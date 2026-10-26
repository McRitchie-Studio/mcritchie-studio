# frozen_string_literal: true

# THE APP DEPLOYS RUN IN PARALLEL AFTER THE GEM PHASE, as bin/release drives them
# (deploy_apps → deploy_satellites_in_parallel). The pool, the partial-failure rule
# and the prefixed output are unit-tested in test/models/release/parallel_deploy_test.rb;
# these drive the real CLI path.
#
#   ruby -Itest test/lib/release_parallel_deploy_cli_test.rb

require_relative "release_cli_harness"

class ReleaseParallelDeployCliTest < ReleaseCliHarness
  SHAS = { "mcritchie-studio" => "a" * 40, "turf-monster" => "b" * 40, "rantly" => "c" * 40, "moms-app" => "d" * 40 }.freeze
  GROUPS = SHAS.keys.map { |r| { "repo" => r, "members" => [] } }.freeze

  # deploy_app is stubbed: each app announces itself, waits briefly, and the apps in
  # `fail` abort exactly as the real one does (abort!).
  def stub(fail: [], live: [])
    <<~RUBY
      $events = Queue.new
      $recorded = []
      def deploy_app(group, frozen)
        repo = group["repo"]
        $events << "start:\#{repo}"
        if #{live.inspect}.include?(repo)
          say("  ALREADY live — skipping re-dispatch")
          $events << "done:\#{repo}"
          return
        end
        sleep 0.2
        abort!("\#{repo} deploy script failed (bin/deploy) — its own rollback applies") if #{fail.inspect}.include?(repo)
        say("deployed \#{repo} @ \#{frozen[0, 7]}")
        $events << "done:\#{repo}"
      end
      def record_deployed_apps(_slug, groups, _shas) = ($recorded.concat(groups.map { |g| g["repo"] }))
    RUBY
  end

  def drive(setup)
    run_cli(["--yes"], setup: setup, call: <<~CALL)
      begin
        deploy_apps(#{GROUPS.inspect}, #{SHAS.inspect}, "rel-x")
        puts "RESULT=ok"
      rescue SystemExit => e
        puts "RESULT=aborted"
        puts "ABORT=\#{e.message}"
      end
      events = []
      events << $events.pop until $events.empty?
      puts "EVENTS=\#{events.join(',')}"
      puts "RECORDED=\#{$recorded.join(',')}"
    CALL
  end

  def events(out) = out[/EVENTS=(.*)/, 1].to_s.split(",")

  # [integration] The hub deploys first and alone; the satellites then overlap.
  def test_the_hub_deploys_first_then_the_satellites_run_concurrently
    out = drive(stub)
    ev = events(out)

    assert_includes out, "RESULT=ok", out
    assert_equal %w[start:mcritchie-studio done:mcritchie-studio], ev.first(2), "the hub finishes before any satellite starts"
    satellite_starts = ev.each_index.select { |i| ev[i].start_with?("start:") }.drop(1)
    first_done = ev.index { |e| e.start_with?("done:") && e != "done:mcritchie-studio" }
    assert satellite_starts.all? { |i| i < first_done }, "every satellite started before the first one finished: #{ev}"
    assert_includes out, "3 satellites CONCURRENTLY"
    assert_includes out, "[rantly] deployed rantly @ ccccccc", "a satellite's lines carry its prefix"
    assert_equal %w[mcritchie-studio moms-app rantly turf-monster], out[/RECORDED=(.*)/, 1].split(",").sort
  end

  # [integration] PARTIAL FAILURE: turf fails; rantly and moms-app still go live and
  # are recorded; the ship aborts naming both halves, and nothing is rolled back.
  def test_one_failing_satellite_does_not_stop_the_others_and_the_ship_names_who_is_live
    out = drive(stub(fail: ["turf-monster"]))

    assert_includes out, "RESULT=aborted"
    assert_includes events(out), "done:rantly"
    assert_includes events(out), "done:moms-app"
    assert_equal %w[mcritchie-studio moms-app rantly], out[/RECORDED=(.*)/, 1].split(",").sort,
                 "the record names exactly the apps that went live"
    assert_includes out, "✗ FAILED turf-monster"
    assert_includes out, "1 of 3 satellite deploys FAILED (turf-monster); LIVE on production: rantly, moms-app"
    log = out[%r{\(log: (\S+/turf-monster\.log)\)}, 1]
    assert log && File.read(log).include?("✗ turf-monster deploy script failed"),
           "the failing app's own abort (stderr) lands in its log: #{log}"
  end

  # [integration] A hub failure aborts before any satellite moves (the order that stays).
  def test_a_hub_failure_aborts_before_any_satellite_moves
    out = drive(stub(fail: ["mcritchie-studio"]))

    assert_includes out, "RESULT=aborted"
    assert_equal ["start:mcritchie-studio"], events(out)
    assert_equal "", out[/RECORDED=(.*)/, 1].to_s
  end

  # [integration] RESUME: an app already live is skipped (deploy_already_succeeded?
  # answers inside deploy_app) while the unfinished one deploys.
  def test_a_rerun_deploys_only_the_unfinished_apps
    out = drive(stub(live: %w[mcritchie-studio rantly moms-app]))

    assert_includes out, "RESULT=ok"
    assert_includes out, "[rantly]   ALREADY live — skipping re-dispatch"
    assert_includes out, "[turf-monster] deployed turf-monster"
  end

  # [integration] A satellite's CHILD PROCESS output is prefixed too: sh streams it
  # through $stdout instead of letting the child inherit the terminal.
  def test_child_process_output_is_prefixed_per_app
    Dir.mktmpdir do |dir|
      repos = %w[sat-one sat-two]
      clones = repos.to_h { |r| [r, build_sibling_fixture(File.join(dir, r).tap { |d| FileUtils.mkdir_p(d) })] }
      probe = File.join(dir, "probe.sh")
      File.write(probe, "#!/usr/bin/env sh\necho \"child says hello\"\necho \"child stderr\" >&2\n")
      File.chmod(0o755, probe)
      groups = repos.map do |r|
        { "repo" => r, "members" => [],
          "prod_deploy" => { "strategy" => "repo_script", "command" => probe, "args" => [] } }
      end
      shas = clones.to_h { |r, c| [r, git_out(c, "rev-parse", "release")] }
      setup = %(CLONES = #{clones.inspect}\ndef repo_path(repo) = CLONES.fetch(repo)\n) +
              %(def record_merged_main(_s); end\ndef record_deployed_apps(*); end\n)
      out = run_cli(["--yes"], setup: setup,
                               call: %{deploy_apps(#{groups.inspect}, #{shas.inspect}, "rel-x"); puts("PASSED")})

      assert_includes out, "PASSED", out
      repos.each do |r|
        assert_includes out, "[#{r}] child says hello", "#{r}'s child stdout is prefixed"
        assert_includes out, "[#{r}] child stderr", "…and its stderr"
      end
    end
  end
end
