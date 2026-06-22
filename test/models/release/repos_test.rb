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
end
