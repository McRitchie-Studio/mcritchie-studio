# frozen_string_literal: true

# [unit] bin/release prepare runs the devnet gauntlet on a Turf release, once QA is
# green (prepare_devnet_gauntlet!). The runner, the board and the usage capture are
# stubs in the child; the driver and the devnet RPC are sealed by OutboundSeams, so
# no test reaches QA, devnet, Heroku or 1Password.
#
#   ruby -Itest test/lib/release_cli_prepare_gauntlet_test.rb
require_relative "release_cli_harness"

class ReleaseCliPrepareGauntletTest < ReleaseCliHarness
  TURF = [{ "repo" => "mcritchie-studio", "kind" => "app" }, { "repo" => "turf-monster", "kind" => "app" }].freeze
  HUB_ONLY = [{ "repo" => "mcritchie-studio", "kind" => "app" }].freeze
  GREEN_META = { "contest" => "rehearsal-abc", "settle_signature" => "SETTLE", "close_signature" => "CLOSE",
                 "steps" => {} }.freeze

  # `result:` is what the fake runner answers (nil: no runner may be built);
  # `recorded:` is the board's answer; `usage:` what the session capture yields.
  QA_SHAS = { "mcritchie-studio" => "hub111", "turf-monster" => "turf222" }.freeze
  GREEN_RECORD = { "status" => "completed", "occurred_at" => "2026-10-28T20:00:00Z",
                   "metadata" => { "shas" => { "turf-monster" => "turf222" } } }.freeze

  # `recorded:` is the newest terminal gauntlet event the board answers (nil: none).
  def gauntlet(repos:, result: nil, recorded: nil, usage: {}, skip: false, record_lands: true, shas: QA_SHAS, extra: "")
    runner = if result
               "Release::DevnetGauntletRun::Result.new(**#{result.inspect})"
             else
               "raise('NO RUNNER MAY BE BUILT')"
             end
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("BOARD-READ read_only=" + read_only.to_s) if ruby.include?("devnet_gauntlet")
        { "devnet_gauntlet" => JSON.parse(#{JSON.generate(recorded).inspect}) }
      end
      def devnet_gauntlet_runner(root)
        $stdout.puts("RUNNER-ROOT " + root.to_s)
        o = Object.new
        o.define_singleton_method(:call) { $stdout.puts("RUNNER-CALLED"); #{runner} }
        o
      end
      def seed_gauntlet_usage(key) = $stdout.puts("SEEDED " + key)
      def capture_move_usage(key) = ($stdout.puts("CAPTURED " + key); #{usage.inspect})
      def record_gauntlet_event!(slug, status, attrs)
        $stdout.puts("EVENT " + JSON.generate([slug, Release::DevnetGauntlet::STEP, status, attrs]))
        #{record_lands}
      end
      def abort!(msg) = ($stdout.puts("ABORT: " + msg); raise(SystemExit))
      #{extra}
    RUBY
    call = "begin; puts('OUTCOME ' + prepare_devnet_gauntlet!('rel-g', #{repos.inspect}, skip: #{skip}, shas: #{shas.inspect}).to_s); " \
           "rescue SystemExit; puts('EXITED'); end"
    run_cli([], setup: setup, call: call)
  end

  def event(out)
    line = out.lines.find { |l| l.start_with?("EVENT ") }
    line && JSON.parse(line.delete_prefix("EVENT "))
  end

  def test_a_release_without_turf_runs_nothing
    out = gauntlet(repos: HUB_ONLY)

    assert_includes out, "OUTCOME not_required"
    refute_includes out, "BOARD-READ"
    refute_includes out, "RUNNER-CALLED"
  end

  def test_skip_flag_runs_nothing_and_says_ship_still_refuses
    out = gauntlet(repos: TURF, skip: true)

    assert_includes out, "OUTCOME skipped"
    assert_includes out, "--skip-gauntlet: no devnet gauntlet ran for turf-monster"
    assert_includes out, "`bin/release ship` still refuses this release until one is recorded"
    refute_includes out, "RUNNER-CALLED"
    assert_nil event(out), "a skip records nothing"
  end

  def test_a_green_gauntlet_for_the_turf_code_on_qa_runs_no_second_contest
    out = gauntlet(repos: TURF, recorded: GREEN_RECORD)

    assert_includes out, "BOARD-READ read_only=true"
    assert_includes out, "OUTCOME recorded"
    assert_includes out, "already recorded on rel-g for turf-monster@turf222; not running a second contest"
    refute_includes out, "RUNNER-CALLED"
  end

  # The blocker this binding closes: a green gauntlet, then a new Turf task joins the
  # release and QA redeploys new code. The old record must not stand in for it.
  def test_a_green_gauntlet_for_older_turf_code_runs_a_new_one
    stale = GREEN_RECORD.merge("metadata" => { "shas" => { "turf-monster" => "old0001" } })
    out = gauntlet(repos: TURF, recorded: stale, result: { ok: true, step: nil, reason: nil, metadata: GREEN_META })

    assert_includes out, "RUNNER-CALLED", "new Turf code on QA earns its own gauntlet"
    assert_equal({ "turf-monster" => "turf222" }, event(out).last.dig("metadata", "shas"),
                 "the new record names the Turf SHAs it tested")
  end

  def test_a_red_newest_gauntlet_runs_again
    red = GREEN_RECORD.merge("status" => "failed")
    out = gauntlet(repos: TURF, recorded: red, result: { ok: true, step: nil, reason: nil, metadata: GREEN_META })
    assert_includes out, "RUNNER-CALLED"
  end

  def test_a_green_run_records_complete_with_the_contest_and_signatures_and_the_runs_usage
    usage = { "model" => "claude-opus-5-5", "tokens_in" => 120, "tokens_out" => 40, "cost" => "0.0123" }
    out = gauntlet(repos: TURF, result: { ok: true, step: nil, reason: nil, metadata: GREEN_META }, usage: usage)

    assert_includes out, "SEEDED release:rel-g:devnet_gauntlet", "usage is measured across the run"
    assert_includes out, "CAPTURED release:rel-g:devnet_gauntlet"
    slug, step, status, attrs = event(out)
    assert_equal %w[rel-g devnet_gauntlet completed], [slug, step, status]
    assert_equal "turf_monster", attrs["actor"]
    assert_equal "agent", attrs["source"], "a full usage capture is an agent event"
    assert_equal [120, 40, "0.0123", "claude-opus-5-5"], attrs.values_at("tokens_in", "tokens_out", "cost", "model")
    assert_equal "rehearsal-abc", attrs.dig("metadata", "contest")
    assert_equal %w[SETTLE CLOSE], attrs["metadata"].values_at("settle_signature", "close_signature")
    assert_equal ["turf-monster"], attrs.dig("metadata", "repos")
    assert_includes out, "OUTCOME completed"
  end

  def test_with_no_session_usage_the_event_is_the_conductors_own
    out = gauntlet(repos: TURF, result: { ok: true, step: nil, reason: nil, metadata: GREEN_META }, usage: {})

    attrs = event(out).last
    assert_equal "conductor", attrs["source"], "never an agent event without its usage (MISSING_EVENT_USAGE)"
    refute attrs.key?("tokens_in"), "no hand-typed numbers"
  end

  def test_a_red_step_records_fail_and_names_the_step
    meta = { "contest" => "rehearsal-abc", "failed_step" => "play", "steps" => {} }
    out = gauntlet(repos: TURF, result: { ok: false, step: "play", reason: "replay: CATCH-UP FAILED — x", metadata: meta })

    _, step, status, attrs = event(out)
    assert_equal %w[devnet_gauntlet failed], [step, status]
    assert_equal "play", attrs.dig("metadata", "failed_step")
    assert_includes out, "✗ devnet gauntlet RED at step `play`: replay: CATCH-UP FAILED — x"
    assert_includes out, "Recorded devnet_gauntlet fail on rel-g"
    assert_includes out, "OUTCOME red", "prepare turns :red into PREPARE_GAUNTLET_RED_EXIT"
  end

  def test_a_green_run_whose_record_does_not_land_is_loud_not_green
    out = gauntlet(repos: TURF, result: { ok: true, step: nil, reason: nil, metadata: GREEN_META }, record_lands: false)

    assert_includes out, "was NOT recorded on rel-g, so `bin/release ship` will refuse it"
    assert_includes out, "/api/v1/releases/current/events/devnet_gauntlet/complete"
    assert_includes out, "OUTCOME unrecorded"
  end

  def test_a_red_gauntlet_is_its_own_exit_status
    out = run_cli([], call: "puts(Release::Cli.prepare_exit_status(:gauntlet_red)); " \
                            "puts(Release::Cli.prepare_exit_status(:assembled))")
    assert_equal %w[4 0], out.lines.map(&:strip).last(2)
  end

  def test_the_guard_accepts_skip_gauntlet_on_prepare
    call = 'guard_argv!(["prepare", "--skip-gauntlet"], exiter: ->(code) { puts("EXITED " + code.to_s) }); ' \
           'puts("GUARD-PASSED")'
    out = run_cli([], call: call)

    assert_includes out, "GUARD-PASSED"
    refute_includes out, "EXITED"
  end

  # The containment receipt: in a test child the real driver is the sealed stub,
  # so a gauntlet step reaches neither QA nor devnet, and says so by failing.
  def test_a_test_child_runs_the_sealed_driver_never_turf_monsters
    call = 'require "tmpdir"; out, ok = run_gauntlet_step(Dir.tmpdir, ["seed"]); ' \
           'puts("OK=" + ok.to_s); puts("SEAL-LOG " + File.read(ENV["OUTBOUND_SEAM_LOG"]).to_s)'
    out = run_cli(["--local"], call: call)

    assert_includes out, "OK=false"
    assert_match(/SEAL-LOG .*qa-contest-rehearsal seed/m, out)
  end

  # --- the dedupe key carries the Turf SHAs ---------------------------------------

  RED_PLAY = { ok: false, step: "play", reason: "replay: CATCH-UP FAILED — x",
               metadata: { "failed_step" => "play", "steps" => {} } }.freeze

  def red_key(shas)
    out = gauntlet(repos: TURF, shas: shas, result: RED_PLAY)
    event(out).last["idempotency_key"]
  end

  # The defect: two reds at the same step and the same duration on DIFFERENT Turf
  # code shared one key, so the second (new code, still red) was swallowed as a
  # replay of the first. Seconds are the run's own and both runs here take 0s.
  def test_two_red_runs_on_different_turf_shas_record_two_events
    first = red_key(QA_SHAS)
    second = red_key(QA_SHAS.merge("turf-monster" => "turf333"))

    refute_equal first, second, "a red on new Turf code must land as its own event"
    assert_includes second, "turf-monster@turf333"
    assert_equal first, red_key(QA_SHAS), "the same run on the same code still dedupes"
  end

  # --- the driver runs from the release's turf-monster tree ------------------------

  def test_a_turf_release_with_no_turf_monster_sha_is_red_at_tree_and_runs_nothing
    out = gauntlet(repos: TURF, shas: QA_SHAS.merge("turf-monster" => ""),
                   result: { ok: true, step: nil, reason: nil, metadata: GREEN_META },
                   extra: 'ENV.delete("RELEASE_GAUNTLET_DRIVER")')

    refute_includes out, "RUNNER-CALLED", "no contest runs on a driver this release cannot name"
    _, _, status, attrs = event(out)
    assert_equal "failed", status
    assert_equal "tree", attrs.dig("metadata", "failed_step")
    assert_includes out, "RED at step `tree`: no QA SHA for turf-monster"
    assert_includes out, "OUTCOME red"
  end

  # A scratch turf-monster: commit A's driver says "driver A", commit B's "driver B",
  # and the primary sits on A (main, behind the release). The gauntlet given B must
  # run B's driver from a tree at B, and leave no worktree behind.
  def with_scratch_turf
    Dir.mktmpdir("gauntlet-turf") do |dir|
      primary = File.join(dir, "turf-monster")
      git = ->(*args) { system("git", "-C", primary, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')}") }
      FileUtils.mkdir_p(File.join(primary, "bin"))
      git.call("init", "-q")
      driver = File.join(primary, "bin", "qa-contest-rehearsal")
      shas = %w[A B].map do |name|
        File.write(driver, "#!/bin/sh\necho \"driver #{name} $* in $(pwd)\"\n")
        FileUtils.chmod(0o755, driver)
        git.call("add", "-A")
        git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name)
        `git -C #{primary} rev-parse HEAD`.strip
      end
      git.call("checkout", "-q", shas.first)
      File.write(File.join(primary, ".env"), "FROM_PRIMARY=1\n")
      yield primary, *shas
    end
  end

  def tree_path(out) = out[/gauntlet driver: turf-monster@\h{7} \((\S+)\)/, 1] || flunk("no tree named: #{out}")

  def tree_call(primary, sha, body, rescue_it: false)
    setup = <<~RUBY
      ENV.delete("RELEASE_GAUNTLET_DRIVER")
      def repo_path(_repo) = #{primary.inspect}
      def bundle_gauntlet_tree(_path) = nil
    RUBY
    call = "r = with_gauntlet_tree(['turf-monster'], { 'turf-monster' => #{sha.inspect} }) { |root| #{body} }; " \
           "puts('RESULT ' + r.inspect)"
    call = "begin; #{call}; rescue RuntimeError => e; puts('RAISED ' + e.message); end" if rescue_it
    run_cli([], setup: setup, call: call)
  end

  def test_the_driver_runs_from_a_worktree_at_the_release_sha_not_the_primary
    with_scratch_turf do |primary, _main_sha, release_sha|
      body = 'out, ok = run_gauntlet_step(root, ["seed"]); puts("ENV-COPIED " + File.exist?(File.join(root, ".env")).to_s); ' \
             'puts("STEP " + out.strip + " ok=" + ok.to_s); :ran'
      out = tree_call(primary, release_sha, body)

      assert_match(%r{STEP driver B seed in \S*/gauntlet-turf-monster-[^/\s]+ ok=true}, out,
                   "the release's driver (B), from the release tree, never the primary's (A)")
      assert_includes out, "ENV-COPIED true", "the tree boots with the primary's env"
      assert_includes out, "RESULT :ran", "the block's result is the answer"
      tree = tree_path(out)
      refute tree.start_with?(primary), "a throwaway is never cut inside turf-monster (DeskRoot's managed root)"
      refute File.exist?(tree), "the tree is removed after the run"
      assert_equal 1, `git -C #{primary} worktree list`.lines.size, "no worktree registration is left behind"
      assert_equal "A", `git -C #{primary} log -1 --format=%s`.strip, "the primary checkout is untouched"
    end
  end

  def test_the_tree_is_removed_even_when_the_run_raises
    with_scratch_turf do |primary, _main_sha, release_sha|
      out = tree_call(primary, release_sha, 'File.write(File.join(root, "MARK"), "x"); raise "boom"', rescue_it: true)
      assert_includes out, "RAISED boom", "the raise reaches the caller"
      refute File.exist?(tree_path(out)), "ensure removes the tree"
      assert_equal 1, `git -C #{primary} worktree list`.lines.size
    end
  end

  def test_an_unknown_release_sha_is_red_at_tree
    with_scratch_turf do |primary, _main_sha, _release_sha|
      out = tree_call(primary, "f" * 40, ":ran")
      assert_match(/RESULT .*step="tree".*could not cut a turf-monster worktree/m, out)
      assert_equal 1, `git -C #{primary} worktree list`.lines.size
    end
  end

  # --- the overall deadline bounds a step it would outlast -------------------------

  def test_a_step_longer_than_the_overall_budget_is_killed_naming_the_overall_bound
    Dir.mktmpdir("gauntlet-slow") do |dir|
      slow = File.join(dir, "slow-driver")
      File.write(slow, "#!/bin/sh\nsleep 30\n")
      FileUtils.chmod(0o755, slow)
      call = "ENV['RELEASE_GAUNTLET_DRIVER'] = #{slow.inspect}; t = Time.now; " \
             "out, ok = run_gauntlet_step(#{dir.inspect}, ['play'], budget: 1); " \
             "puts('OK=' + ok.to_s); puts('SECS=' + (Time.now - t).round.to_s); puts(out)"
      out = run_cli([], call: call)

      assert_includes out, "OK=false"
      assert_operator out[/SECS=(\d+)/, 1].to_i, :<, 10, "killed at the budget, not the 1200s step bound"
      assert_includes out, "(RELEASE_GAUNTLET_DEADLINE sets the bound)"
    end
  end
end
