require "test_helper"
require Rails.root.join("db/migrate/20261012200000_split_growth_tier")

# [integration] SplitGrowthTier — on 2026-10-12 Growth split into Pro and Team
# and the old $100 Pro was renamed Builder, so `pro` now names a different tier.
# Runs the migration's own up and down against rows written with the old keys
# (validation bypassed, as production holds them), and pins the ORDER: an old
# pro row must end on builder, never on the new pro.
class SplitGrowthTierTest < ActiveSupport::TestCase
  def migration = SplitGrowthTier.new.tap { |m| m.verbose = false }

  def client(slug, tier)
    StackClient.find_or_initialize_by(slug: slug).tap do |row|
      row.assign_attributes(name: slug, tier: tier)
      row.save!(validate: false)
    end
  end

  def request(tier, token)
    AppRequest.new(prompt: "a dog walking app", tier: tier, status: "draft", token: token).tap { |row| row.save!(validate: false) }
  end

  test "the migration lands only on current keys, and growth is gone from the config" do
    refute_includes WorkspacePackage.keys, SplitGrowthTier::RETIRED
    targets = SplitGrowthTier::CLIENT_TIERS.values + SplitGrowthTier::RENAMED.values + [ SplitGrowthTier::DEFAULT ]
    assert_empty targets - WorkspacePackage.keys
    assert_equal %w[vibe builder pro team enterprise], WorkspacePackage.keys
  end

  test "production's rows: old Pro becomes Builder FIRST, then Commercial Welding takes the new Pro and Turf Monster Team" do
    clients = {
      "commercial-welding" => "growth", "turf-monster" => "growth", "cyvasse" => "pro",
      "10and5" => "vibe", "industries" => "internal", "studio" => "internal"
    }.to_h { |slug, tier| [ slug, client(slug, tier) ] }

    migration.up

    assert_equal({ "commercial-welding" => "pro", "turf-monster" => "team", "cyvasse" => "builder",
                   "10and5" => "vibe", "industries" => "internal", "studio" => "internal" },
                 clients.transform_values { |row| row.reload.tier })
    assert_equal "builder", clients.fetch("cyvasse").tier, "an old pro row ends on builder, not on the new pro"
    clients.slice("commercial-welding", "turf-monster", "cyvasse").each do |slug, row|
      assert row.valid?, "#{slug}: #{row.errors.full_messages.to_sentence}"
    end
  end

  test "any other growth row takes Team; app requests move too; enterprise stays" do
    other = client("family", "growth")
    enterprise = client("industries", "enterprise")
    rows = { "growth" => request("growth", "split-1"), "pro" => request("pro", "split-2"), "vibe" => request("vibe", "split-3") }

    migration.up

    assert_equal "team", other.reload.tier
    assert_equal "enterprise", enterprise.reload.tier
    assert_equal({ "growth" => "team", "pro" => "builder", "vibe" => "vibe" }, rows.transform_values { |row| row.reload.tier })
    assert_equal 0, StackClient.where(tier: "growth").count + AppRequest.where(tier: "growth").count
  end

  test "down reverses in a safe order: new Pro and Team fold into growth before Builder takes pro back" do
    cw = client("commercial-welding", "pro")
    turf = client("turf-monster", "team")
    cyvasse = client("cyvasse", "builder")
    vibe = client("10and5", "vibe")

    migration.down

    assert_equal %w[growth growth pro vibe], [ cw, turf, cyvasse, vibe ].map { |row| row.reload.tier },
                 "Builder's row returns to pro and is NOT folded into growth"
  end

  test "up then down returns production's rows to where they started" do
    start = { "commercial-welding" => "growth", "turf-monster" => "growth", "cyvasse" => "pro", "10and5" => "vibe" }
    rows = start.to_h { |slug, tier| [ slug, client(slug, tier) ] }

    migration.up
    migration.down

    assert_equal start, rows.transform_values { |row| row.reload.tier }
  end
end
