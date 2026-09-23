require "test_helper"

# The INLINE strategies' deployed-marker: what lets `bin/release ship
# --finalize-only` confirm a killed ship's git_push_heroku / repo_script deploy
# instead of re-running it.
#
# THE BUG THESE PIN. deploy_already_succeeded? has always required
# `deployed_at_sha == true` for those two strategies — correctly, since main
# advances BEFORE an inline deploy runs — but bin/release never computed one, so
# the argument defaulted to nil and the predicate could not return true for an
# inline-deploy app however live it was. The parameter was fully specified, fully
# unit-tested, and had NO production caller.
class Release::InlineDeployMarkerTest < ActiveSupport::TestCase
  S = Release::ShipSequence

  # Verbatim from `heroku releases --app turf-monster-mainnet --json -n 2`,
  # measured 2026-09-22. The shape matters: the `current` flag, the `succeeded`
  # status and the `Deploy <sha8>` description are the three things the marker
  # reads, and a hand-invented payload would test a record Heroku never emits.
  LIVE = {
    "version" => 285, "description" => "Deploy 0988886c",
    "status" => "succeeded", "current" => true
  }.freeze
  PRIOR = {
    "version" => 284, "description" => "Deploy 7c655eab",
    "status" => "succeeded", "current" => false
  }.freeze
  FROZEN = "0988886c1f2e3d4c5b6a798877665544332211aa".freeze

  # --- heroku_app_for: WHERE the release list is read from -----------------

  test "[unit] a git_push_heroku adapter needs no new key — its own `remote:` names the app" do
    # The remote is what ship PUSHES to, so it cannot drift silently: a wrong
    # value deploys to the wrong place, loudly. Deriving from it adds no second
    # source of truth to keep in sync.
    assert_equal "mcritchie-industries", S.heroku_app_for(
      "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/mcritchie-industries.git"
    )
    assert_equal "rolio-prod", S.heroku_app_for(
      "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/rolio-prod.git"
    )
  end

  test "[unit] a repo_script adapter must DECLARE the app — its command names no target" do
    assert_equal "turf-monster-mainnet", S.heroku_app_for(
      "strategy" => "repo_script", "command" => "bin/deploy", "heroku_app" => "turf-monster-mainnet"
    )
  end

  test "[unit] an explicit heroku_app OUTRANKS a derived one" do
    assert_equal "declared-app", S.heroku_app_for(
      "remote" => "https://git.heroku.com/derived-app.git", "heroku_app" => "declared-app"
    )
  end

  test "[unit] an adapter that names no Heroku app resolves to nothing, never a guess" do
    # A repo_script deploy may not touch Heroku at all. Returning "" keeps the
    # caller's behaviour exactly as it is today — no marker, so no confirmation —
    # rather than reading a stranger's release list.
    assert_equal "", S.heroku_app_for("strategy" => "repo_script", "command" => "bin/deploy")
    assert_equal "", S.heroku_app_for("remote" => "git@github.com:McRitchie-Studio/turf-monster.git")
    assert_equal "", S.heroku_app_for("remote" => "https://git.heroku.com/.git")
    assert_equal "", S.heroku_app_for(nil)
    assert_equal "", S.heroku_app_for({})
  end

  # --- heroku_release_at_sha?: WHAT proves the deploy landed ---------------

  test "[unit] REGRESSION: the CURRENT succeeded Deploy of the frozen SHA is the proof" do
    assert S.heroku_release_at_sha?([LIVE, PRIOR], FROZEN)
  end

  test "[unit] symbol keys read the same as string keys" do
    assert S.heroku_release_at_sha?([{ description: "Deploy 0988886c", status: "succeeded", current: true }], FROZEN)
  end

  test "[unit] a DIFFERENT SHA is not our deploy" do
    assert_not S.heroku_release_at_sha?([LIVE, PRIOR], "7c655eab" + ("0" * 32))
  end

  test "[unit] CONTROL: our SHA in a NON-current release does not confirm it, IN EITHER ORDER" do
    # The both-arms ablation for `current` — and the order is load-bearing in the
    # test, not just in the data. Measured: with our release listed SECOND, a
    # `find`-anything implementation still answers false (it hits the other release
    # first and fails to match), so the mutation that ignores `current` passes the
    # assertion and the flag goes unpinned. Our release goes FIRST, where only code
    # that actually reads `current` can refuse it — and the realistic
    # newest-first order is asserted too, so both are covered.
    superseded = LIVE.merge("current" => false)
    newer      = { "description" => "Deploy 7c655eab", "status" => "succeeded", "current" => true }

    assert_not S.heroku_release_at_sha?([superseded, newer], FROZEN),
      "a deploy that is no longer current is not what Heroku is serving"
    assert_not S.heroku_release_at_sha?([newer, superseded], FROZEN),
      "and the answer cannot depend on the order the list arrives in"
  end

  test "[unit] a later config-var release hides the deploy, and that FAILS CLOSED" do
    # Heroku records a config change as a release too, so the current one may not
    # name any SHA while our build is still the one running. The marker does not
    # walk back to find the older Deploy row: a `Rollback to v283` is also a later
    # release, and telling those two apart by parsing English descriptions is how
    # a false green gets manufactured. Re-deploying costs a same-SHA push Heroku
    # answers "up-to-date"; a false green costs a release marked shipped that is not.
    config_change = { "description" => "Set RESEND_API_KEY config vars", "status" => "succeeded",
                      "current" => true }
    # Ours FIRST: only code that reads `current` can refuse it here.
    assert_not S.heroku_release_at_sha?([LIVE.merge("current" => false), config_change], FROZEN)
    assert_not S.heroku_release_at_sha?([config_change, LIVE.merge("current" => false)], FROZEN)
  end

  test "[unit] a ROLLBACK on top of our deploy must never read as live" do
    rollback = { "description" => "Rollback to v283", "status" => "succeeded", "current" => true }
    assert_not S.heroku_release_at_sha?([LIVE.merge("current" => false), rollback], FROZEN),
      "the build was rolled back — confirming it would mark a reverted release shipped"
    assert_not S.heroku_release_at_sha?([rollback, LIVE.merge("current" => false)], FROZEN)
  end

  test "[unit] a release that did not SUCCEED is not a deploy" do
    assert_not S.heroku_release_at_sha?([LIVE.merge("status" => "failed")], FROZEN)
    assert_not S.heroku_release_at_sha?([LIVE.merge("status" => "pending")], FROZEN)
    assert_not S.heroku_release_at_sha?([LIVE.reject { |k, _| k == "status" }], FROZEN)
  end

  test "[unit] it FAILS CLOSED on an unreadable, empty or currentless list" do
    assert_not S.heroku_release_at_sha?([], FROZEN)
    assert_not S.heroku_release_at_sha?(nil, FROZEN)
    assert_not S.heroku_release_at_sha?("not a list", FROZEN)
    assert_not S.heroku_release_at_sha?([LIVE.merge("current" => false)], FROZEN),
      "no release flagged current — not even our own matching one confirms"
    assert_not S.heroku_release_at_sha?([LIVE.merge("current" => "true")], FROZEN),
      "the flag is a boolean; the string \"true\" is not it"
    assert_not S.heroku_release_at_sha?(["garbled"], FROZEN)
  end

  test "[unit] a too-short prefix cannot match — a 2-char description is not evidence" do
    assert_not S.heroku_release_at_sha?([LIVE.merge("description" => "Deploy 09")], FROZEN)
    assert_not S.heroku_release_at_sha?([LIVE], "0988886")
    assert_not S.heroku_release_at_sha?([LIVE], "")
  end

  test "[unit] a description that is not a deploy at all matches nothing" do
    assert_not S.heroku_release_at_sha?([LIVE.merge("description" => "Deployed by hand 0988886c")], FROZEN)
    assert_not S.heroku_release_at_sha?([LIVE.merge("description" => "")], FROZEN)
  end

  # --- the predicate, now reachable for the inline strategies --------------

  test "[unit] REGRESSION: an inline strategy with the marker now reads as already shipped" do
    %w[git_push_heroku repo_script].each do |strategy|
      deployed = S.heroku_release_at_sha?([LIVE, PRIOR], FROZEN)
      assert S.deploy_already_succeeded?(strategy: strategy, up_ok: true, deployed_at_sha: deployed),
        "#{strategy}: a live frozen SHA must finalize instead of re-deploying"
    end
  end

  test "[unit] CONTROL: the SAME call with the argument the caller used to pass still refuses" do
    # This is the defect, reproduced: bin/release passed four arguments and let
    # deployed_at_sha default. Every other input here is identical to the test
    # above, so the pair isolates the missing argument as the whole cause.
    %w[git_push_heroku repo_script].each do |strategy|
      assert_not S.deploy_already_succeeded?(strategy: strategy, up_ok: true, main_at_sha: true),
        "#{strategy}: without the marker the predicate cannot return true — the measured bug"
    end
  end

  # --- the refusal names WHICH condition was unmet -------------------------

  test "[unit] a confirmed deploy has no gap to report" do
    assert_equal "", S.deploy_gap_reason(strategy: "repo_script", up_ok: true, deployed_at_sha: true)
    assert_equal "", S.deploy_gap_reason(strategy: "github_actions", up_ok: true,
                                         main_at_sha: true, run_success: true)
  end

  test "[unit] a repo_script row that names no Heroku app says SO, and names the key" do
    # This failure is NEW with the marker and is otherwise invisible: the app
    # refuses forever, silently, exactly as if its deploy had never landed.
    reason = S.deploy_gap_reason(strategy: "repo_script", up_ok: true, heroku_app: "")

    assert_includes reason, "names no Heroku app"
    assert_includes reason, "prod_deploy.heroku_app:"
    # Compared against the model's OWN constant, not a literal path. Two reasons:
    # the two cannot drift, and a test file that SPELLS a config path joins that
    # config's fast-check mapped set — which pushed this registry over the mapped
    # cap and reddened test/lib/fast_cert_subject_test.rb on CI (measured, and the
    # only thing that caught it).
    assert_includes reason, S::REGISTRY_FILE, "the remedy names the file to edit"
  end

  test "[unit] a named app that did not confirm names the app and the likely causes" do
    reason = S.deploy_gap_reason(strategy: "git_push_heroku", up_ok: true,
                                 heroku_app: "mcritchie-industries", deployed_at_sha: false)

    assert_includes reason, "mcritchie-industries"
    assert_includes reason, "rollback"
  end

  test "[unit] a down prod outranks every other gap — it is checked first" do
    # KEPT, with the input corrected: a DECLARED smoke_url is what makes
    # "did not answer 200" a true sentence. The property under test is the
    # PRECEDENCE, and it is unchanged.
    reason = S.deploy_gap_reason(strategy: "repo_script", up_ok: false, heroku_app: "",
                                 smoke_url: "https://turfmonster.media")

    assert_equal "prod /up did not answer 200", reason,
      "the FIRST unmet condition is the one to report; a registry gap is moot if prod is down"
  end

  # THE BLOCKER THIS PR WAS BOUNCED FOR. `up_ok == false` has two causes and the old
  # wording asserted the wrong one for a whole class of apps: prod_up_ok? returns
  # false WITHOUT CURLING when the URL is blank, and group_smoke_url is blank for any
  # non-hub adapter with no smoke_url. Measured 2026-09-22 — turf-monster refused with
  # "prod /up did not answer 200" while GET https://turfmonster.media/up returned 200.
  test "[unit] an undeclared smoke_url says no probe was made, not that prod is down" do
    reason = S.deploy_gap_reason(strategy: "repo_script", up_ok: false, heroku_app: "", smoke_url: "")

    refute_equal "prod /up did not answer 200", reason,
      "no /up probe was made at all — blaming prod sends the reader to an incident that does not exist"
    assert_includes reason, "no smoke_url"
    assert_includes reason, "NO /up probe was made"
    assert_includes reason, "smoke_url", "the remedy must name the key to add"
  end

  # It is fail-DEAD, not fail-closed, and the message has to carry that: no deploy,
  # however healthy, can satisfy a gate whose probe never runs.
  test "[unit] the undeclared-smoke_url gap says the repo can NEVER be confirmed" do
    reason = S.deploy_gap_reason(strategy: "repo_script", up_ok: false, smoke_url: "")

    assert_includes reason, "never be confirmed"
  end

  # The new branch must keep the precedence the old one had: it still outranks the
  # heroku_app gap, so a reader is never handed the second-most-relevant remedy.
  test "[unit] the undeclared-smoke_url gap still outranks the registry gap" do
    reason = S.deploy_gap_reason(strategy: "repo_script", up_ok: false, heroku_app: "", smoke_url: "")

    refute_includes reason, "names no Heroku app"
  end

  # The hub reaches up_ok through PROD_URL rather than the key, so its row declaring
  # none is not the defect above — the message must not send its reader to the YAML.
  test "[unit] a declared smoke_url that answered non-200 never mentions the registry" do
    reason = S.deploy_gap_reason(strategy: "github_actions", up_ok: false,
                                 smoke_url: "https://mcritchie.studio")

    assert_equal "prod /up did not answer 200", reason
  end

  test "[unit] the github_actions gaps stay distinguishable" do
    assert_equal "origin/main is not at the frozen SHA",
                 S.deploy_gap_reason(strategy: "github_actions", up_ok: true, main_at_sha: false)
    assert_includes S.deploy_gap_reason(strategy: "github_actions", up_ok: true, main_at_sha: true,
                                        workflow: "prod-deploy.yml"),
                    "no successful prod-deploy.yml run"
  end

  test "[unit] an unknown strategy says that it can never be confirmed" do
    assert_includes S.deploy_gap_reason(strategy: "carrier_pigeon", up_ok: true), "unknown prod_deploy strategy"
  end

  # --- the registry actually resolves for every live inline app ------------

  test "[integration] every LIVE inline-deploy app in the registry resolves to a Heroku app" do
    # No `skip` here, deliberately — config/rails_lane.yml ratchets the lane's skip
    # count, and this half needs no checkout anyway. A `planned` row has no repo
    # and nothing to name, so it is exempt BY LADDER rather than by exception list.
    unresolved = Release::Repos.app_repos.filter_map do |repo|
      adapter = Release::Repos.prod_deploy(repo) || {}
      next unless %w[git_push_heroku repo_script].include?(adapter["strategy"].to_s)
      next if Release::Repos.app_meta(repo)["ladder"].to_s == "planned"
      next unless Release::ShipSequence.heroku_app_for(adapter).empty?

      "#{repo} (#{adapter['strategy']})"
    end

    assert_empty unresolved,
      "an inline-deploy app whose Heroku app cannot be resolved can never be finalized: #{unresolved.join(', ')}"
  end

  test "[integration] the registry resolves each inline app to the app it really deploys to" do
    assert_equal "turf-monster-mainnet", Release::ShipSequence.heroku_app_for(Release::Repos.prod_deploy("turf-monster"))
    assert_equal "mcritchie-industries",
                 Release::ShipSequence.heroku_app_for(Release::Repos.prod_deploy("mcritchie-industries"))
  end

  test "[integration] bin/release COMPUTES and PASSES the marker — the seam that was missing" do
    # Supplementary tripwire ONLY; the decisions above are proven by behaviour.
    # It guards the one seam no unit test can see, and it is the seam that was
    # broken: the parameter was fully specified and fully unit-tested, and simply
    # had no production caller.
    body = Rails.root.join("bin", "release.rb").read[/^def deploy_live_verdict.*?(?=^def )/m]
    assert body, "bin/release.rb defines deploy_live_verdict"

    assert_includes body, "heroku_release_at_sha?", "the inline marker is computed"
    assert_includes body, "deployed_at_sha: deployed_at_sha", "and PASSED — the whole defect"
    assert_includes body, "Release::ShipSequence.heroku_app_for(adapter)"
    # THE SAME DEFECT CLASS, ONE PARAMETER OVER. `smoke_url:` is fully specified and
    # fully unit-tested above, and every one of those unit tests passes whether or not
    # bin/release.rb actually hands it over — which is exactly how `deployed_at_sha:`
    # came to exist with no production caller. Pin the hand-over, not just the shape.
    assert_includes body, "smoke_url: smoke_url",
      "the resolved smoke URL is PASSED — without it the gap reason cannot tell " \
      "a non-200 probe from a probe that never ran"
    assert_includes body, "smoke_url = group_smoke_url(group)",
      "and resolved ONCE, so the probe and the diagnosis cannot disagree"
    assert_match(/Open3\.capture3\("heroku", "releases"/, Rails.root.join("bin", "release.rb").read,
      "the Heroku read keeps stderr OUT of the JSON — the CLI prints an update warning there")
    assert_no_match(/capture2e\("heroku"/, Rails.root.join("bin", "release.rb").read)
  end

  # THE KEY THAT MAKES heroku_app MEAN ANYTHING. Without it, deploy_already_succeeded?
  # returns false for turf-monster on its opening `return false unless up_ok == true`,
  # so the whole inline marker is inert for the one app it was written for.
  test "[integration] turf-monster declares the smoke_url its confirmation depends on" do
    adapter = Release::Repos.prod_deploy("turf-monster")

    assert_equal "https://turfmonster.media", adapter["smoke_url"].to_s,
      "without a smoke_url, group_smoke_url returns blank and prod_up_ok? answers false unprobed"
  end

  # AND IT MUST AGREE WITH THE OTHER SOURCE THAT ALREADY HELD IT.
  # Release::ProdSmoke.base_url_for reads the registry FIRST and falls back to
  # qa_environments.<app>.production_url, so the two spellings silently diverging
  # would move ProdSmoke's answer without moving finalize's. Declaring the key was
  # only safe BECAUSE they matched; this keeps that true.
  test "[integration] the registry smoke_url matches qa_environments' production_url" do
    registry = Release::Repos.prod_deploy("turf-monster")["smoke_url"].to_s
    qa = YAML.load_file(Rails.root.join("config", "qa_environments.yml"))
             .dig("qa_environments", "turf-monster", "production_url").to_s

    assert_equal qa, registry,
      "ProdSmoke falls back to qa_environments; a divergence makes the two disagree about prod"
  end

  test "[integration] turf-monster's declared heroku_app matches the script that deploys it" do
    # The one risk of declaring the app in the registry is drift from the script
    # that performs the deploy. NO `skip` — config/rails_lane.yml ratchets the
    # lane's skip count — and NO bare early return either: a `return` past every
    # assertion leaves a test that proves nothing and reports green, which CI
    # flagged as "Test is missing assertions" (measured, and the only thing that
    # caught it). So the half that needs no checkout ALWAYS runs, and the on-disk
    # comparison is added for whichever siblings are present.
    declared = Release::ShipSequence.heroku_app_for(Release::Repos.prod_deploy("turf-monster"))
    assert_equal "turf-monster-mainnet", declared,
      "the registry must name the app turf-monster deploys to"

    deploy = File.join(Rails.root.to_s.sub(%r{/mcritchie-studio(/\.worktrees/[^/]+)?\z}, ""),
                       "turf-monster", "bin", "deploy")
    # The registry assertion above has already run, so leaving here proves something
    # either way — that is what separates this from the bare `return` CI caught.
    next unless File.exist?(deploy)

    assert_equal declared, File.read(deploy)[/^HEROKU_APP="([^"]+)"/, 1],
      "the registry names a different app than turf-monster/bin/deploy pushes to"
  end
end
