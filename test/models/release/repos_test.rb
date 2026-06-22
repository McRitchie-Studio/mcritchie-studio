require "test_helper"

class Release::ReposTest < ActiveSupport::TestCase
  test "classifies registered gems as :gem" do
    assert_equal :gem, Release::Repos.kind("studio-engine")
    assert_equal :gem, Release::Repos.kind("solana-studio")
    assert Release::Repos.gem?("studio-engine")
    assert Release::Repos.gem?("solana-studio")
  end

  test "classifies registered apps as :app" do
    assert_equal :app, Release::Repos.kind("mcritchie-studio")
    assert_equal :app, Release::Repos.kind("turf-monster")
    assert Release::Repos.app?("turf-monster")
    assert_not Release::Repos.gem?("turf-monster")
  end

  test "classifies anything outside the registry as :unknown" do
    assert_equal :unknown, Release::Repos.kind("not-a-real-repo")
    assert_equal :unknown, Release::Repos.kind(nil)
    assert_equal :unknown, Release::Repos.kind("")
    assert_not Release::Repos.gem?("not-a-real-repo")
    assert_not Release::Repos.app?("not-a-real-repo")
  end

  test "gem_repos and app_repos read the registry" do
    assert_includes Release::Repos.gem_repos, "studio-engine"
    assert_includes Release::Repos.gem_repos, "solana-studio"
    assert_includes Release::Repos.app_repos, "mcritchie-studio"
    assert_not_includes Release::Repos.gem_repos, "mcritchie-studio"
  end

  test "gem_meta returns the gem's publish metadata" do
    meta = Release::Repos.gem_meta("studio-engine")
    assert_equal "lib/studio/version.rb", meta["version_file"]
    assert_equal "studio-engine.gemspec", meta["gemspec"]
    assert_equal "bin/release-check", meta["release_check"]
  end

  test "gem_meta is nil for a non-gem" do
    assert_nil Release::Repos.gem_meta("turf-monster")
    assert_nil Release::Repos.gem_meta("nope")
  end

  test "extract_version parses a VERSION constant assignment" do
    assert_equal "0.7.0", Release::Repos.extract_version(%(module Studio\n  VERSION = "0.7.0"\nend\n))
  end

  test "extract_version parses a gemspec version assignment" do
    assert_equal "0.4.7", Release::Repos.extract_version(%(  spec.version = "0.4.7"\n))
  end

  test "extract_version returns nil when no version is present" do
    assert_nil Release::Repos.extract_version("no version here")
    assert_nil Release::Repos.extract_version(nil)
  end

  test "gem_version is nil for a non-gem repo" do
    assert_nil Release::Repos.gem_version("turf-monster")
  end

  # --- apps as a hash: app_meta / prod_deploy / qa_app ---

  test "app_repos lists the registry's app hash keys" do
    assert_equal %w[mcritchie-studio turf-monster tax-studio chain-ops].sort,
                 Release::Repos.app_repos.sort
  end

  test "app? matches the app hash keys" do
    assert Release::Repos.app?("mcritchie-studio")
    assert Release::Repos.app?("tax-studio")
    assert Release::Repos.app?("chain-ops")
    assert_not Release::Repos.app?("studio-engine") # a gem
    assert_not Release::Repos.app?("not-a-real-repo")
  end

  test "app_meta returns the app's registry metadata" do
    meta = Release::Repos.app_meta("turf-monster")
    assert_kind_of Hash, meta
    assert meta.key?("prod_deploy")
  end

  test "app_meta is nil for a non-app" do
    assert_nil Release::Repos.app_meta("studio-engine") # a gem
    assert_nil Release::Repos.app_meta("nope")
  end

  test "prod_deploy returns the git_push_heroku adapter for mcritchie-studio" do
    adapter = Release::Repos.prod_deploy("mcritchie-studio")
    assert_equal "git_push_heroku", adapter["strategy"]
    assert_equal "heroku", adapter["remote"]
    assert_equal "main", adapter["branch"]
    assert_equal "https://app.mcritchie.studio", adapter["smoke_url"]
  end

  test "prod_deploy returns the repo_script adapter for turf-monster" do
    adapter = Release::Repos.prod_deploy("turf-monster")
    assert_equal "repo_script", adapter["strategy"]
    assert_equal "bin/deploy", adapter["command"]
    assert_equal ["--yes"], adapter["args"]
  end

  test "prod_deploy is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.prod_deploy("studio-engine")
    assert_nil Release::Repos.prod_deploy("not-a-real-repo")
  end

  test "qa_app defaults to the repo slug when no qa_deploy override is set" do
    assert_equal "turf-monster", Release::Repos.qa_app("turf-monster")
    assert_equal "mcritchie-studio", Release::Repos.qa_app("mcritchie-studio")
  end

  # --- test_cmd: the conductor's pre-prod gate ---

  test "test_cmd returns the hub's pre-prod gate command" do
    assert_equal "bin/rails test", Release::Repos.test_cmd("mcritchie-studio")
  end

  test "test_cmd is nil for a self-gating repo_script satellite" do
    # Satellites run their own suite in bin/deploy, so they leave test_cmd unset
    # (the conductor skips the gate) to avoid double-testing.
    assert_nil Release::Repos.test_cmd("turf-monster")
    assert_nil Release::Repos.test_cmd("tax-studio")
  end

  test "test_cmd is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.test_cmd("studio-engine")
    assert_nil Release::Repos.test_cmd("not-a-real-repo")
  end
end
