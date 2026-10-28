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
  def gauntlet(repos:, result: nil, recorded: false, usage: {}, skip: false)
    runner = if result
               "Release::DevnetGauntletRun::Result.new(**#{result.inspect})"
             else
               "raise('NO RUNNER MAY BE BUILT')"
             end
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("BOARD-READ read_only=" + read_only.to_s) if ruby.include?("devnet_gauntlet")
        { "recorded" => #{recorded} }
      end
      def devnet_gauntlet_runner
        o = Object.new
        o.define_singleton_method(:call) { $stdout.puts("RUNNER-CALLED"); #{runner} }
        o
      end
      def seed_gauntlet_usage(key) = $stdout.puts("SEEDED " + key)
      def capture_move_usage(key) = ($stdout.puts("CAPTURED " + key); #{usage.inspect})
      def record_release_event(slug, step, status, attrs)
        $stdout.puts("EVENT " + JSON.generate([slug, step, status, attrs]))
      end
      def abort!(msg) = ($stdout.puts("ABORT: " + msg); raise(SystemExit))
    RUBY
    call = "begin; puts('OUTCOME ' + prepare_devnet_gauntlet!('rel-g', #{repos.inspect}, skip: #{skip}).to_s); " \
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

  def test_an_already_gauntleted_release_runs_no_second_contest
    out = gauntlet(repos: TURF, recorded: true)

    assert_includes out, "BOARD-READ read_only=true"
    assert_includes out, "OUTCOME recorded"
    assert_includes out, "not running a second contest"
    refute_includes out, "RUNNER-CALLED"
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

  def test_a_red_step_records_fail_and_aborts_naming_the_step
    meta = { "contest" => "rehearsal-abc", "failed_step" => "play", "steps" => {} }
    out = gauntlet(repos: TURF, result: { ok: false, step: "play", reason: "replay: CATCH-UP FAILED — x", metadata: meta })

    _, step, status, attrs = event(out)
    assert_equal %w[devnet_gauntlet failed], [step, status]
    assert_equal "play", attrs.dig("metadata", "failed_step")
    assert_includes out, "ABORT: devnet gauntlet RED at step `play`: replay: CATCH-UP FAILED — x"
    assert_includes out, "EXITED"
    refute_includes out, "OUTCOME"
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
end
