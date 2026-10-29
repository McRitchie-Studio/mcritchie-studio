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
      def devnet_gauntlet_runner(root, started_at: nil)
        $stdout.puts("RUNNER-ROOT " + root.to_s + " STARTED-AT " + started_at.inspect)
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

  # `warm:` is the warm tree's path; nil runs the cold cut, as OutboundSeams seals it.
  def tree_call(primary, sha, body, rescue_it: false, tmp_root: nil, warm: nil)
    setup = <<~RUBY
      ENV.delete("RELEASE_GAUNTLET_DRIVER")
      ENV["RELEASE_GAUNTLET_WARM_TREE"] = #{(warm || "off").inspect}
      def repo_path(_repo) = #{primary.inspect}
      def bundle_gauntlet_tree(_path) = nil
      #{"def gauntlet_tmp_root = #{tmp_root.inspect}" if tmp_root}
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

  # --- a red run keeps its devnet state; a killed run's tree is swept --------------

  STATE = '{"contest_slug":"rehearsal-open","step":"settle"}'

  def write_state_body(result)
    'FileUtils.mkdir_p(File.join(root, "tmp/qa-rehearsal")); ' \
      "File.write(File.join(root, 'tmp/qa-rehearsal/current.json'), #{STATE.inspect}); #{result}"
  end

  def kept_states(primary) = Dir.glob(File.join(primary, "tmp/qa-rehearsal/release-gauntlet-*.json"))

  def test_a_red_run_keeps_its_state_file_in_the_primary_before_the_tree_goes
    with_scratch_turf do |primary, _main_sha, release_sha|
      red = 'Release::DevnetGauntletRun::Result.new(ok: false, step: "settle", reason: "x", metadata: {})'
      out = tree_call(primary, release_sha, write_state_body(red))

      kept = kept_states(primary)
      assert_equal 1, kept.size, "the open contest's state survives the tree: #{out}"
      assert_equal STATE, File.read(kept.first)
      assert_includes File.basename(kept.first), "release-gauntlet-#{release_sha[0, 7]}-"
      refute File.exist?(File.join(primary, "tmp/qa-rehearsal/current.json")), "never over the primary's own state"
      assert_includes out, "kept the gauntlet's devnet state: #{kept.first}"
      refute File.exist?(tree_path(out)), "the tree itself still goes"
    end
  end

  def test_a_raise_keeps_the_state_file_too
    with_scratch_turf do |primary, _main_sha, release_sha|
      out = tree_call(primary, release_sha, write_state_body('raise "boom"'), rescue_it: true)
      assert_includes out, "RAISED boom"
      assert_equal 1, kept_states(primary).size
    end
  end

  def test_a_green_run_keeps_nothing
    with_scratch_turf do |primary, _main_sha, release_sha|
      green = "Release::DevnetGauntletRun::Result.new(ok: true, step: nil, reason: nil, metadata: {})"
      tree_call(primary, release_sha, write_state_body(green))
      assert_empty kept_states(primary)
    end
  end

  def test_a_stale_tree_a_killed_run_left_is_swept_with_its_state_kept_and_a_fresh_one_is_not
    with_scratch_turf do |primary, _main_sha, release_sha|
      Dir.mktmpdir("gauntlet-root") do |root|
        stale = File.join(root, "gauntlet-turf-monster-killed")
        FileUtils.mkdir_p(File.join(stale, "tmp/qa-rehearsal"))
        File.write(File.join(stale, ".env"), "SECRET_COPY=1\n")
        File.write(File.join(stale, "tmp/qa-rehearsal/current.json"), STATE)
        File.utime(Time.now - 86_400, Time.now - 86_400, stale)
        fresh = File.join(root, "gauntlet-turf-monster-inflight")
        FileUtils.mkdir_p(fresh)

        out = tree_call(primary, release_sha, ":ran", tmp_root: root)

        refute File.exist?(stale), "the killed run's tree (and its .env copy) is gone: #{out}"
        assert File.exist?(fresh), "a tree inside the deadline may be a run in flight"
        assert_includes out, "sweeping a stale gauntlet tree a killed run left behind: #{stale}"
        kept = kept_states(primary)
        assert_equal 1, kept.size
        assert_includes File.basename(kept.first), "release-gauntlet-stale-"
        assert tree_path(out).start_with?(root), "the new tree is cut under the same root it sweeps"
      end
    end
  end

  # --- the tree's bundle runs through its own bundler, bounded ---------------------

  def bundle_call(binstub:)
    Dir.mktmpdir("gauntlet-bundle") do |dir|
      if binstub
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin", "bundle"), "#!/bin/sh\n")
      end
      setup = <<~RUBY
        def sh(*cmd, capture: false, chdir: nil, env: nil, deadline: nil, deadline_env: nil)
          $stdout.puts("SH " + cmd.join(" ") + " deadline_env=" + deadline_env.to_s)
          ["", cmd.include?("install")]
        end
      RUBY
      run_cli([], setup: setup, call: "puts('BUNDLE ' + bundle_gauntlet_tree(#{dir.inspect}).inspect)")
    end
  end

  def test_the_tree_bundles_through_its_binstub_like_every_release_tree
    out = bundle_call(binstub: true)

    assert_includes out, "SH bin/bundle check deadline_env=RELEASE_GAUNTLET_DEADLINE"
    assert_includes out, "SH bin/bundle install --quiet deadline_env=RELEASE_GAUNTLET_DEADLINE"
    refute_match(/^SH bundle /, out, "never the conductor PATH's bare bundle")
    assert_includes out, "BUNDLE nil"
  end

  def test_without_a_binstub_the_tree_bundles_through_ruby_s_bundle
    out = bundle_call(binstub: false)
    assert_includes out, "SH ruby -S bundle check"
  end

  # --- the overall deadline starts before the tree is cut --------------------------

  def test_the_deadline_clock_is_read_before_the_tree_is_cut
    extra = <<~RUBY
      def gauntlet_clock = ($stdout.puts("CLOCK-READ"); 4242.0)
      def with_gauntlet_tree(_turf, _shas) = ($stdout.puts("TREE-CUT"); yield("/tmp/tree"))
    RUBY
    out = gauntlet(repos: TURF, result: { ok: true, step: nil, reason: nil, metadata: GREEN_META }, extra: extra)

    assert_operator out.index("CLOCK-READ"), :<, out.index("TREE-CUT"), "the clock starts before the cut"
    assert_includes out, "RUNNER-ROOT /tmp/tree STARTED-AT 4242.0", "the runner counts from that reading"
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

  # --- the warm tree: one persistent turf-monster worktree, reused --------------------

  # A body that reports what the driver's tree holds, then plants a stray, the caches
  # and a state file for the next run to find (or not).
  WARM_BODY = 'out, ok = run_gauntlet_step(root, ["seed"]); ' \
              'puts("STEP " + out.strip + " ok=" + ok.to_s); ' \
              'puts("HEAD " + `git -C #{root} rev-parse HEAD`.strip); ' \
              "%w[STRAY vendor/bundle/gem.rb node_modules/pkg.js tmp/cache/bootsnap/c tmp/qa-rehearsal/current.json tmp/log.txt]" \
              '.each { |f| puts("SAW " + f + "=" + File.exist?(File.join(root, f)).to_s) }; ' \
              'puts("ENV-MODE " + format("%o", File.stat(File.join(root, ".env")).mode & 0o777)); ' \
              "%w[STRAY vendor/bundle/gem.rb node_modules/pkg.js tmp/cache/bootsnap/c tmp/qa-rehearsal/current.json tmp/log.txt]" \
              '.each { |f| FileUtils.mkdir_p(File.dirname(File.join(root, f))); File.write(File.join(root, f), "x") }; :ran'

  def saw(out, file) = out[/^SAW #{Regexp.escape(file)}=(\w+)$/, 1]

  def with_warm_root
    Dir.mktmpdir("gauntlet-warm") { |dir| yield File.join(dir, "cache", "turf-monster-gauntlet") }
  end

  def test_the_warm_tree_is_reused_across_runs_at_each_release_sha_and_wiped_but_its_caches
    with_scratch_turf do |primary, main_sha, release_sha|
      with_warm_root do |warm|
        first = tree_call(primary, release_sha, WARM_BODY, warm: warm)
        assert_includes first, "(#{warm}), the tree prepare deployed to QA (warm tree, reused)"
        assert_match(/STEP driver B seed in \S*turf-monster-gauntlet ok=true/, first, "B's driver, from the warm tree")
        assert_includes first, "HEAD #{release_sha}"
        assert File.directory?(warm), "the warm tree stays after the run"
        assert_equal 2, `git -C #{primary} worktree list`.lines.size, "the warm tree stays registered"
        assert File.exist?(File.join(warm, "vendor/bundle/gem.rb")), "caches survive the end-of-run wipe"
        refute File.exist?(File.join(warm, "STRAY")), "strays go at the end of the run"

        second = tree_call(primary, main_sha, WARM_BODY, warm: warm)
        assert_includes second, "(#{warm}), the tree prepare deployed to QA (warm tree, reused)", "the same tree: #{second}"
        assert_match(/STEP driver A seed in \S*turf-monster-gauntlet ok=true/, second, "moved to the next release's SHA")
        assert_includes second, "HEAD #{main_sha}"
        %w[vendor/bundle/gem.rb node_modules/pkg.js tmp/cache/bootsnap/c].each do |cache|
          assert_equal "true", saw(second, cache), "#{cache} is a cache the warm tree keeps"
        end
        %w[STRAY tmp/qa-rehearsal/current.json tmp/log.txt].each do |stray|
          assert_equal "false", saw(second, stray), "#{stray} from the last run is gone before this one"
        end
        assert_equal 2, `git -C #{primary} worktree list`.lines.size, "still one warm registration, not two"
        assert_equal "A", `git -C #{primary} log -1 --format=%s`.strip, "the primary checkout is untouched"
      end
    end
  end

  def test_a_stray_left_by_a_killed_run_is_wiped_before_the_next_run
    with_scratch_turf do |primary, _main_sha, release_sha|
      with_warm_root do |warm|
        tree_call(primary, release_sha, ":ran", warm: warm)
        File.write(File.join(warm, "STRAY"), "x") # a SIGKILL skipped the end-of-run wipe
        FileUtils.mkdir_p(File.join(warm, "tmp/qa-rehearsal"))
        File.write(File.join(warm, "tmp/qa-rehearsal/current.json"), STATE)
        File.write(File.join(warm, "bin/qa-contest-rehearsal"), "#!/bin/sh\necho tampered\n") # tracked, edited

        out = tree_call(primary, release_sha, WARM_BODY, warm: warm)
        assert_equal "false", saw(out, "STRAY")
        assert_equal "false", saw(out, "tmp/qa-rehearsal/current.json")
        assert_match(/STEP driver B seed/, out, "a tracked file edited in the tree is reset to the commit")
      end
    end
  end

  def test_env_copies_are_0600_never_printed_and_gone_after_a_warm_run
    with_scratch_turf do |primary, _main_sha, release_sha|
      File.chmod(0o644, File.join(primary, ".env"))
      with_warm_root do |warm|
        out = tree_call(primary, release_sha, WARM_BODY, warm: warm)
        assert_includes out, "ENV-MODE 600", "the copy is the owner's alone, whatever the primary's mode"
        refute_includes out, "FROM_PRIMARY", "an env file's contents are never printed"
        refute File.exist?(File.join(warm, ".env")), "the warm tree keeps no .env copy between runs"
      end
    end
  end

  def test_the_cold_cut_writes_its_env_copies_0600_too
    with_scratch_turf do |primary, _main_sha, release_sha|
      File.chmod(0o644, File.join(primary, ".env"))
      out = tree_call(primary, release_sha, 'puts("ENV-MODE " + format("%o", File.stat(File.join(root, ".env")).mode & 0o777)); :ran')
      assert_includes out, "(cold cut)"
      assert_includes out, "ENV-MODE 600"
    end
  end

  def test_a_tree_whose_head_is_not_the_release_sha_is_refused
    with_scratch_turf do |primary, main_sha, release_sha|
      call = "puts('VERIFY ' + verify_gauntlet_tree(#{primary.inspect}, #{release_sha.inspect}).inspect); " \
             "puts('MATCH ' + verify_gauntlet_tree(#{primary.inspect}, #{main_sha.inspect}).inspect)"
      out = run_cli([], call: call)
      assert_match(/VERIFY ".*HEAD is .*not #{release_sha[0, 7]}"/, out)
      assert_includes out, "MATCH nil"
    end
  end

  def test_a_warm_tree_git_cannot_move_is_discarded_and_cut_afresh
    with_scratch_turf do |primary, main_sha, release_sha|
      with_warm_root do |warm|
        tree_call(primary, release_sha, ":ran", warm: warm)
        gitdir = File.read(File.join(warm, ".git"))[/gitdir: (.+)/, 1].strip
        File.write(File.join(gitdir, "index.lock"), "") # a killed git left its lock: checkout fails

        out = tree_call(primary, main_sha, WARM_BODY, warm: warm)
        assert_includes out, "discarding a broken one"
        assert_includes out, "(warm tree, reused)"
        assert_includes out, "HEAD #{main_sha}"
        assert_equal 2, `git -C #{primary} worktree list`.lines.size
      end
    end
  end

  def test_a_warm_path_holding_something_else_is_left_alone_and_the_run_falls_back_to_the_cold_cut
    with_scratch_turf do |primary, _main_sha, release_sha|
      with_warm_root do |warm|
        FileUtils.mkdir_p(warm)
        File.write(File.join(warm, "precious.txt"), "not ours")

        out = tree_call(primary, release_sha, WARM_BODY, warm: warm)
        assert_includes out, "is unusable"
        assert_includes out, "(cold cut)"
        assert_match(/STEP driver B seed in \S*gauntlet-turf-monster-\S+ ok=true/, out)
        assert_equal "not ours", File.read(File.join(warm, "precious.txt")), "never deleted"
        refute File.exist?(tree_path(out)), "the cold tree still goes"
        assert_equal 1, `git -C #{primary} worktree list`.lines.size
      end
    end
  end

  def test_a_warm_tree_another_run_holds_is_not_shared
    with_scratch_turf do |primary, _main_sha, release_sha|
      with_warm_root do |warm|
        FileUtils.mkdir_p(File.dirname(warm))
        File.open("#{warm}.lock", File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          out = tree_call(primary, release_sha, ":ran", warm: warm)
          assert_includes out, "held by another run; cold cut instead"
          assert_includes out, "(cold cut)"
          refute File.exist?(warm), "the held tree is not touched"
        end
      end
    end
  end

  def test_a_warm_path_inside_turf_monster_is_refused
    with_scratch_turf do |primary, _main_sha, release_sha|
      out = tree_call(primary, release_sha, ":ran", warm: File.join(primary, "tmp", "warm"))
      assert_includes out, "is inside a turf-monster checkout or a managed desk root; cold cut instead"
      assert_includes out, "(cold cut)"
      out = tree_call(primary, release_sha, ":ran", warm: primary)
      assert_includes out, "(cold cut)", "never the primary itself: #{out}"
      assert_equal "A", `git -C #{primary} log -1 --format=%s`.strip
    end
  end

  def test_the_stale_sweep_never_deletes_the_warm_tree
    with_scratch_turf do |primary, _main_sha, release_sha|
      Dir.mktmpdir("gauntlet-root") do |root|
        # The worst case: a warm tree whose name the cold sweep's glob matches.
        warm = File.join(root, "gauntlet-turf-monster-warm")
        tree_call(primary, release_sha, ":ran", tmp_root: root, warm: warm)
        File.utime(Time.now - 86_400, Time.now - 86_400, warm)

        out = tree_call(primary, release_sha, ":ran", tmp_root: root, warm: warm)
        refute_includes out, "sweeping a stale gauntlet tree"
        assert_includes out, "(#{warm}), the tree prepare deployed to QA (warm tree, reused)"
        assert File.directory?(warm)
      end
    end
  end

  def test_an_unknown_release_sha_with_a_warm_tree_is_red_at_tree_and_keeps_the_warm_tree
    with_scratch_turf do |primary, _main_sha, release_sha|
      with_warm_root do |warm|
        tree_call(primary, release_sha, ":ran", warm: warm)
        out = tree_call(primary, "f" * 40, ":ran", warm: warm)
        assert_match(/RESULT .*step="tree".*could not cut a turf-monster worktree/m, out)
        assert File.directory?(warm), "a bad SHA is the release's fault, not the tree's"
      end
    end
  end

  def test_a_red_warm_run_keeps_its_state_before_the_wipe
    with_scratch_turf do |primary, _main_sha, release_sha|
      with_warm_root do |warm|
        red = 'Release::DevnetGauntletRun::Result.new(ok: false, step: "settle", reason: "x", metadata: {})'
        out = tree_call(primary, release_sha, write_state_body(red), warm: warm)
        assert_includes out, "(warm tree, reused)"
        assert_equal [STATE], kept_states(primary).map { |f| File.read(f) }
        refute File.exist?(File.join(warm, GAUNTLET_STATE)), "the warm tree holds no state once kept"
      end
    end
  end

  GAUNTLET_STATE = "tmp/qa-rehearsal/current.json"
end
