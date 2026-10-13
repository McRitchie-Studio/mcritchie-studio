require "test_helper"

# [unit] config/integrations.yml: two groups, every entry with a known status,
# a known CTA and a real tier, and the honesty rule (Connect only on a live
# entry) enforced on load.
class IntegrationTest < ActiveSupport::TestCase
  test "[unit] the config loads two groups, integrations then add-ons" do
    groups = Integration.groups

    assert_equal %w[integrations add_ons], groups.map(&:key)
    groups.each { |group| assert group.entries.any?, "#{group.key} has entries" }
  end

  test "[unit] every entry has a known status, a known CTA and, when gated, a real tier" do
    Integration.entries.each do |entry|
      assert_includes Integration::STATUSES, entry.status, entry.key
      assert_includes Integration::CTAS, entry.cta, entry.key
      assert WorkspacePackage.find(entry.tier), "#{entry.key}: tier #{entry.tier}" if entry.tier.present?
    end
    assert_equal Integration.entries.size, Integration.entries.map(&:key).uniq.size, "keys are unique"
  end

  test "[unit] the statuses Alex set on 2026-10-13" do
    assert_equal "live", Integration.find(:google_workspace_connect).status
    assert_equal "pro", Integration.find(:google_workspace_connect).tier
    assert_equal "live", Integration.find(:discord).status
    assert_equal "soon", Integration.find(:slack).status
    assert_equal "soon", Integration.find(:stripe_connect).status
    assert_equal "soon", Integration.find(:custom_connectors).status
    assert_equal "enterprise", Integration.find(:enterprise_extras).tier
  end

  test "[unit] availability reads Every plan, From <tier>, or nothing" do
    assert_equal "Every plan", Integration.find(:discord).availability
    assert_equal "From Pro", Integration.find(:google_workspace_connect).availability
    assert_equal "From Enterprise", Integration.find(:github_org).availability
    assert_nil Integration.find(:slack).availability
  end

  test "[unit] integrations are free; an add-on shows its price or Quote" do
    Integration.groups.first.entries.each { |entry| assert_equal "Free", entry.price_label, entry.key }
    assert_equal "Google's seat price + $10/user/month", Integration.find(:google_workspace_managed).price_label
    assert_equal "Quote", Integration.find(:payments).price_label
  end

  test "[unit] an entry leads with a brand logo only for a known software key" do
    assert_equal "google", Integration.find(:google_workspace_connect).brand
    assert_nil Integration.find(:ai_features).brand
  end

  test "[unit] a Connect button on an entry that is not live fails the load" do
    error = assert_raises(ArgumentError) do
      Integration.send(:build_entry, "integrations", { "key" => "x", "name" => "X", "icon" => "slack", "status" => "soon", "cta" => "connect" })
    end
    assert_match(/Connect is for live entries only/, error.message)
  end

  test "[unit] an unknown status or tier fails the load" do
    assert_raises(ArgumentError) { Integration.send(:build_entry, "add_ons", { "key" => "x", "status" => "shipped", "cta" => "talk" }) }
    assert_raises(ArgumentError) { Integration.send(:build_entry, "add_ons", { "key" => "x", "status" => "live", "cta" => "talk", "tier" => "growth" }) }
  end
end
