require "test_helper"

# [unit] config/integrations.yml: three groups, every entry with a known status
# and a real tier, and the button each one gets: Connect for an integration
# live or on request, Get notified for a Coming soon one, Talk to us for an
# add-on or a custom need. Never Connect on a Coming soon entry.
class IntegrationTest < ActiveSupport::TestCase
  test "[unit] the config loads five groups: Google sign-in, meeting notes, integrations, add-ons, then custom" do
    groups = Integration.groups

    assert_equal %w[google_sign_in meeting_notes integrations add_ons custom], groups.map(&:key)
    groups.each { |group| assert group.entries.any?, "#{group.key} has entries" }
  end

  test "[unit] every entry has a known status and, when gated, a real tier" do
    Integration.entries.each do |entry|
      assert_includes Integration::STATUSES, entry.status, entry.key
      assert WorkspacePackage.find(entry.tier), "#{entry.key}: tier #{entry.tier}" if entry.tier.present?
    end
    assert_equal Integration.entries.size, Integration.entries.map(&:key).uniq.size, "keys are unique"
  end

  test "[unit] the statuses Alex McRitchie set on 2026-10-13" do
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
    assert_equal "From Builder", Integration.find(:extra_builds).availability
    assert_nil Integration.find(:slack).availability
  end

  test "[unit] integrations are free; an add-on shows its price or Quote; a custom entry no price" do
    Integration.groups.first.entries.each { |entry| assert_equal "Free", entry.price_label, entry.key }
    managed = Integration.find(:google_workspace_managed)
    assert_equal "Managed Workspace", managed.name
    assert_equal "I'd like to talk about Managed Workspace.", managed.contact_message
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
    Integration.groups.select { %w[add_ons custom].include?(_1.key) }.flat_map(&:entries).each { |entry| assert_equal "Talk to us", entry.cta_label, entry.key }
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

  test "[unit] Discord has a guide page, whose button carries its own source" do
    discord = Integration.find(:discord)
    assert_equal "Discord", discord.name
    assert_equal "I'd like to connect Discord.", discord.contact_message
    assert_equal "discord", discord.guide
    assert_equal({ page: "integrations/discord", item: "discord", intent: "connect" }, discord.guide_contact_source)
    assert_raises(ArgumentError) { Integration.send(:build_entry, "integrations", { "key" => "x", "status" => "live", "guide" => "teams" }) }
  end

  test "[unit] an unknown status or tier fails the load" do
    assert_raises(ArgumentError) { Integration.send(:build_entry, "add_ons", { "key" => "x", "status" => "shipped" }) }
    assert_raises(ArgumentError) { Integration.send(:build_entry, "add_ons", { "key" => "x", "status" => "live", "tier" => "growth" }) }
  end

  test "[unit] the five connection methods, each with who it covers, setup and upkeep" do
    methods = Integration.connection_methods

    assert_equal %w[sign_in admin_grant app_install api_key managed], methods.keys
    methods.each_value { |m| assert(m.label.present? && m.covers.present? && m.setup.present? && m.upkeep.present?, m.key) }
    assert_equal "May ask you to sign in again", methods["sign_in"].upkeep
    assert_equal "No upkeep", methods["admin_grant"].upkeep
  end

  test "[unit] Google Workspace connects by admin grant; Calendar, Gmail and Drive each by one sign-in" do
    google = Integration.find(:google_workspace_connect)

    assert_equal %w[admin_grant], google.connects
    assert_equal %w[draft_email knowledge_base], google.abilities.map(&:key)
    refute google.method_soon?("admin_grant")

    { google_calendar: "read_calendar", gmail: "read_email", google_drive: "read_drive" }.each do |key, ability|
      entry = Integration.find(key)
      assert entry.live?, key
      assert_equal %w[sign_in], entry.connects, key
      assert_equal [ ability ], entry.abilities.map(&:key), key
      refute entry.abilities.first.soon?, "#{key}: live, the hub reads its own"
      refute entry.method_soon?("sign_in"), key
    end
    assert_equal IntegrationsController::GOOGLE_CARDS.keys.sort, %w[gmail google_calendar google_drive], "every Google card carries the admin buttons"
  end

  test "[unit] every ability in the config names only ways its entry connects" do
    Integration.entries.each do |entry|
      entry.abilities.each { |ability| assert_empty ability.via - entry.connects, "#{entry.key}.#{ability.key}" }
    end
  end

  test "[unit] the load refuses an ability naming a way the entry does not connect" do
    attrs = { "key" => "x", "status" => "live", "connects" => [ "sign_in" ],
              "abilities" => [ { "key" => "a", "name" => "A", "via" => [ "admin_grant" ] } ] }
    error = assert_raises(ArgumentError) { Integration.send(:build_entry, "integrations", attrs) }
    assert_match(/admin_grant is not a way x connects/, error.message)

    assert Integration.send(:build_entry, "integrations", attrs.merge("connects" => %w[sign_in admin_grant])) # the control
  end

  test "[unit] the load refuses an unknown method, an ability with no way, a bad status, and duplicate abilities" do
    build = ->(attrs) { Integration.send(:build_entry, "integrations", { "key" => "x", "status" => "live" }.merge(attrs)) }
    ability = { "key" => "a", "name" => "A", "via" => [ "sign_in" ] }

    assert_raises(ArgumentError) { build.("connects" => [ "carrier_pigeon" ]) }
    assert_raises(ArgumentError) { build.("connects" => [ "sign_in" ], "abilities" => [ ability.merge("via" => []) ]) }
    assert_raises(ArgumentError) { build.("connects" => [ "sign_in" ], "abilities" => [ ability.merge("status" => "beta") ]) }
    assert_raises(ArgumentError) { build.("connects" => [ "sign_in" ], "abilities" => [ ability, ability ]) }
    assert_raises(ArgumentError) { build.("connects" => [ "sign_in" ], "abilities" => [ ability.merge("name" => "") ]) }
    # What YAML makes of { name: Post sign-ups, errors and updates }: a stray key.
    error = assert_raises(ArgumentError) { build.("connects" => [ "sign_in" ], "abilities" => [ ability.merge("errors and updates" => nil) ]) }
    assert_match(/quote a name with a comma/, error.message)
  end

  test "[unit] an entry with no connections has none, and a lone method follows the entry's status" do
    assert_empty Integration.find(:ai_features).connection_methods
    assert Integration.find(:stripe_connect).method_soon?("sign_in"), "Stripe is Coming soon"
    refute Integration.find(:google_workspace_managed).method_soon?("managed")
  end
end
