require "test_helper"
require Rails.root.join("db/migrate/20261001060000_remap_package_tiers")

# [unit] RemapPackageTiers — the v2 tiers replaced Launch/Host/Workspace/Agentic
# in the same deploy that changed the config, so every stored tier must move or
# its row could no longer be saved. Runs the migration's own remap against rows
# written with the retired keys (validation bypassed, as production holds them).
class RemapPackageTiersTest < ActiveSupport::TestCase
  def migration = RemapPackageTiers.new.tap { |m| m.verbose = false }

  test "the migration's mapping is the model's, and lands on current keys" do
    assert_equal WorkspacePackage::LEGACY_TIERS, RemapPackageTiers::MAP
    assert_empty RemapPackageTiers::MAP.values - WorkspacePackage.keys
    assert_equal WorkspacePackage.keys.sort, RemapPackageTiers::REVERSE.keys.sort, "down covers every current tier"
  end

  test "stored stack client and app request tiers move to v2; internal stays" do
    clients = {
      "turf-monster" => "agentic", "commercial-welding" => "workspace", "cyvasse" => "host",
      "10and5" => "launch", "industries" => "internal"
    }.to_h do |slug, tier|
      client = StackClient.new(slug: slug, name: slug, tier: tier)
      client.save!(validate: false)
      [ slug, client ]
    end
    request = AppRequest.new(prompt: "a dog walking app", tier: "launch", status: "draft", token: "remap-tiers-test")
    request.save!(validate: false)

    migration.send(:remap, RemapPackageTiers::MAP)

    assert_equal({ "turf-monster" => "growth", "commercial-welding" => "growth", "cyvasse" => "pro",
                   "10and5" => "vibe", "industries" => "internal" },
                 clients.transform_values { |client| client.reload.tier })
    assert_equal "vibe", request.reload.tier
    clients.each_value { |client| assert client.valid?, "#{client.slug}: #{client.errors.full_messages.to_sentence}" }
  end

  test "a new app request defaults to the Vibe tier" do
    assert_equal "vibe", AppRequest.new.tier
    assert_equal "vibe", AppRequest.column_defaults["tier"]
  end
end
