# frozen_string_literal: true

# [integration] `bin/release ship` refuses a Turf release with no devnet gauntlet
# recorded (Release::DevnetGauntlet), before its preflight: nothing is published,
# pushed or deployed. Drives the real ship against stubbed conductor reads; no
# board, no git, no deploy.
#
#   ruby -Itest test/lib/release_ship_devnet_gauntlet_test.rb
require_relative "release_cli_harness"

class ReleaseShipDevnetGauntletTest < ReleaseCliHarness
  RECORD = { "occurred_at" => "2026-10-11T15:00:00Z", "actor" => "turf_monster", "metadata" => {} }.freeze

  # The snapshot names `repos`; `gauntlet: :absent` omits the key entirely.
  def ship_with(repos:, gauntlet:, argv: ["--yes"])
    snapshot = { "slug" => "rel-g", "state" => "assembled", "branch" => "release", "qa_shas" => {},
                 "repos" => repos.map { |r| { "repo" => r, "kind" => "app", "members" => [] } } }
    snapshot["devnet_gauntlet"] = gauntlet unless gauntlet == :absent
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        return { "slug" => "rel-g" } if ruby.include?("last_shipped")
        $stdout.puts("SNAPSHOT-ASKS-GAUNTLET") if ruby.include?("devnet_gauntlet")
        JSON.parse(#{JSON.generate(snapshot).inspect})
      end
      def conductor_claim(*a) = ReleaseClaimCli::OK
      def frozen_sha_for(*) = "abc123"
      def ship_preflight(*) = ($stdout.puts("PREFLIGHT-REACHED"); raise(SystemExit))
      def abort!(msg) = ($stdout.puts("ABORT: " + msg); raise(SystemExit))
    RUBY
    run_cli(argv, setup: setup, call: "begin; ship; rescue SystemExit => e; puts('EXIT: ' + e.message); end")
  end

  def test_a_turf_release_without_a_gauntlet_is_refused_before_the_preflight
    out = ship_with(repos: %w[mcritchie-studio turf-monster], gauntlet: nil)

    assert_includes out, "SNAPSHOT-ASKS-GAUNTLET", "the decision snapshot reads the record"
    assert_includes out, "ABORT: this release carries turf-monster and has NO devnet gauntlet recorded"
    refute_includes out, "PREFLIGHT-REACHED", "refused before anything is built, pushed or deployed"
  end

  def test_a_recorded_gauntlet_lets_the_ship_proceed
    out = ship_with(repos: %w[turf-vault], gauntlet: RECORD)

    assert_includes out, "devnet gauntlet recorded 2026-10-11T15:00:00Z by turf_monster for turf-vault"
    assert_includes out, "PREFLIGHT-REACHED"
  end

  def test_a_release_with_no_turf_work_is_not_asked
    out = ship_with(repos: %w[mcritchie-studio], gauntlet: nil)

    refute_includes out, "devnet gauntlet"
    assert_includes out, "PREFLIGHT-REACHED"
  end

  def test_alexs_words_waive_it_loudly
    out = ship_with(repos: %w[turf-monster], gauntlet: nil,
                    argv: ["--yes", "--skip-devnet-gauntlet", "devnet RPC is down; ship the copy fix"])

    assert_includes out, "⚠ NO devnet gauntlet is recorded for turf-monster; shipping on --skip-devnet-gauntlet"
    assert_includes out, "PREFLIGHT-REACHED"
  end

  def test_the_guard_accepts_the_override_flag_on_ship
    call = 'guard_argv!(["ship", "--skip-devnet-gauntlet", "words"], exiter: ->(code) { puts("EXITED " + code.to_s) }); ' \
           'puts("GUARD-PASSED")'
    out = run_cli([], call: call)

    assert_includes out, "GUARD-PASSED"
    refute_includes out, "EXITED"
  end
end
