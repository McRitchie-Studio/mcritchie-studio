# frozen_string_literal: true

require "test_helper"

# [component] /stack in isolation: one row per client with its tier, a software
# strip where MS-hosted software wears the Studio chest and the client's own
# accounts are plain, then Google users and Resend mode.
#
# Named ...ViewTest so it can never collide with the controller test's class.
class StackViewTest < ActionView::TestCase
  setup do
    vault = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
    records = [
      CredentialRecord.create!(credential_vault: vault, title: "agent.turf.x", service: "x", entity: "turf-monster")
    ]
    WorkspaceAccount.create!(domain: "turfmonster.media", status: "active")
    @clients = [
      StackClient.create!(slug: "turf-monster", name: "Turf Monster", tier: "agentic", domain: "turfmonster.media",
                          google_users: 3, resend_mode: "ms", hosting: { "heroku" => "own" }, position: 1),
      StackClient.create!(slug: "studio", name: "McRitchie Studio", tier: "internal", position: 2)
    ]
    @records_by_entity = records.group_by(&:served_entity)
  end

  def row(slug) = "[data-test='stack-client'][data-client='#{slug}']"
  def icon(slug, software) = "#{row(slug)} [data-test='stack-software-icon'][data-software='#{software}']"

  test "one row per client, in position order, each with its tier" do
    render template: "stack/index"

    assert_equal %w[turf-monster studio], css_select("[data-test='stack-client']").map { |tr| tr["data-client"] }
    assert_select "#{row('turf-monster')} [data-test='stack-tier']", text: %r{Agentic · \$500/mo}
    assert_select "#{row('studio')} [data-test='stack-tier']", text: /Internal/
  end

  test "MS-hosted software wears the Studio chest; the client's own accounts are plain" do
    render template: "stack/index"

    assert_select "#{icon('turf-monster', 'google')}[data-hosting='ms'] img[src*='workspace_icons/google/studio']", 1
    assert_select "#{icon('turf-monster', 'x')}[data-hosting='own'] img[src*='workspace_icons/software/x']", 1
    assert_select "#{icon('turf-monster', 'heroku')}[data-hosting='own']", 1, "the override made Heroku white label"
  end

  test "each icon's tooltip says who hosts it" do
    render template: "stack/index"

    assert_select "#{icon('turf-monster', 'google')}[title*='hosted by McRitchie Studio']"
    assert_select "#{icon('turf-monster', 'x')}[title*=\"Turf Monster's own account\"]"
  end

  test "Google users and Resend mode close each row; unknowns read as a dash" do
    render template: "stack/index"

    assert_select "#{row('turf-monster')} [data-test='stack-google-users']", text: /3.*delegation · active/m
    assert_select "#{row('turf-monster')} [data-test='stack-resend'][data-mode='ms']", text: /McRitchie Studio account/
    assert_select "#{row('studio')} [data-test='stack-google-users']", text: /—/
    assert_select "#{row('studio')} [data-test='stack-resend']", text: /—/
  end
end
