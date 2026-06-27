require "test_helper"

class Release
  class ProdSmokeTest < ActiveSupport::TestCase
    RELEASE_REPOS = {
      "apps" => {
        "mcritchie-studio" => { "prod_deploy" => { "smoke_url" => "https://app.mcritchie.studio" } },
        "rolio" => { "prod_deploy" => { "smoke_url" => "https://rolio-prod.example.test" } },
        "turf-monster" => { "prod_deploy" => { "strategy" => "repo_script" } } # no smoke_url
      }
    }.freeze

    QA_ENVIRONMENTS = {
      "qa_environments" => {
        "mcritchie-studio" => { "production_url" => "https://app.mcritchie.studio" },
        "rolio" => { "production_url" => "https://rolio-prod-fallback.example.test" },
        "turf-monster" => { "production_url" => "https://turfmonster.media" }
      }
    }.freeze

    test "[unit] resolves the hub host from release_repos smoke_url (the /up gate's host)" do
      assert_equal "https://app.mcritchie.studio",
        ProdSmoke.base_url_for("mcritchie-studio", release_repos: RELEASE_REPOS, qa_environments: QA_ENVIRONMENTS)
    end

    test "[unit] falls back to qa_environments production_url when no smoke_url" do
      assert_equal "https://turfmonster.media",
        ProdSmoke.base_url_for("turf-monster", release_repos: RELEASE_REPOS, qa_environments: QA_ENVIRONMENTS)
    end

    test "[unit] resolves Rolio from release_repos smoke_url" do
      assert_equal "https://rolio-prod.example.test",
        ProdSmoke.base_url_for("rolio", release_repos: RELEASE_REPOS, qa_environments: QA_ENVIRONMENTS)
    end

    test "[unit] falls back to the default for an unknown app" do
      assert_equal ProdSmoke::DEFAULT_BASE_URL,
        ProdSmoke.base_url_for("ghost", release_repos: RELEASE_REPOS, qa_environments: QA_ENVIRONMENTS)
    end

    test "[unit] tolerates empty / missing config without raising" do
      assert_equal ProdSmoke::DEFAULT_BASE_URL, ProdSmoke.base_url_for("mcritchie-studio")
      assert_equal ProdSmoke::DEFAULT_BASE_URL,
        ProdSmoke.base_url_for("mcritchie-studio", release_repos: {}, qa_environments: {})
    end

    test "[unit] the default IS the gate host (app.mcritchie.studio, not the apex)" do
      assert_equal "https://app.mcritchie.studio", ProdSmoke::DEFAULT_BASE_URL
    end

    test "[unit] the shipped release_repos.yml resolves the hub to the gate host" do
      release_repos = YAML.load_file(Rails.root.join("config/release_repos.yml"))
      qa = YAML.load_file(Rails.root.join("config/qa_environments.yml"))
      assert_equal "https://app.mcritchie.studio",
        ProdSmoke.base_url_for("mcritchie-studio", release_repos: release_repos, qa_environments: qa)
    end

    test "[unit] the shipped release_repos.yml resolves Rolio to the Heroku prod app" do
      release_repos = YAML.load_file(Rails.root.join("config/release_repos.yml"))
      qa = YAML.load_file(Rails.root.join("config/qa_environments.yml"))
      assert_equal "https://rolio-prod-82e96784b462.herokuapp.com",
        ProdSmoke.base_url_for("rolio", release_repos: release_repos, qa_environments: qa)
    end
  end
end
