require "test_helper"

# Pure decision logic for the multi-repo `bin/release ship`. No git/gem/bundle/
# network here — same IO-free contract as GemfileRepin, so it's trivially unit
# tested and the shell stays thin.
class Release::ShipSequenceTest < ActiveSupport::TestCase
  S = Release::ShipSequence

  # --- strategy_handler: adapter string → handler symbol -------------------

  test "strategy_handler maps git_push_heroku" do
    assert_equal :git_push_heroku, S.strategy_handler("git_push_heroku")
  end

  test "strategy_handler maps repo_script" do
    assert_equal :repo_script, S.strategy_handler("repo_script")
  end

  test "strategy_handler raises on an unknown strategy" do
    err = assert_raises(ArgumentError) { S.strategy_handler("rsync_box") }
    assert_match(/unknown prod_deploy strategy/, err.message)
    assert_match(/rsync_box/, err.message)
  end

  test "strategy_handler raises on nil/blank rather than silently skipping a deploy" do
    assert_raises(ArgumentError) { S.strategy_handler(nil) }
    assert_raises(ArgumentError) { S.strategy_handler("") }
  end

  # --- ordered_app_groups: hub first, rest stable --------------------------

  test "ordered_app_groups pulls the hub to the front" do
    groups = [{ "repo" => "turf-monster" }, { "repo" => "mcritchie-studio" }, { "repo" => "tax-studio" }]
    assert_equal %w[mcritchie-studio turf-monster tax-studio],
                 S.ordered_app_groups(groups).map { |g| g["repo"] }
  end

  test "ordered_app_groups keeps the non-hub order stable" do
    groups = [{ "repo" => "tax-studio" }, { "repo" => "turf-monster" }, { "repo" => "chain-ops" }]
    # No hub present — order is unchanged (stable).
    assert_equal %w[tax-studio turf-monster chain-ops],
                 S.ordered_app_groups(groups).map { |g| g["repo"] }
  end

  test "ordered_app_groups accepts symbol-keyed groups (record side) too" do
    groups = [{ repo: "turf-monster" }, { repo: "mcritchie-studio" }]
    assert_equal %w[mcritchie-studio turf-monster],
                 S.ordered_app_groups(groups).map { |g| g[:repo] }
  end

  test "ordered_app_groups handles an empty list" do
    assert_equal [], S.ordered_app_groups([])
  end

  # --- gems_to_repin: which published gems still branch-ref'd in a Gemfile --

  BRANCH_GEMFILE = <<~GEMFILE
    source "https://rubygems.org"
    gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"
    gem "solana-studio", "~> 0.4.7"
    gem "rails", "~> 7.2"
  GEMFILE

  test "gems_to_repin returns the branch-ref'd published gems" do
    assert_equal %w[studio-engine],
                 S.gems_to_repin(%w[studio-engine solana-studio], BRANCH_GEMFILE)
  end

  test "gems_to_repin excludes an already-pinned gem (idempotent)" do
    assert_equal [], S.gems_to_repin(%w[solana-studio], BRANCH_GEMFILE)
  end

  test "gems_to_repin excludes a gem absent from the Gemfile" do
    assert_equal [], S.gems_to_repin(%w[not-a-dep], BRANCH_GEMFILE)
  end

  test "gems_to_repin handles multiple branch-ref'd gems" do
    text = <<~GEMFILE
      gem "studio-engine", branch: "feat/a"
      gem "solana-studio", git: "https://github.com/amcritchie/solana-studio"
    GEMFILE
    assert_equal %w[studio-engine solana-studio],
                 S.gems_to_repin(%w[studio-engine solana-studio], text)
  end

  test "gems_to_repin returns [] for an empty published set" do
    assert_equal [], S.gems_to_repin([], BRANCH_GEMFILE)
  end

  # --- publish_needed?: RubyGems idempotency -------------------------------

  # The real /api/v1/versions/<gem>.json shape: an array of { "number" => ... }
  # entries, all LIVE — RubyGems excludes yanked versions from the listing
  # entirely (there is no `yanked` field). Other API fields are irrelevant here.
  REMOTE = [
    { "number" => "0.9.0" },
    { "number" => "0.8.0" }
  ].freeze

  test "publish_needed? is false when the version is already live (skip)" do
    assert_not S.publish_needed?("0.9.0", REMOTE)
  end

  test "publish_needed? is true when the version was never published" do
    assert S.publish_needed?("1.0.0", REMOTE)
  end

  test "publish_needed? is true for a version absent from the listing (e.g. yanked)" do
    # A yanked version is excluded from the listing, so it reads as not-live →
    # publish_needed? is true. Ship then attempts the push and RubyGems rejects
    # re-pushing a yanked number — yank safety lives at `gem push` (fail-closed),
    # since the listing carries no yanked flag to read.
    assert S.publish_needed?("0.8.1", REMOTE)
  end

  test "publish_needed? accepts a plain string listing (gem list shape)" do
    assert_not S.publish_needed?("0.9.0", %w[0.9.0 0.8.0])
    assert S.publish_needed?("1.0.0", %w[0.9.0 0.8.0])
  end

  test "publish_needed? is true against an empty (never-published) listing" do
    assert S.publish_needed?("0.1.0", [])
  end
end
