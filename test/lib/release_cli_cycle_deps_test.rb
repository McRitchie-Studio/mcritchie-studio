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
      { "repo" => "turf-monster", "kind" => "app", "prod_deploy" => { "strategy" => "git_push_heroku" } },
      # The release repo registry: turf-vault and chain-ops are apps with NO prod_deploy.
      { "repo" => "turf-vault", "kind" => "app" },
      { "repo" => "chain-ops", "kind" => "app", "prod_deploy" => {} }
    ],
    "qa_shas" => { "mcritchie-studio" => "hub1111aaaa", "turf-monster" => "turf222bbbb", "studio-engine" => "gem0",
                   "turf-vault" => "vault333" },
    "shipped_shas" => { "turf-monster" => "repin444cccc" }
  }.freeze

  def sha_call(plan:, live_turf: true)
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("BOARD-READ read_only=" + read_only.to_s + " " + ruby[/find_by!\\(slug: "([^"]+)"/, 1].to_s)
        #{plan.nil? ? 'raise("board down")' : "JSON.parse(#{JSON.generate(plan).inspect})"}
      end
      class ReleaseCycleDeps
        private def mint(identity, _env) = "fake-#{'#'}{identity}-token"
      end
      ENV["GH_TOKEN"] = "outer-login"
      def deploy_live_verdict(group, frozen, post_ship: false)
        $stdout.puts("PROBE " + group["repo"] + "@" + frozen + " post_ship=" + post_ship.to_s + " gh=" + ENV["GH_TOKEN"].to_s)
        group["repo"] == "turf-monster" && !#{live_turf} ? [false, "current Heroku release is not at the frozen SHA"] : [true, ""]
      end
    RUBY
    run_cli([], setup: setup, call: 'puts("VERDICTS " + ReleaseCycleDeps.new.deployed_sha_verdicts("rel-s").to_json); ' \
                                    'puts("GH-AFTER " + ENV["GH_TOKEN"].to_s)')
  end

  def verdicts(out) = JSON.parse(out[/^VERDICTS (.*)$/, 1])

  def test_each_app_is_probed_at_the_frozen_qa_sha_and_gems_are_not
    out = sha_call(plan: PLAN, live_turf: false)

    assert_includes out, "BOARD-READ read_only=true rel-s"
    assert_includes out, "PROBE mcritchie-studio@hub1111aaaa"
    assert_includes out, "PROBE turf-monster@repin444cccc", "shipped_shas (what the ship pushed) before qa_shas"
    refute_includes out, "PROBE studio-engine", "a gem has no deployed app to probe"
    got = verdicts(out).to_h { |v| [v["repo"], [v["ok"], v["reason"]]] }
    assert_equal [true, ""], got["mcritchie-studio"]
    assert_equal [false, "current Heroku release is not at the frozen SHA"], got["turf-monster"]
  end

  # Carl's blocker: turf-vault and chain-ops have no prod_deploy, so a release
  # carrying either exited 5 on a healthy ship. Only deploy targets are asked.
  def test_apps_with_no_prod_deploy_are_not_probed
    out = sha_call(plan: PLAN)

    refute_includes out, "PROBE turf-vault"
    refute_includes out, "PROBE chain-ops"
    assert_equal %w[mcritchie-studio turf-monster], verdicts(out).map { |v| v["repo"] }.sort
  end

  def test_the_probe_is_the_post_ship_form_under_a_minted_agent_token_restored_after
    out = sha_call(plan: PLAN)

    assert_includes out, "PROBE turf-monster@repin444cccc post_ship=true gh=fake-agent-token",
                    "gh run list reads under the cycle's own agent token, never the shell's login"
    assert_includes out, "GH-AFTER outer-login", "the process env is restored after the read"
  end

  def test_an_unreadable_release_answers_nil_so_prod_verify_fails_closed
    out = sha_call(plan: nil)

    assert_includes out, "VERDICTS null"
    refute_includes out, "PROBE"
  end

  # The post-ship read walks past a config-only release (turf-monster's
  # EXPECTED_IDL_HASH set) to the frozen deploy; finalize keeps the strict read.
  def test_deploy_live_verdict_post_ship_accepts_a_config_set_after_the_deploy_and_finalize_does_not
    frozen = "0988886c1f2e3d4c5b6a798877665544332211aa"
    setup = <<~RUBY
      def heroku_releases(app, limit: 5)
        $stdout.puts("RELEASES " + app + " limit=" + limit.to_s)
        [{ "version" => 286, "description" => "Set EXPECTED_IDL_HASH config vars", "status" => "succeeded", "current" => true },
         { "version" => 285, "description" => "Deploy 0988886c", "status" => "succeeded", "current" => false }]
      end
      def prod_up_ok?(_url) = true
      def origin_main_sha(_repo) = #{frozen.inspect}
      def group_smoke_url(_group) = "https://turf.example"
    RUBY
    group = { "repo" => "turf-monster", "kind" => "app",
              "prod_deploy" => { "strategy" => "repo_script", "heroku_app" => "turf-monster-mainnet" } }
    call = "puts('POST ' + deploy_live_verdict(#{group.inspect}, #{frozen.inspect}, post_ship: true).inspect); " \
           "puts('FINALIZE ' + deploy_live_verdict(#{group.inspect}, #{frozen.inspect}).inspect)"
    out = run_cli([], setup: setup, call: call)

    assert_includes out, "RELEASES turf-monster-mainnet limit=20"
    assert_includes out, 'POST [true, ""]'
    assert_match(/FINALIZE \[false, /, out)
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
  # --- the Slack announce after a green prod verify ----------------------------

  def announce_call(answer:)
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("HUB read_only=" + read_only.to_s + " " + ruby)
        #{answer}
      end
      class ReleaseCycleDeps
        def http_status(_url) = "200"
      end
    RUBY
    verdicts = [{ "repo" => "turf-monster", "sha" => "turf222bbbb", "ok" => true, "reason" => "" }]
    run_cli([], setup: setup,
                call: "puts('LINE ' + ReleaseCycleDeps.new.announce('rel-s', repos: ['turf-monster'], " \
                      "verdicts: #{verdicts.inspect}))")
  end

  def test_announce_smokes_production_and_posts_through_the_hub_with_the_verdicts_prod_verify_read
    out = announce_call(answer: 'JSON.parse(\'{"line":"Slack posts: 5 sent / 0 failed","sent":5,"failed":0,"posts":[]}\')')

    hub = out[/^HUB read_only=false .*$/]
    refute_nil hub, out
    assert_includes hub, "Release::Conductor.announce_release(release: r"
    assert_includes hub, "dry_run: false"
    assert_includes hub, "turf222bbbb", "prod verify's SHA verdict rides to the hub; it is not read again"
    refute_includes out, "HUB read_only=true", "the cycle's repos and verdicts are reused: no extra board read"
    assert_includes out, "✓ smoke turf-monster: /up 200, / 200"
    assert_includes out, "LINE Slack posts: 5 sent / 0 failed"
  end

  def test_announce_that_the_hub_aborts_answers_a_failed_line_and_never_raises
    out = announce_call(answer: 'abort!("record op failed: heroku down")')

    assert_includes out, "Slack announce for rel-s did not complete; the ship stands"
    assert_includes out, "LINE Slack posts: 0 sent / 1 failed"
  end
end
