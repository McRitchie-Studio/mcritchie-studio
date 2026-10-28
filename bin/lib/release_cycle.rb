# frozen_string_literal: true

require "time"

# ReleaseCycle — `bin/release cycle --clearance "<Alex McRitchie's words>"`: the whole
# release, prepare to archive, as one resumable command.
#
# WHY (2026-10-28). Every release that day was run by hand from scratch scripts: one
# to export OP_CACHE=false, mint the agent GitHub token and run `prepare`; another to
# source the admin 1Password token, mint the DEPLOYER token and run `ship --mode
# cleared`; a third for `archive`; a watcher that polled 1Password every two minutes
# and re-ran prepare; `caffeinate -is -w $$` in each; and `curl` by eye on every QA
# and production URL between them. The same failures recurred and were absorbed by
# the operator each time: a GitHub connect timeout 545 seconds into prepare (a re-run
# resumed it), a ship refused for a Turf release with no devnet gauntlet (a re-run of
# prepare runs it), a stale-tree refusal when a newcomer landed on `accepted`
# mid-release (a re-run of bare prepare sweeps it). Alex McRitchie: "think about how to
# systemize so they run seamlessly." This is the scripts, absorbed.
#
# THE SHAPE. A state machine over the board's own record, so re-running it resumes:
#
#   board says                          the cycle starts at
#   no active release, nothing to file  prepare
#   assembling                          prepare
#   assembled                           qa verify  (then ship)
#   no active release, archive pending  prod verify (the last release shipped; then archive)
#
#   prepare → qa verify → ship → prod verify → archive
#
# Each act is the existing `bin/release <step>`, run as a child with the lane's
# credentials (CREDENTIALS below); the cycle adds only the seams between them. It
# never ships without the clearance string, and it stands down when another session
# holds the release claim. Every act prints one line on entry and one on exit, with
# its elapsed time and the DevOps estimate's ETA when the board has one.
#
# PURE. Every collaborator is a method on +deps+ (snapshot, run_step, http_status,
# session_id, now), so the machine is proven with fake steps and a fake board; no
# test ever runs a real prepare or ship. bin/release.rb supplies the live deps.
module ReleaseCycle
  STAGES = %w[prepare qa_verify ship prod_verify archive].freeze
  LABELS = {
    "prepare" => "prepare",
    "qa_verify" => "qa verify",
    "ship" => "ship",
    "prod_verify" => "prod verify",
    "archive" => "archive"
  }.freeze

  OK = 0
  # The step's own refusal (no clearance, a bad flag): nothing ran.
  REFUSED = 2
  # A QA or production URL did not answer 200.
  VERIFY_FAILED = 5
  # A credential the step needs could not be minted.
  CREDENTIAL_MISSING = 9
  # Another live session holds the release claim (ReleaseClaimCli::STOOD_DOWN).
  STOOD_DOWN = 10
  # The board could not be read, or said something the cycle cannot act on.
  BOARD_UNREADABLE = 1

  # A transient GitHub network failure, by the message curl and git print. One re-run
  # of the step: prepare and ship both resume where they stopped.
  NETWORK_FAILURE = /Failed to connect to github\.com|Timeout was reached|Could not resolve host/

  # prepare's stale-tree refusal (bin/release.rb#verify_release_carries_accepted!):
  # `accepted` moved after the promote, almost always a newcomer reviewed mid-run.
  # A re-run of bare prepare sweeps it onto the candidate.
  STALE_TREE = /stale tree: `release` does not carry `accepted`/

  # ship's devnet-gauntlet refusal (Release::DevnetGauntlet.refusal). Its remedy is
  # re-running prepare, which runs the contest-rehearsal on QA and records it.
  GAUNTLET_REFUSAL = /Re-run `bin\/release prepare`, which runs Turf Monster's contest-rehearsal/

  RETRYABLE = [
    [NETWORK_FAILURE, "a transient GitHub network failure"],
    [STALE_TREE, "a stale-tree refusal (work landed on `accepted` mid-release)"]
  ].freeze

  module_function

  # What a failed step's output says about re-running it: the cause in words, or nil
  # when the failure is not one a re-run can heal.
  def retryable_cause(output)
    RETRYABLE.each { |pattern, cause| return cause if pattern.match?(output.to_s) }
    nil
  end

  def gauntlet_refusal?(output) = GAUNTLET_REFUSAL.match?(output.to_s)

  # The stage a cycle enters at, from the board snapshot.
  def entry_stage(snapshot)
    current = snapshot["current"]
    return current["state"] == "assembled" ? "qa_verify" : "prepare" if current
    return "prod_verify" if snapshot["last_shipped"] && snapshot["archivable"].to_i.positive?

    "prepare"
  end

  # The live claims on the release lane held by a session other than +own_session+.
  # A claim this session holds is a resume, not a collision.
  def foreign_holders(snapshot, own_session)
    Array(snapshot["holders"]).select do |holder|
      holder.is_a?(Hash) && holder["live"] && holder["session"].to_s != own_session.to_s
    end
  end

  # [[app, url], ...] to check for +target+ (:qa or :prod) across the apps +repos+
  # carries, plus the hub, which every release redeploys. A repo with no URL for the
  # target (a gem, an Anchor program, an app with no QA env) is skipped.
  def verify_targets(repos, target, app_repos:, qa_environments:, hub: "mcritchie-studio")
    apps = ([hub] + Array(repos).map(&:to_s)).uniq.select { |repo| app_repos.key?(repo) }
    apps.filter_map do |repo|
      meta = app_repos[repo] || {}
      qa_app = meta.dig("qa_deploy", "app") || repo
      env = qa_environments[qa_app] || {}
      url = if target == :qa
              env["qa_url"]
            else
              meta.dig("prod_deploy", "smoke_url").to_s.strip.then { |s| s.empty? ? env["production_url"] : s }
            end
      url = url.to_s.strip.chomp("/")
      [repo, url] unless url.empty?
    end
  end

  def duration(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60

    hours, rest = seconds.divmod(3600)
    minutes, secs = rest.divmod(60)
    hours.positive? ? "#{hours}h #{minutes}m" : "#{minutes}m #{secs}s"
  end

  # Denver wall-clock time, as the operator reads it.
  def stamp(time)
    saved = ENV["TZ"]
    ENV["TZ"] = "America/Denver"
    time.localtime.strftime("%H:%M %Z")
  ensure
    ENV["TZ"] = saved
  end

  # The ETA clause from the snapshot's DevOps estimate, or "" without one.
  def eta_clause(snapshot)
    eta = snapshot && snapshot.dig("estimate", "eta")
    return "" if eta.to_s.empty?

    " · ETA #{stamp(Time.iso8601(eta.to_s))} (DevOps estimate)"
  rescue ArgumentError
    ""
  end

  # THE CREDENTIALS each act runs with — the scratch scripts' preamble, in one place.
  #
  #   prepare, archive  the AGENT GitHub App (build/review lane): GH_APP_ITEM unset
  #   ship              the DEPLOYER App (GH_APP_ITEM=github.mcritchie-admin), which
  #                     needs the admin 1Password token (~/.zprofile.admin)
  #
  # Every act also gets OP_CACHE=false (the cache daemon is what hangs) and a CI poll
  # budget of an hour. The token is minted fresh for EVERY attempt, a retry included,
  # so a long wait between acts never hands the next one an expired token; inside an
  # act, bin/release re-mints on an auth failure itself (GhAuthRetry), in the lane
  # GH_APP_ITEM names. GH_TOKEN is never set EMPTY: an empty GH_TOKEN makes `gh`
  # refuse every call, where an absent one falls back to its own login.
  #
  # Returns [env, minted?]. A nil value in env UNSETS that variable in the child.
  def step_env(step, mint:, admin_token: -> { }, base_env: ENV)
    env = { "OP_CACHE" => "false" }
    poll = base_env["RELEASE_CI_POLL_TIMEOUT"].to_s.strip
    env["RELEASE_CI_POLL_TIMEOUT"] = poll.empty? ? "3600" : poll
    identity = step == "ship" ? "deployer" : "agent"
    if identity == "deployer"
      env["GH_APP_ITEM"] = "github.mcritchie-admin"
      if base_env["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"].to_s.strip.empty?
        admin = admin_token.call.to_s.strip
        env["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"] = admin unless admin.empty?
      end
    else
      env["GH_APP_ITEM"] = nil
    end
    token = mint.call(identity, env).to_s.strip
    env["GH_TOKEN"] = token.empty? ? nil : token
    [env, !token.empty?]
  end

  # The state machine. One instance per `bin/release cycle`.
  class Runner
    def initialize(clearance:, deps:, out: $stdout, assume_yes: false, wait_for_1password: nil, extra_args: [])
      @clearance = clearance.to_s.strip
      @deps = deps
      @out = out
      @assume_yes = assume_yes
      @wait = wait_for_1password
      @extra = Array(extra_args)
    end

    def run
      if @clearance.empty?
        say("✗ cycle refused: no --clearance. The cycle ends in a production ship, and only Alex McRitchie's " \
            "own words clear one: bin/release cycle --clearance \"<his words>\". Nothing ran.")
        return REFUSED
      end

      @started = @deps.now
      snapshot = read_snapshot or return BOARD_UNREADABLE

      foreign = ReleaseCycle.foreign_holders(snapshot, @deps.session_id)
      if foreign.any?
        foreign.each { |h| say("✗ #{holder_line(h)}") }
        say("✗ cycle stood down: another session holds the release claim. Let it finish (its lease lapses " \
            "about two minutes after it stops), then re-run: the cycle resumes from the board. Nothing ran.")
        return STOOD_DOWN
      end

      stage = ReleaseCycle.entry_stage(snapshot)
      @repos = repos_of(snapshot, stage)
      say("Release cycle: #{describe(snapshot)} → starting at #{LABELS[stage]}" \
          "#{ReleaseCycle.eta_clause(snapshot)}")

      STAGES.drop(STAGES.index(stage)).each_with_index do |name, i|
        number = STAGES.index(name) + 1
        say("▸ #{number}/#{STAGES.size} #{LABELS[name]} · #{ReleaseCycle.stamp(@deps.now)}" \
            "#{ReleaseCycle.eta_clause(snapshot)}")
        began = @deps.now
        status, snapshot = send("stage_#{name}", snapshot, fresh: i.zero?)
        elapsed = ReleaseCycle.duration(@deps.now - began)
        if status == :done
          say("✓ #{LABELS[name]} · #{elapsed} · #{@done_reason}")
          return finish(OK)
        end
        unless status.zero?
          say("✗ #{LABELS[name]} · #{elapsed} · stopped (exit #{status}). Fix what it names, then re-run " \
              "`bin/release cycle`: it resumes from the board.")
          return finish(status)
        end
        say("✓ #{LABELS[name]} · #{elapsed} (cycle #{ReleaseCycle.duration(@deps.now - @started)})")
      end
      finish(OK)
    end

    private

    # --- the acts -------------------------------------------------------------

    def stage_prepare(snapshot, fresh:)
      status = run_step("prepare", prepare_argv)
      return [status, snapshot] unless status.zero?

      after = read_snapshot or return [BOARD_UNREADABLE, snapshot]
      current = after["current"]
      if current.nil?
        @done_reason = "nothing to release: prepare found no reviewed work and no release is active"
        return [:done, after]
      end
      unless current["state"] == "assembled"
        say("  prepare exited 0 but #{current['slug']} is #{current['state']}, not assembled")
        return [BOARD_UNREADABLE, after]
      end
      @repos = Array(current["repos"])
      [OK, after]
    end

    # Each QA app the release carries answers 200 on /up and /, and a Turf release has
    # a green devnet gauntlet on the record (else prepare runs one: it is owed).
    def stage_qa_verify(snapshot, fresh:)
      status = verify(:qa)
      return [status, snapshot] unless status.zero?

      current = snapshot["current"] || {}
      if current["gauntlet_required"] && current["gauntlet_status"] != "completed"
        say("  devnet gauntlet owed on #{current['slug']} (newest: #{current['gauntlet_status'] || 'none'}); " \
            "re-running prepare, which runs it")
        status = run_step("prepare", prepare_argv)
        return [status, snapshot] unless status.zero?

        snapshot = read_snapshot || snapshot
      end
      [OK, snapshot]
    end

    def stage_ship(snapshot, fresh:)
      status, output = run_step_with_output("ship", ship_argv)
      # ONE recovery, by construction: the second ship's verdict is final.
      if !status.zero? && ReleaseCycle.gauntlet_refusal?(output)
        say("  ship refused for the devnet gauntlet; re-running prepare (it runs the gauntlet), then the ship once")
        status = run_step("prepare", prepare_argv)
        return [status, snapshot] unless status.zero?

        status, = run_step_with_output("ship", ship_argv)
      end
      return [status, snapshot] unless status.zero?

      [OK, read_snapshot || snapshot]
    end

    def stage_prod_verify(snapshot, fresh:) = [verify(:prod), snapshot]

    def stage_archive(snapshot, fresh:) = [run_step("archive", archive_argv), snapshot]

    # --- plumbing -------------------------------------------------------------

    def run_step(name, argv) = run_step_with_output(name, argv).first

    # Runs the step; on a failure a re-run can heal, says so and runs it ONCE more.
    def run_step_with_output(name, argv)
      retried = false
      loop do
        status, output = @deps.run_step(name, argv)
        return [status, output] if status.zero?

        cause = ReleaseCycle.retryable_cause(output)
        return [status, output] if cause.nil? || retried

        retried = true
        say("  ↻ #{name} exited #{status} on #{cause}; re-running it once (it resumes)")
      end
    end

    def verify(target)
      targets = @deps.verify_targets(@repos, target)
      if targets.empty?
        say("  no #{target == :qa ? 'QA' : 'production'} URL for #{@repos.join(', ')}; nothing to check")
        return OK
      end
      bad = []
      targets.each do |app, base|
        %w[/up /].each do |path|
          url = path == "/" ? "#{base}/" : "#{base}#{path}"
          code = @deps.http_status(url)
          ok = code.to_s == "200"
          say("  #{ok ? '✓' : '✗'} #{app} #{url} → #{code || 'no answer'}")
          bad << url unless ok
        end
      end
      return OK if bad.empty?

      say("  #{bad.size} URL(s) did not answer 200: #{bad.join(', ')}")
      VERIFY_FAILED
    end

    def read_snapshot
      2.times do |attempt|
        snapshot = @deps.snapshot
        return snapshot if snapshot.is_a?(Hash)

        say("  ↻ board read failed; reading it once more") if attempt.zero?
      end
      say("✗ cycle could not read the board (Release.current and its claims). Nothing further ran.")
      nil
    end

    def repos_of(snapshot, stage)
      release = stage == "prod_verify" ? snapshot["last_shipped"] : snapshot["current"]
      Array(release && release["repos"])
    end

    def prepare_argv = ["prepare", *common_flags, *wait_flag]
    def archive_argv = ["archive", *common_flags]

    def ship_argv
      ["ship", "--mode", "cleared", "--clearance", @clearance, *common_flags, *wait_flag]
    end

    def common_flags = [*(@assume_yes ? ["--yes"] : []), *@extra]
    def wait_flag = @wait ? ["--wait-for-1password=#{@wait}"] : []

    def describe(snapshot)
      current = snapshot["current"]
      return "#{current['slug']} is #{current['state']}" if current

      last = snapshot["last_shipped"]
      archivable = snapshot["archivable"].to_i
      if last && archivable.positive?
        "no active release; #{last['slug']} shipped and #{archivable} task(s) await the archive"
      else
        "no active release"
      end
    end

    def holder_line(holder)
      sentence = holder["sentence"].to_s.strip
      return sentence unless sentence.empty?

      "#{holder['role']} claim on #{holder['release_slug']} is held by session …#{holder['session'].to_s[-4..]}"
    end

    def finish(status)
      say("Release cycle #{status.zero? ? 'done' : 'stopped'} · #{ReleaseCycle.duration(@deps.now - @started)}") if @started
      status
    end

    def say(line) = @out.puts(line)
  end
end
