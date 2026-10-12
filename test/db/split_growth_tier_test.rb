require "test_helper"
require Rails.root.join("db/migrate/20261012200000_split_growth_tier")

# [integration] SplitGrowthTier — Growth left the config on 2026-10-12 (CTO and
# Team replaced it) in the same deploy as this migration, so every stored
# `growth` row must move or it could no longer be saved. Runs the migration's
# own up and down against rows written with the retired key (validation
# bypassed, as production holds them).
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
    assert_empty (SplitGrowthTier::CLIENT_TIERS.values + [ SplitGrowthTier::DEFAULT ]) - WorkspacePackage.keys
  end

  test "Commercial Welding moves to CTO, Turf Monster and any other growth row to Team; others stay" do
    clients = {
      "commercial-welding" => "growth", "turf-monster" => "growth", "10and5" => "growth",
      "cyvasse" => "pro", "industries" => "internal", "studio" => "enterprise"
    }.to_h { |slug, tier| [ slug, client(slug, tier) ] }
    growth_request = request("growth", "split-growth-1")
    vibe_request = request("vibe", "split-growth-2")

    migration.up

    assert_equal({ "commercial-welding" => "cto", "turf-monster" => "team", "10and5" => "team",
                   "cyvasse" => "pro", "industries" => "internal", "studio" => "enterprise" },
                 clients.transform_values { |row| row.reload.tier })
    assert_equal "team", growth_request.reload.tier
    assert_equal "vibe", vibe_request.reload.tier
    assert_equal 0, StackClient.where(tier: "growth").count + AppRequest.where(tier: "growth").count
    %w[commercial-welding turf-monster].each do |slug|
      row = clients.fetch(slug)
      assert row.valid?, "#{slug}: #{row.errors.full_messages.to_sentence}"
    end
  end

  test "down folds CTO and Team back into growth and touches nothing else" do
    cw = client("commercial-welding", "cto")
    turf = client("turf-monster", "team")
    cyvasse = client("cyvasse", "pro")
    team_request = request("team", "split-growth-3")

    migration.down

    assert_equal %w[growth growth pro growth], [ cw, turf, cyvasse, team_request ].map { |row| row.reload.tier }
  end
end
