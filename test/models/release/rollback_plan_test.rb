require "test_helper"

class Release
  class RollbackPlanTest < ActiveSupport::TestCase
    HUB_ADAPTER = { "strategy" => "github_actions", "workflow" => "prod-deploy.yml", "smoke_url" => "https://mcritchie.studio" }.freeze
    TURF_ADAPTER = { "strategy" => "repo_script", "command" => "bin/deploy", "heroku_app" => "turf-monster-mainnet",
                     "smoke_url" => "https://turfmonster.media" }.freeze
    ROLIO_ADAPTER = { "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/rolio-prod.git",
                      "branch" => "main", "smoke_url" => "https://rolio.example" }.freeze

    def target(**over)
      {
        "slug" => "rel-new", "state" => "shipped", "deployed_sha" => "hub2222222",
        "shipped_shas" => { "mcritchie-studio" => "hub2222222", "turf-monster" => "aa22222222" },
        "repos" => [
          { "repo" => "studio-engine", "kind" => "gem", "members" => [{ "slug" => "t-gem", "version" => "0.91.0" }] },
          { "repo" => "mcritchie-studio", "kind" => "app", "prod_deploy" => HUB_ADAPTER },
          { "repo" => "turf-monster", "kind" => "app", "prod_deploy" => TURF_ADAPTER }
        ]
      }.merge(over)
    end

    # Newest first. rel-mid shipped only the hub, so turf's previous SHA is two back.
    def history
      [
        { "slug" => "rel-mid", "shipped_shas" => { "mcritchie-studio" => "hub1111111" } },
        { "slug" => "rel-old", "shipped_shas" => { "mcritchie-studio" => "hub0000000", "turf-monster" => "aa11111111" } }
      ]
    end

    def no_migrations = ->(_repo, _from, _to) { [] }

    test "[unit] rollback plan picks the prior shipped SHA per repo from the release record" do
      plan = RollbackPlan.build(target: target, history: history)

      assert_not plan.refused?, plan.refusals.inspect
      hub = plan.apps.find { |a| a.repo == "mcritchie-studio" }
      turf = plan.apps.find { |a| a.repo == "turf-monster" }
      assert_equal %w[hub2222222 hub1111111 rel-mid], [hub.from_sha, hub.to_sha, hub.to_release]
      assert_equal %w[aa22222222 aa11111111 rel-old], [turf.from_sha, turf.to_sha, turf.to_release],
                   "a release that did not touch turf is walked past, not read as turf's previous SHA"
    end

    test "[unit] the hub rolls back last, after the satellites" do
      plan = RollbackPlan.build(target: target, history: history)

      assert_equal %w[turf-monster mcritchie-studio], plan.apps.map(&:repo)
    end

    test "[unit] the hub falls back to deployed_sha on releases that predate shipped_shas" do
      plan = RollbackPlan.build(
        target: target("shipped_shas" => { "turf-monster" => "aa22222222" }),
        history: [{ "slug" => "rel-legacy", "deployed_sha" => "hubAAAAAAA" },
                  { "slug" => "rel-old", "shipped_shas" => { "turf-monster" => "aa11111111" } }]
      )

      hub = plan.apps.find { |a| a.repo == "mcritchie-studio" }
      assert_equal %w[hub2222222 hubAAAAAAA rel-legacy], [hub.from_sha, hub.to_sha, hub.to_release]
    end

    test "[unit] refuses when the shipped release carried a migration the previous SHA lacks" do
      lister = lambda do |repo, from, to|
        repo == "turf-monster" && from == "aa22222222" && to == "aa11111111" ? ["db/migrate/20261006_add_cents.rb"] : []
      end
      plan = RollbackPlan.build(target: target, history: history).check_migrations!(lister)

      assert plan.refused?
      refusal = plan.refusals.join("\n")
      assert_includes refusal, "turf-monster"
      assert_includes refusal, "db/migrate/20261006_add_cents.rb", "the refusal names the migration file"
      assert_equal ["db/migrate/20261006_add_cents.rb"], plan.apps.find { |a| a.repo == "turf-monster" }.migrations
    end

    test "[unit] an unreadable tree comparison refuses rather than passing the schema check" do
      plan = RollbackPlan.build(target: target, history: history).check_migrations!(->(*) { nil })

      assert plan.refused?
      assert_match(/schema check fails closed/, plan.refusals.join)
    end

    test "[unit] a release that is not shipped, or has a later shipped release, is refused" do
      assert_match(/not shipped/, RollbackPlan.build(target: target("state" => "assembled"), history: history).refusals.join)
      later = RollbackPlan.build(target: target, history: history, later: "rel-newer")
      assert_match(/roll back rel-newer first/, later.refusals.join)
      assert_empty later.apps, "a refused release plans no deploy"
      assert_match(/deploying to production now/,
                   RollbackPlan.build(target: target, history: history, shipping: "rel-next").refusals.join)
      assert_match(/already rolled back/,
                   RollbackPlan.build(target: target("rolled_back" => { "at" => "x" }), history: history).refusals.join)
    end

    test "[unit] an app with no earlier shipped SHA refuses instead of guessing" do
      plan = RollbackPlan.build(target: target, history: [{ "slug" => "rel-mid", "shipped_shas" => { "mcritchie-studio" => "hub1111111" } }])

      assert_match(/turf-monster: no earlier shipped release/, plan.refusals.join)
    end

    test "[unit] each strategy redeploys the previous SHA its own way" do
      plan = RollbackPlan.build(
        target: target("shipped_shas" => { "mcritchie-studio" => "hub2222222", "turf-monster" => "aa22222222",
                                           "rolio" => "rolio22222" },
                       "repos" => target["repos"] + [{ "repo" => "rolio", "kind" => "app", "prod_deploy" => ROLIO_ADAPTER }]),
        history: history + [{ "slug" => "rel-older", "shipped_shas" => { "rolio" => "rolio11111" } }]
      )
      plan.resolve_heroku_versions!(lambda do |app|
        assert_equal "turf-monster-mainnet", app
        [{ "version" => 290, "current" => true, "status" => "succeeded", "description" => "Deploy aa222222" },
         { "version" => 287, "status" => "succeeded", "description" => "Set EXPECTED_IDL_HASH config vars" },
         { "version" => 286, "status" => "succeeded", "description" => "Deploy aa111111" }]
      end)

      commands = plan.apps.to_h { |a| [a.repo, plan.command_for(a)] }
      assert_equal "gh workflow run prod-deploy.yml -f sha=hub1111111", commands["mcritchie-studio"]
      assert_equal "git -C rolio push --force https://git.heroku.com/rolio-prod.git rolio11111:refs/heads/main", commands["rolio"]
      assert_equal "heroku rollback v286 --app turf-monster-mainnet", commands["turf-monster"]
      assert_equal "", plan.smoke_url_for(plan.apps.find { |a| a.repo == "mcritchie-studio" }),
                   "the hub's workflow hard-gates on /up itself"
      assert_equal "https://turfmonster.media", plan.smoke_url_for(plan.apps.find { |a| a.repo == "turf-monster" })
    end

    test "[unit] a repo_script app whose previous deploy is not in the Heroku history refuses" do
      plan = RollbackPlan.build(target: target, history: history)
                         .resolve_heroku_versions!(->(_app) { [{ "version" => 9, "status" => "succeeded", "description" => "Deploy deadbeef" }] })

      assert_match(/no succeeded Heroku release on turf-monster-mainnet deployed aa111111/, plan.refusals.join)
    end

    test "[unit] a skipped Heroku read leaves the version to the real run" do
      plan = RollbackPlan.build(target: target, history: history).resolve_heroku_versions!(->(_app) { nil })

      assert_not plan.refused?
      assert_includes plan.command_for(plan.apps.first), "<the release that deployed aa111111>"
    end

    test "[unit] heroku_version_for skips the current release and failed deploys" do
      releases = [{ "version" => 5, "current" => true, "status" => "succeeded", "description" => "Deploy abcdef12" },
                  { "version" => 4, "status" => "failed", "description" => "Deploy abcdef12" },
                  { "version" => 3, "status" => "succeeded", "description" => "Deploy abcdef12" }]

      assert_equal 3, RollbackPlan.heroku_version_for(releases, "abcdef1234567890")
      assert_nil RollbackPlan.heroku_version_for(releases, "abc"), "a short SHA matches nothing"
    end

    test "[unit] gems are named and left published; the plan says main is untouched" do
      text = RollbackPlan.build(target: target, history: history).lines.join("\n")

      assert_includes text, "studio-engine 0.91.0: stays published on RubyGems"
      assert_includes text, "cannot be unpublished"
      assert_includes text, "main is untouched"
      assert_includes text, "heroku rollback restores that release's config vars"
    end

    test "[unit] authority: a plan by default, ask or auto on request, timed refused" do
      assert_equal "plan", RollbackPlan.authority(explicit: nil, assume_yes: false, dry: false)
      assert_equal "plan", RollbackPlan.authority(explicit: "auto", assume_yes: true, dry: true), "--dry-run always plans"
      assert_equal "auto", RollbackPlan.authority(explicit: nil, assume_yes: true, dry: false)
      assert_equal "ask", RollbackPlan.authority(explicit: "ask", assume_yes: false, dry: false)
      assert_raises(ArgumentError) { RollbackPlan.authority(explicit: "timed", assume_yes: false, dry: false) }
      assert_raises(ArgumentError) { RollbackPlan.authority(explicit: "now", assume_yes: false, dry: false) }
    end

    test "[unit] evidence and seal summary carry both SHAs per app" do
      plan = RollbackPlan.build(target: target, history: history).check_migrations!(no_migrations)

      assert_equal({ "turf-monster" => "aa22222222", "mcritchie-studio" => "hub2222222" }, plan.evidence["from"])
      assert_equal({ "turf-monster" => "aa11111111", "mcritchie-studio" => "hub1111111" }, plan.evidence["to"])
      assert_equal "rolled back: turf-monster aa222222 → aa111111; mcritchie-studio hub22222 → hub11111", plan.seal_summary
    end
    test "[unit] a rolled-back release is never a rollback target: R3 goes back to R1, not R2" do
      plan = RollbackPlan.build(
        target: target("slug" => "rel-r3"),
        history: [
          { "slug" => "rel-r2", "rolled_back" => { "at" => "2026-10-05T10:00:00Z" },
            "shipped_shas" => { "mcritchie-studio" => "hubBAD0000", "turf-monster" => "bb00000000" } },
          { "slug" => "rel-r1", "shipped_shas" => { "mcritchie-studio" => "hub1111111", "turf-monster" => "aa11111111" } }
        ]
      )

      assert_not plan.refused?, plan.refusals.inspect
      assert_equal({ "turf-monster" => "aa11111111", "mcritchie-studio" => "hub1111111" }, plan.evidence["to"])
      assert_equal %w[rel-r1 rel-r1], plan.apps.map(&:to_release), "R2's known-bad SHAs are walked past"
    end

    CONFIGURED = [
      { "version" => 307, "current" => true, "status" => "succeeded", "description" => "Deploy aa222222" },
      { "version" => 306, "status" => "succeeded", "description" => "Update REDIS_URL by heroku-redis" },
      { "version" => 305, "status" => "succeeded", "description" => "Set ACTIVE_STORAGE_BACKEND config vars" },
      { "version" => 304, "status" => "succeeded", "description" => "Deploy aa111111" }
    ].freeze

    test "[unit] the plan lists every config change the heroku rollback reverts, by name" do
      plan = RollbackPlan.build(target: target, history: history).resolve_heroku_versions!(->(_app) { CONFIGURED })
      turf = plan.apps.find { |a| a.repo == "turf-monster" }

      assert_equal 304, turf.heroku_version
      assert_equal ["v305 Set ACTIVE_STORAGE_BACKEND config vars", "v306 Update REDIS_URL by heroku-redis"],
                   turf.config_reverts, "config and add-on releases count; the Deploy rows do not"
      text = plan.lines.join("\n")
      assert_includes text, "REVERTS CONFIG: v305 Set ACTIVE_STORAGE_BACKEND config vars"
      assert_includes text, "REVERTS CONFIG: v306 Update REDIS_URL by heroku-redis"
    end

    test "[unit] --mode auto refuses a config revert; --mode ask may run it" do
      reverting = RollbackPlan.build(target: target, history: history).resolve_heroku_versions!(->(_app) { CONFIGURED })
      assert_match(/ACTIVE_STORAGE_BACKEND.*--mode auto and --yes never revert config/, reverting.authority_refusal("auto"))
      assert_nil reverting.authority_refusal("ask"), "ask shows the list and confirms it separately"

      clean = RollbackPlan.build(target: target, history: history)
                          .resolve_heroku_versions!(->(_app) { [CONFIGURED[0], CONFIGURED[3]] })
      assert_empty clean.config_reverts
      assert_nil clean.authority_refusal("auto"), "with nothing to revert, auto runs"
      assert_includes clean.lines.join("\n"), "reverts no config"
    end

    test "[unit] a retry finds the app already rolled back and reverts nothing more" do
      releases = [{ "version" => 308, "current" => true, "status" => "succeeded", "description" => "Rollback to v304" }] + CONFIGURED.map { |r| r.merge("current" => false) }
      plan = RollbackPlan.build(target: target, history: history).resolve_heroku_versions!(->(_app) { releases })
      turf = plan.apps.find { |a| a.repo == "turf-monster" }

      assert turf.already_live
      assert_empty turf.config_reverts
      assert_nil plan.authority_refusal("auto")
    end

    test "[unit] release_phase_verdict waits for the new release to be current and succeeded" do
      assert_equal :pending, RollbackPlan.release_phase_verdict(CONFIGURED, after: 307), "not created yet"
      pending = [{ "version" => 308, "current" => false, "status" => "pending", "description" => "Rollback to v304" }]
      assert_equal :pending, RollbackPlan.release_phase_verdict(pending + CONFIGURED, after: 307)
      failed = [{ "version" => 308, "status" => "failed", "description" => "Rollback to v304" }]
      assert_equal :failed, RollbackPlan.release_phase_verdict(failed + CONFIGURED, after: 307)
      live = [{ "version" => 308, "current" => true, "status" => "succeeded", "description" => "Rollback to v304" }]
      assert_equal :succeeded, RollbackPlan.release_phase_verdict(live, after: 307)
    end

    test "[unit] the devops backfill step prints only while it can apply" do
      plan = RollbackPlan.build(target: target, history: history).check_migrations!(no_migrations)

      assert_nil plan.devops_backfill_step(rake_in_target: false), "no rake in the target, no migration in range"
      assert_nil plan.devops_backfill_step(rake_in_target: nil), "an unread rake is not a present one"
      assert_includes plan.devops_backfill_step(rake_in_target: true),
                      "the hub target hub11111 carries lib/tasks/devops_columns_backfill.rake"
      assert_includes plan.devops_backfill_step(rake_in_target: true),
                      "heroku run bin/rails tasks:backfill_devops_columns --app mcritchie-studio"
    end

    test "[unit] a hub range adding the devops columns migration names the backfill step" do
      added = ->(repo, _f, _t) { repo == "mcritchie-studio" ? ["db/migrate/20261006150000_add_devops_columns_to_tasks.rb"] : [] }
      plan = RollbackPlan.build(target: target, history: history).check_migrations!(added)

      assert plan.refused?, "the schema check still refuses the range"
      assert_includes plan.devops_backfill_step(rake_in_target: false),
                      "the hub range adds the devops columns migration 20261006150000"

      other = ->(repo, _f, _t) { repo == "turf-monster" ? ["db/migrate/20261006150000_add_devops_columns_to_tasks.rb"] : [] }
      turf_only = RollbackPlan.build(target: target, history: history).check_migrations!(other)
      assert_nil turf_only.devops_backfill_step(rake_in_target: false), "only the hub range counts"
    end
  end
end
