require "test_helper"

# Pure decision logic for the release pipeline's post-deploy command hook. Like
# Release::ShipSequence this is IO-free — no heroku, no DB — so the {task, app,
# cmd} plan + the QA-vs-prod target resolution are unit tested here and the
# `heroku run` orchestration stays thin in bin/release.
class Release::PostDeployTest < ActiveSupport::TestCase
  PD = Release::PostDeploy

  # The qa_environments.yml shape the planner reads (qa-server key → apps). Mirrors
  # config/qa_environments.yml: each entry carries the QA heroku_app + the prod
  # production_app, the two targets a post-deploy command resolves to.
  QA_ENVS = {
    "mcritchie-studio" => { "heroku_app" => "mcritchie-studio-qa", "production_app" => "mcritchie-studio" },
    "turf-monster"     => { "heroku_app" => "turf-monster-qa", "production_app" => "turf-monster-mainnet" }
  }.freeze

  # The repo_plan as the CLI sees it (JSON-parsed → STRING keys). turf declares a
  # post_deploy_cmd; the studio member does not; the gem rides along (no qa_app).
  REPOS = [
    { "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
      "members" => [{ "slug" => "t-gem", "post_deploy_cmd" => nil }] },
    { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
      "members" => [{ "slug" => "t-studio", "post_deploy_cmd" => "" }] },
    { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
      "members" => [{ "slug" => "t-turf", "post_deploy_cmd" => "rake pokemon:backfill_mascots" }] }
  ].freeze

  # --- plan: target resolution (the load-bearing prepare-vs-ship decision) ---

  test "prepare (:qa) targets the member's QA heroku app" do
    plan = PD.plan(REPOS, qa_environments: QA_ENVS, target: :qa)

    assert_equal 1, plan.size, "only the member that declares a post_deploy_cmd is planned"
    entry = plan.first
    assert_equal "t-turf", entry["task"]
    assert_equal "turf-monster", entry["repo"]
    assert_equal "turf-monster-qa", entry["app"], "prepare runs on the QA app"
    assert_equal "rake pokemon:backfill_mascots", entry["cmd"]
  end

  test "ship (:prod) targets the member's production app" do
    plan = PD.plan(REPOS, qa_environments: QA_ENVS, target: :prod)

    assert_equal 1, plan.size
    assert_equal "turf-monster-mainnet", plan.first["app"], "ship runs on the production app"
    assert_equal "rake pokemon:backfill_mascots", plan.first["cmd"]
  end

  # --- plan: which members are included ---

  test "plan skips members with a nil, blank, or whitespace-only post_deploy_cmd" do
    repos = [
      { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
        "members" => [
          { "slug" => "a", "post_deploy_cmd" => nil },
          { "slug" => "b", "post_deploy_cmd" => "" },
          { "slug" => "c", "post_deploy_cmd" => "   " },
          { "slug" => "d" } # key absent entirely
        ] }
    ]
    assert_empty PD.plan(repos, qa_environments: QA_ENVS, target: :qa)
  end

  test "plan trims surrounding whitespace from the command" do
    repos = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
               "members" => [{ "slug" => "t", "post_deploy_cmd" => "  rake foo:bar  " }] }]
    assert_equal "rake foo:bar", PD.plan(repos, qa_environments: QA_ENVS, target: :qa).first["cmd"]
  end

  test "plan preserves producer-first member order across repos and within a repo" do
    repos = [
      { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
        "members" => [{ "slug" => "hub-1", "post_deploy_cmd" => "rake one" }] },
      { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
        "members" => [{ "slug" => "turf-1", "post_deploy_cmd" => "rake two" },
                      { "slug" => "turf-2", "post_deploy_cmd" => "rake three" }] }
    ]
    assert_equal %w[hub-1 turf-1 turf-2],
                 PD.plan(repos, qa_environments: QA_ENVS, target: :prod).map { |e| e["task"] }
  end

  # --- plan: a declared-but-unroutable command yields a blank app (CLI aborts) ---

  test "plan yields a blank app when the repo has no registered target (gem / unknown)" do
    repos = [{ "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
               "members" => [{ "slug" => "g", "post_deploy_cmd" => "rake noop" }] }]
    entry = PD.plan(repos, qa_environments: QA_ENVS, target: :prod).first

    assert_equal "g", entry["task"]
    assert_equal "", entry["app"], "an unroutable command surfaces a blank app so the CLI aborts"
  end

  test "plan yields a blank app for an app missing from the qa_environments registry" do
    repos = [{ "repo" => "chain-ops", "kind" => "app", "qa_app" => "chain-ops",
               "members" => [{ "slug" => "c", "post_deploy_cmd" => "rake noop" }] }]
    assert_equal "", PD.plan(repos, qa_environments: QA_ENVS, target: :qa).first["app"]
  end

  # --- plan: edge cases ---

  test "plan returns [] for an empty release" do
    assert_empty PD.plan([], qa_environments: QA_ENVS, target: :qa)
    assert_empty PD.plan(nil, qa_environments: QA_ENVS, target: :prod)
  end

  test "plan rejects an unknown target rather than silently running nothing" do
    err = assert_raises(ArgumentError) { PD.plan(REPOS, qa_environments: QA_ENVS, target: :staging) }
    assert_match(/target must be one of/, err.message)
    assert_match(/staging/, err.message)
  end

  # --- target_app: the per-key QA/prod resolution ---

  test "target_app resolves :qa to heroku_app and :prod to production_app" do
    assert_equal "turf-monster-qa", PD.target_app(QA_ENVS, "turf-monster", :qa)
    assert_equal "turf-monster-mainnet", PD.target_app(QA_ENVS, "turf-monster", :prod)
  end

  test "target_app returns '' for an unregistered or nil key" do
    assert_equal "", PD.target_app(QA_ENVS, "not-registered", :qa)
    assert_equal "", PD.target_app(QA_ENVS, nil, :prod)
    assert_equal "", PD.target_app(nil, "turf-monster", :qa)
  end
end
