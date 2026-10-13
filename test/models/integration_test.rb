require "test_helper"

# [unit] config/integrations.yml: three groups, every entry with a known status
# and a real tier, and the button each one gets: Connect for an integration
# live or on request, Get notified for a Coming soon one, Talk to us for an
# add-on or a custom need. Never Connect on a Coming soon entry.
class IntegrationTest < ActiveSupport::TestCase
  test "[unit] the config loads three groups: integrations, add-ons, then custom" do
    groups = Integration.groups

    assert_equal %w[integrations add_ons custom], groups.map(&:key)
    groups.each { |group| assert group.entries.any?, "#{group.key} has entries" }
  end

  test "[unit] every entry has a known status and, when gated, a real tier" do
    Integration.entries.each do |entry|
      assert_includes Integration::STATUSES, entry.status, entry.key
      assert WorkspacePackage.find(entry.tier), "#{entry.key}: tier #{entry.tier}" if entry.tier.present?
    end
    assert_equal Integration.entries.size, Integration.entries.map(&:key).uniq.size, "keys are unique"
  end

  test "[unit] the statuses Alex set on 2026-10-13" do
    assert_equal "live", Integration.find(:google_workspace_connect).status
    assert_equal "pro", Integration.find(:google_workspace_connect).tier
    assert_equal "on_request", Integration.find(:discord).status
    assert_equal "on_request", Integration.find(:payments).status
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

  test "[unit] integrations are free; an add-on shows its price or Quote; a custom entry no price" do
    Integration.groups.first.entries.each { |entry| assert_equal "Free", entry.price_label, entry.key }
    managed = Integration.find(:google_workspace_managed)
    assert_equal "$25/month + $15/user/month", managed.price_label
    assert_equal "Google Business Starter seat included", managed.price_note
    assert_equal "Quote", Integration.find(:payments).price_label
    Integration.groups.last.entries.each { |entry| assert_nil entry.price_label, entry.key }
  end

  test "[unit] an entry leads with a brand logo only for a known software key" do
    assert_equal "google", Integration.find(:google_workspace_connect).brand
    assert_nil Integration.find(:ai_features).brand
    assert_nil Integration.find(:custom_connectors).brand, "an emoji tile, not the tiny Egnyte mark"
  end

  test "[unit] the button follows the group and status, never Connect on Coming soon" do
    labels = Integration.entries.to_h { |entry| [ entry.key, entry.cta_label ] }

    assert_equal "Connect", labels["google_workspace_connect"]
    assert_equal "Connect", labels["discord"]
    assert_equal "Connect", labels["github_org"]
    assert_equal "Get notified", labels["slack"]
    assert_equal "Talk to us", labels["stripe_connect"], "Stripe moved to the custom section"
    Integration.groups.drop(1).flat_map(&:entries).each { |entry| assert_equal "Talk to us", entry.cta_label, entry.key }
    Integration.groups.last.entries.each { |entry| assert_equal "custom", entry.intent, entry.key }
    Integration.entries.select(&:soon?).each { |entry| refute_equal "connect", entry.intent, entry.key }
  end

  test "[unit] each entry's contact source and prefilled line" do
    github = Integration.find(:github_org)
    assert_equal({ page: "integrations", item: "github_org", intent: "connect" }, github.contact_source)
    assert_equal "I'd like to connect GitHub.", github.contact_message
    assert_equal "Please let me know when Slack is available.", Integration.find(:slack).contact_message
    assert_equal "I'd like to talk about AI features.", Integration.find(:ai_features).contact_message
    assert_equal({ page: "integrations", item: "ai_features", intent: "custom" }, Integration.find(:ai_features).contact_source)
  end

  test "[unit] an unknown status or tier fails the load" do
    assert_raises(ArgumentError) { Integration.send(:build_entry, "add_ons", { "key" => "x", "status" => "shipped" }) }
    assert_raises(ArgumentError) { Integration.send(:build_entry, "add_ons", { "key" => "x", "status" => "live", "tier" => "growth" }) }
  end
end
