# frozen_string_literal: true

require "time"
require "stringio"

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
#   prepare → qa verify → ship → prod verify (green: the Slack posts) → archive
#
# Each act is the existing `bin/release <step>`, run as a child with the lane's
# credentials (CREDENTIALS below); the cycle adds only the seams between them. It
# never ships without the clearance string, and it stands down when another session
# holds the release claim. Every act prints one line on entry and one on exit, with
# its elapsed time and the DevOps estimate's ETA when the board has one.
#
# PURE. Every collaborator is a method on +deps+ (snapshot, run_step, http_status,
# deployed_sha_verdicts, pause, session_id, now), so the machine is proven with fake steps and a fake board; no
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
  # Prod verify's deployed-SHA read: attempts, and the seconds between them.
  SHA_READ_ATTEMPTS = 3
  SHA_READ_PAUSE = 20

  # The step's own refusal (no clearance, a bad flag): nothing ran.
  REFUSED = 2
  # A QA or production URL did not answer 200, or a production app does not run the
  # SHA the release froze.
  VERIFY_FAILED = 5
  # A credential the step needs could not be minted.
  CREDENTIAL_MISSING = 9
  # Another live session holds the release claim (ReleaseClaimCli::STOOD_DOWN).
  STOOD_DOWN = 10
  # The board could not be read, or said something the cycle cannot act on.
  BOARD_UNREADABLE = 1

  # A transient GitHub network failure, by the message curl and git print: one LINE
  # naming github.com AND the failure, within the output's last NETWORK_WINDOW lines
  # (a production /up timeout, or one a step recovered from long ago, is not it).
  # One re-run of the step: prepare and ship both resume where they stopped.
  NETWORK_FAILURE = /^(?=.*github\.com).*(?:Failed to connect to|Timeout was reached|Could not resolve host)/
  NETWORK_WINDOW = 40

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
    RETRYABLE.each do |pattern, cause|
      text = pattern.equal?(NETWORK_FAILURE) ? output.to_s.lines.last(NETWORK_WINDOW).join : output.to_s
      return cause if pattern.match?(text)
    end
    nil
  end

  def gauntlet_refusal?(output) = GAUNTLET_REFUSAL.match?(output.to_s)

  # Why the active release owes a devnet gauntlet, in words, or nil when it owes none.
  # +current+ is the snapshot's release: its repos, the newest terminal gauntlet
  # record ("gauntlet", the slice Release::DevnetGauntlet::SNAPSHOT_RUBY reads) and
  # the SHAs QA runs ("qa_shas"). Owed unless that record COVERS the Turf SHAs on QA
  # (Release::DevnetGauntlet.covers?): none, a red one, or a green one on other code.
  def gauntlet_owed(current)
    current = {} unless current.is_a?(Hash)
    rules = gauntlet_rules
    turf = rules.turf_repos(current["repos"])
    return nil if turf.empty?

    record = current["gauntlet"]
    shas = current["qa_shas"].is_a?(Hash) ? current["qa_shas"] : {}
    return nil if rules.covers?(record, turf: turf, shas: shas)

    return "has no devnet gauntlet recorded" unless record.is_a?(Hash)
    return "has a RED newest devnet gauntlet (#{record['occurred_at']})" if record["status"] == "failed"

    tested = record.dig("metadata", "shas")
    tested = {} unless tested.is_a?(Hash)
    "has a green devnet gauntlet on other Turf code: it tested #{sha_list(turf, tested)}, QA runs #{sha_list(turf, shas)}"
  end

  # Release::DevnetGauntlet, loaded on first use rather than at require time. It
  # opens `class Release`, so a plain require that runs BEFORE Rails boots (a test
  # file loaded ahead of test_helper) defines a bare Release, and Zeitwerk then never
  # loads the ActiveRecord model (Release.create! undefined). bin/release requires
  # it itself; under Rails `defined?` autoloads it; bare ruby requires it here.
  def gauntlet_rules
    require_relative "../../app/models/release/devnet_gauntlet" unless defined?(Release::DevnetGauntlet)
    Release::DevnetGauntlet
  end

  def sha_list(repos, shas)
    repos.map { |r| "#{r}@#{shas[r].to_s.empty? ? '?' : shas[r].to_s[0, 7]}" }.join(", ")
  end

  # The SHA prod verify holds an app to: what the ship PUSHED
  # (release.metadata["shipped_shas"]), else what QA froze (qa_shas). A candidate
  # gem's re-pin commit ships newer than qa_shas, so qa_shas alone false-reds it.
  def frozen_sha(repo, shipped_shas, qa_shas)
    [shipped_shas, qa_shas].each do |shas|
      sha = (shas.is_a?(Hash) ? shas[repo] : nil).to_s.strip
      return sha unless sha.empty?
    end
    ""
  end

  # The deployed-SHA verdicts for prod verify, one per app group; live(group, sha)
  # answers [ok, reason] (bin/release.rb#deploy_live_verdict). A repo with no SHA
  # recorded is NOT proven: there is nothing to compare production with.
  def sha_verdicts(groups, qa_shas, live:, shipped_shas: {})
    Array(groups).map do |group|
      repo = group["repo"].to_s
      sha = frozen_sha(repo, shipped_shas, qa_shas)
      ok, reason = sha.empty? ? [false, "no shipped or frozen SHA recorded on the release"] : live.call(group, sha)
      { "repo" => repo, "sha" => sha, "ok" => ok ? true : false, "reason" => reason.to_s }
    end
  end

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
  # The admin lane's secrets (OpVaults :deployer, HerokuToken :admin/:applications).
  # A child inherits the parent's env, so an operator who sourced ~/.zprofile.admin
  # would hand them to prepare and archive: those acts UNSET them.
  ADMIN_ONLY_ENV = %w[OP_ADMIN_SERVICE_ACCOUNT_TOKEN HEROKU_STUDIO_ADMIN_API_KEY HEROKU_STUDIO_APPLICATIONS_API_KEY].freeze

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
      ADMIN_ONLY_ENV.each { |name| env[name] = nil }
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
    # a green devnet gauntlet on the record FOR THE TURF CODE QA RUNS NOW (else prepare
    # runs one: it is owed). The same SHA-bound rule the ship and prepare read
    # (Release::DevnetGauntlet.covers?): a green gauntlet on older Turf code is owed,
    # never counted. 2026-10-29 (rel-20261029-f328a7): the cycle read only the newest
    # status, so a green record for code QA no longer ran passed straight to the ship.
    def stage_qa_verify(snapshot, fresh:)
      status = verify(:qa)
      return [status, snapshot] unless status.zero?

      current = snapshot["current"] || {}
      owed = ReleaseCycle.gauntlet_owed(current)
      if owed
        say("  devnet gauntlet owed on #{current['slug']}: it #{owed}; re-running prepare, which runs it")
        status = run_step("prepare", prepare_argv)
        return [status, snapshot] unless status.zero?

        snapshot = read_snapshot || snapshot
      end
      [OK, snapshot]
    end

    def stage_ship(snapshot, fresh:)
      current = snapshot["current"] || {}
      say("  ⚠ shipping #{current['slug'] || 'the active release'} (#{Array(current['repos']).join(', ')}) to " \
          "PRODUCTION under the clearance \"#{@clearance}\"")
      status, output = run_step_with_output("ship", ship_argv)
      # ONE recovery, by construction: the second ship's verdict is final.
      if !status.zero? && ReleaseCycle.gauntlet_refusal?(output)
        say("  ship refused for the devnet gauntlet; re-running prepare (it runs the gauntlet), then the ship once")
        status = run_step("prepare", prepare_argv)
        return [status, snapshot] unless status.zero?

        status, = run_step_with_output("ship", ship_argv)
      end
      return [status, snapshot] unless status.zero?

      # The release prod verify proves: the one this cycle just shipped, by name, so a
      # board read that lags (or fails) cannot point the SHA check at another release.
      @shipped_slug = current["slug"]
      [OK, read_snapshot || snapshot]
    end

    # Each production app answers 200 on /up and /, AND runs the SHA the release froze.
    # A 200 proves an app is up, not that it runs this release: a deploy that never
    # landed answers 200 from the old code (rel-20261029-f328a7's prod verify took 1s).
    #
    # Green, it tells the release on Slack (announce): never a reason to stop.
    def stage_prod_verify(snapshot, fresh:)
      status = verify(:prod)
      return [status, snapshot] unless status.zero?

      slug = @shipped_slug || snapshot.dig("last_shipped", "slug")
      status = verify_deployed_shas(slug)
      announce(slug) if status.zero?
      [status, snapshot]
    end

    # The Slack posts for a green production (`bin/release announce`, through the
    # deps): the #agents-general summary, each app's post and its smoke verdict.
    # BEST-EFFORT by construction: whatever it answers or raises, prod verify's
    # verdict stands, and the line says what was sent and what failed.
    def announce(slug)
      return if slug.to_s.empty? || !@deps.respond_to?(:announce)

      line = @deps.announce(slug, repos: @repos, verdicts: @sha_verdicts)
      say("  #{line}") unless line.to_s.empty?
    rescue StandardError => e
      say("  ⚠ Slack posts: not made (#{e.class}: #{e.message}); the release stands. " \
          "Re-run: bin/release announce #{slug} --post")
    end

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

    # The deployed-SHA leg of prod verify: every app the shipped release carries runs
    # its frozen SHA, read by the deps (the finalize guard's per-strategy probes:
    # the Heroku release, the deploy workflow run, the static marker). nil from the
    # deps is an unreadable answer and fails closed: unproven is not verified.
    def verify_deployed_shas(slug)
      slug = slug.to_s
      if slug.empty?
        say("  ✗ no shipped release on the board to read its frozen SHAs from; the deployed SHAs are unproven")
        return VERIFY_FAILED
      end
      verdicts = @sha_verdicts = read_sha_verdicts(slug)
      if verdicts.nil?
        say("  ✗ could not read #{slug}'s frozen SHAs or what production runs; the deployed SHAs are unproven")
        return VERIFY_FAILED
      end
      if verdicts.empty?
        say("  no app on #{slug} to check a deployed SHA for")
        return OK
      end
      bad = verdicts.reject { |v| v["ok"] }
      verdicts.each do |v|
        sha = v["sha"].to_s.empty? ? "?" : v["sha"].to_s[0, 7]
        say(v["ok"] ? "  ✓ #{v['repo']} runs #{sha} (the shipped SHA)" : "  ✗ #{v['repo']} not proven at #{sha} — #{v['reason']}")
      end
      return OK if bad.empty?

      say("  #{bad.size} app(s) not proven at #{slug}'s frozen SHA: #{bad.map { |v| v['repo'] }.join(', ')}")
      VERIFY_FAILED
    end

    # A just-shipped app can trail its deploy by a few seconds (a release phase, a
    # dyno restart, a workflow run still concluding), and the reads are network
    # calls. So an unreadable or not-yet-proven answer is read again, up to
    # SHA_READ_ATTEMPTS times SHA_READ_PAUSE seconds apart, before prod verify fails.
    def read_sha_verdicts(slug)
      verdicts = nil
      SHA_READ_ATTEMPTS.times do |attempt|
        verdicts = @deps.deployed_sha_verdicts(slug)
        return verdicts if verdicts && verdicts.all? { |v| v["ok"] }
        break if attempt == SHA_READ_ATTEMPTS - 1

        say("  ↻ deployed SHAs not proven yet (read #{attempt + 1}/#{SHA_READ_ATTEMPTS}); reading again in #{SHA_READ_PAUSE}s")
        @deps.pause(SHA_READ_PAUSE)
      end
      verdicts
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
