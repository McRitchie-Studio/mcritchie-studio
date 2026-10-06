# frozen_string_literal: true

# `bin/release rollback`: the previous shipped SHA per app, redeployed through each
# app's strategy, with the board record. Every seam that could reach production,
# Heroku, GitHub or the board is stubbed: the conductor, git reads, the Heroku
# release read, the workflow dispatch, the shell and the /up poll.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_rollback_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliRollbackTest < ReleaseCliHarness
  HUB_NEW = "4ab2222222222222222222222222222222222222"
  HUB_OLD = "4ab1111111111111111111111111111111111111"
  TURF_NEW = "7ff2222222222222222222222222222222222222"
  TURF_OLD = "7ff1111111111111111111111111111111111111"

  READ = {
    "release" => {
      "slug" => "rel-new", "state" => "shipped", "deployed_sha" => HUB_NEW,
      "shipped_shas" => { "mcritchie-studio" => HUB_NEW, "turf-monster" => TURF_NEW },
      "repos" => [
        { "repo" => "studio-engine", "kind" => "gem", "members" => [{ "slug" => "t-gem", "version" => "0.91.0" }] },
        { "repo" => "mcritchie-studio", "kind" => "app",
          "prod_deploy" => { "strategy" => "github_actions", "workflow" => "prod-deploy.yml",
                             "smoke_url" => "https://mcritchie.studio" } },
        { "repo" => "turf-monster", "kind" => "app",
          "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy",
                             "heroku_app" => "turf-monster-mainnet", "smoke_url" => "https://turfmonster.media" } }
      ]
    },
    "history" => [{ "slug" => "rel-old", "shipped_shas" => { "mcritchie-studio" => HUB_OLD, "turf-monster" => TURF_OLD } }],
    "later" => nil, "shipping" => nil
  }.freeze

  HEROKU = [
    { "version" => 290, "current" => true, "status" => "succeeded", "description" => "Deploy #{TURF_NEW[0, 8]}" },
    { "version" => 286, "status" => "succeeded", "description" => "Deploy #{TURF_OLD[0, 8]}" }
  ].freeze

  # $calls collects every seam in order, so a test reads the sequence the command ran.
  def stub(migrations: [], dispatch_ok: true, heroku_ok: true)
    <<~RUBY
      $calls = []
      def conductor(ruby, read_only: false)
        $calls << [:conductor, read_only, ruby]
        return JSON.parse(#{READ.to_json.inspect}) if ruby.include?("Release::Conductor.repo_plan")
        {}
      end
      def git_capture(*args)
        $calls << [:git, args.join(" ")]
        return [#{migrations.join("\n").inspect}, true] if args.include?("diff")
        ["", true]
      end
      def heroku_releases(app, limit: 5)
        $calls << [:heroku_releases, app]
        JSON.parse(#{HEROKU.to_json.inspect})
      end
      def dispatch_and_watch(workflow, inputs = {}, chdir: nil)
        $calls << [:dispatch, workflow, inputs]
        #{dispatch_ok}
      end
      def sh(*a, **_k)
        $calls << [:sh, a.join(" ")]
        ["", a.first == "heroku" ? #{heroku_ok} : true]
      end
      def wait_for_boot(url, attempts: 30, delay: 5)
        $calls << [:smoke, url]
        true
      end
      def acquire_conductor_claim!(role, slug, span_close: nil) = $calls << [:claim, role, slug]
      def release_conductor_claim!(role: nil, slug: nil); end
      def agent_activity(*_a); end
      def warn_local!; end
      def repo_path(repo) = "/tmp/" + repo
    RUBY
  end

  ROLLBACK = "rollback(Release::Cli.positional_slugs(ARGV).first)"
  CALL = "begin; #{ROLLBACK}; rescue SystemExit => e; puts 'EXIT=' + e.status.to_s + ' ' + e.message.to_s; end; puts 'CALLS=' + $calls.to_json".freeze

  def calls(out) = JSON.parse(out.lines.find { |l| l.start_with?("CALLS=") }.delete_prefix("CALLS="))
  def deploys(out) = calls(out).select { |c| %w[dispatch sh].include?(c[0]) }
  def writes(out) = calls(out).select { |c| c[0] == "conductor" && c[1] == false }.map(&:last)

  def test_rollback_sequence_deploys_each_app_and_records_the_event
    out = run_cli(["rel-new", "--mode", "auto", "--by", "steffon"], setup: stub, call: CALL)

    refute_includes out, "EXIT=", "a clean rollback does not abort"
    assert_equal [["sh", "heroku rollback v286 --app turf-monster-mainnet"],
                  ["dispatch", "prod-deploy.yml", { "sha" => HUB_OLD }]],
                 deploys(out), "turf rolls back to the Heroku release that deployed its previous SHA, then the hub " \
                               "redeploys its previous SHA through the prod-deploy workflow, hub last"
    assert_equal [["smoke", "https://turfmonster.media"]], calls(out).select { |c| c[0] == "smoke" },
                 "the satellite is smoked on /up; the hub's workflow smokes itself"
    refute(calls(out).any? { |c| c.join(" ").include?("origin main") || c.join(" ").include?("push origin") },
           "no ref moves: main is untouched")

    started, completed, restamp = writes(out)
    assert_includes started, %(step: "rollback", status: "started")
    assert_includes started, HUB_NEW, "the started event carries the shipped SHAs"
    assert_includes started, TURF_OLD, "…and the previous ones"
    assert_includes completed, "step: 'rollback', status: 'completed'"
    assert_includes completed, "SmokeSeal.from_result(passed: false", "the release gets a red seal"
    assert_includes completed, "rolled back: turf-monster 7ff22222 → 7ff11111; mcritchie-studio 4ab22222 → 4ab11111"
    assert_includes completed, "'rolled_back' =>"
    assert_includes restamp, %(seal: "red"), "G4's seal is re-stamped red"
    assert_includes out, "studio-engine 0.91.0: stays published on RubyGems"
    assert_includes out, "main is untouched"
  end

  def test_rollback_without_authority_prints_the_plan_and_deploys_nothing
    out = run_cli(["rel-new"], setup: stub, call: CALL)

    assert_includes out, "PLAN ONLY"
    assert_includes out, "turf-monster (repo_script): 7ff22222 → 7ff11111 (shipped by rel-old)"
    assert_includes out, "heroku rollback v286 --app turf-monster-mainnet"
    assert_includes out, "gh workflow run prod-deploy.yml -f sha=#{HUB_OLD}"
    assert_includes out, "bin/release rollback rel-new --mode ask"
    assert_empty deploys(out), "a plan deploys nothing"
    assert_empty writes(out), "a plan records nothing"
    refute(calls(out).any? { |c| c[0] == "claim" }, "a plan takes no deployer claim")
  end

  def test_rollback_dry_run_plans_even_with_authority_and_skips_the_heroku_read
    out = run_cli(["rel-new", "--mode", "auto", "--dry-run"], setup: stub, call: CALL)

    assert_includes out, "PLAN ONLY"
    assert_includes out, "<the release that deployed 7ff11111>"
    assert_empty deploys(out)
    assert_empty writes(out)
    refute(calls(out).any? { |c| c[0] == "heroku_releases" }, "--dry-run leaves Heroku unread")
  end

  def test_rollback_refuses_a_schema_ahead_release_naming_the_migration
    out = run_cli(["rel-new", "--mode", "auto"], setup: stub(migrations: ["db/migrate/20261006120000_add_cents.rb"]),
                                                  call: CALL)

    assert_includes out, "EXIT=1"
    assert_includes out, "db/migrate/20261006120000_add_cents.rb", "the refusal names the migration"
    assert_includes out, "nothing deployed"
    assert_empty deploys(out)
    assert_empty writes(out)
    diff = calls(out).find { |c| c[0] == "git" && c[1].include?("diff") }
    assert_includes diff[1], "--diff-filter=A #{TURF_OLD} #{TURF_NEW} -- db/migrate",
                    "the check diffs the previous tree against the shipped one by SHA, with no checkout"
  end

  def test_rollback_refuses_timed_authority
    out = run_cli(["rel-new", "--mode", "timed"], setup: stub, call: CALL)

    assert_includes out, "EXIT=1"
    assert_empty calls(out), "the mode is refused before the board is read"
  end

  def test_a_failed_app_rollback_records_failed_and_leaves_the_hub_alone
    out = run_cli(["rel-new", "--yes"], setup: stub(heroku_ok: false), call: CALL)

    assert_includes out, "EXIT=1"
    assert_includes out, "rollback of turf-monster failed"
    assert_equal [["sh", "heroku rollback v286 --app turf-monster-mainnet"]], deploys(out),
                 "the hub is not dispatched after a satellite fails"
    assert(writes(out).any? { |w| w.include?(%(step: "rollback", status: "failed")) }, "the failure is recorded")
    refute(writes(out).any? { |w| w.include?("status: 'completed'") }, "…and nothing records completion")
  end
end
