# frozen_string_literal: true

# [unit] bin/release cycle's LIVE deps (ReleaseCycleDeps), with the board and the
# per-app live probes stubbed in the child: the snapshot carries what QA verify's
# SHA-bound gauntlet check reads, and prod verify's SHA leg asks the finalize
# guard's probe (deploy_live_verdict) about each app at its frozen SHA. No test
# reaches the board, Heroku, GitHub or production.
#
#   ruby -Itest test/lib/release_cli_cycle_deps_test.rb
require_relative "release_cli_harness"

class ReleaseCliCycleDepsTest < ReleaseCliHarness
  PLAN = {
    "repos" => [
      { "repo" => "studio-engine", "kind" => "gem" },
      { "repo" => "mcritchie-studio", "kind" => "app", "prod_deploy" => { "strategy" => "git_push_heroku" } },
      { "repo" => "turf-monster", "kind" => "app", "prod_deploy" => { "strategy" => "git_push_heroku" } }
    ],
    "qa_shas" => { "mcritchie-studio" => "hub1111aaaa", "turf-monster" => "turf222bbbb", "studio-engine" => "gem0" }
  }.freeze

  def sha_call(plan:, live_turf: true)
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("BOARD-READ read_only=" + read_only.to_s + " " + ruby[/find_by!\\(slug: "([^"]+)"/, 1].to_s)
        #{plan.nil? ? 'raise("board down")' : "JSON.parse(#{JSON.generate(plan).inspect})"}
      end
      def deploy_live_verdict(group, frozen)
        $stdout.puts("PROBE " + group["repo"] + "@" + frozen)
        group["repo"] == "turf-monster" && !#{live_turf} ? [false, "current Heroku release is not at the frozen SHA"] : [true, ""]
      end
    RUBY
    run_cli([], setup: setup, call: 'puts("VERDICTS " + ReleaseCycleDeps.new.deployed_sha_verdicts("rel-s").to_json)')
  end

  def verdicts(out) = JSON.parse(out[/^VERDICTS (.*)$/, 1])

  def test_each_app_is_probed_at_the_frozen_qa_sha_and_gems_are_not
    out = sha_call(plan: PLAN, live_turf: false)

    assert_includes out, "BOARD-READ read_only=true rel-s"
    assert_includes out, "PROBE mcritchie-studio@hub1111aaaa"
    assert_includes out, "PROBE turf-monster@turf222bbbb"
    refute_includes out, "PROBE studio-engine", "a gem has no deployed app to probe"
    got = verdicts(out).to_h { |v| [v["repo"], [v["ok"], v["reason"]]] }
    assert_equal [true, ""], got["mcritchie-studio"]
    assert_equal [false, "current Heroku release is not at the frozen SHA"], got["turf-monster"]
  end

  def test_an_unreadable_release_answers_nil_so_prod_verify_fails_closed
    out = sha_call(plan: nil)

    assert_includes out, "VERDICTS null"
    refute_includes out, "PROBE"
  end

  def test_the_snapshot_carries_the_gauntlet_record_and_qa_shas_for_the_sha_bound_check
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("SNAPSHOT-RUBY " + ruby)
        { "current" => nil }
      end
      def forming_slug = nil
    RUBY
    out = run_cli([], setup: setup, call: "ReleaseCycleDeps.new.snapshot")
    ruby = out[/^SNAPSHOT-RUBY (.*)$/, 1].to_s

    assert_includes ruby, "gauntlet: g&.slice('occurred_at', 'actor', 'metadata', 'status')"
    assert_includes ruby, "qa_shas: (r.metadata['qa_shas'] || {})"
  end
end
