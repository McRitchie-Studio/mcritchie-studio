require "test_helper"

# [component] /integrations: public, both groups, Coming soon tags on every
# entry not delivered, prices on add-ons, and a booking CTA on every entry.
class IntegrationsControllerTest < ActionDispatch::IntegrationTest
  def entry(key) = "[data-test='integration-entry'][data-entry='#{key}']"

  test "[component] anyone sees both groups, without signing in" do
    get integrations_path

    assert_response :success
    assert_select "h1", text: "Build smarter. Your backend runs itself."
    assert_equal %w[integrations add_ons custom], css_select("[data-test='integration-group']").map { |g| g["data-group"] }
    assert_equal Integration.entries.map(&:key), css_select("[data-test='integration-entry']").map { |e| e["data-entry"] }
  end

  test "[component] every entry not live reads Coming soon or On request, never Available" do
    get integrations_path

    Integration.entries.each do |item|
      if item.soon?
        assert_select "#{entry(item.key)} [data-test='coming-soon']", text: "Coming soon"
      elsif item.on_request?
        assert_select "#{entry(item.key)} [data-test='on-request']", text: "On request"
      end
      assert_select "#{entry(item.key)} [data-test='available']", item.live? ? 1 : 0
    end
    css_select("[data-test='entry-cta'][data-intent='connect']").each do |cta|
      refute_equal "soon", cta.ancestors("[data-test='integration-entry']").first["data-status"]
    end
  end

  test "[component] integrations read Free, add-ons a price or Quote, each with its button" do
    get integrations_path

    assert_select "#{entry('discord')} [data-test='entry-price']", text: /Free/
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-price']", text: %r{\$25/month \+ \$15/user/month}
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-price-note']", text: "Google Business Starter seat included"
    assert_no_match(/\$250/, response.body)
    assert_select "#{entry('payments')} [data-test='entry-price']", text: /Quote/
    assert_select "#{entry('discord')} [data-test='entry-cta']", text: "Connect"
    assert_select "#{entry('github_org')} [data-test='entry-cta']", text: "Connect"
    assert_select "#{entry('slack')} [data-test='entry-cta']", text: "Get notified"
    assert_select "#{entry('stripe_connect')} [data-test='entry-cta']", text: "Talk to us"
    assert_select "#{entry('payments')} [data-test='entry-cta']", text: "Talk to us"
    assert_select "#{entry('payments')} [data-test='on-request']"
    assert_select "#{entry('google_workspace_connect')} [data-test='entry-tier']", text: "From Pro"
    assert_select "#{entry('google_workspace_connect')} [data-test='entry-lead'][data-lead='google'] [data-test='brand-logo']"
    css_select("[data-test='entry-cta']").each do |cta|
      item = cta.ancestors("[data-test='integration-entry']").first["data-entry"]
      intent = Integration.find(item).intent
      assert_equal contact_form_path(source: { page: "integrations", item: item, intent: intent }), cta["href"], item
    end
  end

  test "[component] the Talk to us section: Custom eyebrow, no price line, one Talk to us button each" do
    get integrations_path

    group = "[data-test='integration-group'][data-group='custom']"
    assert_select "#{group} [data-test='group-kicker']", text: "Custom"
    assert_select "#{group} h2", text: "Talk to us"
    assert_equal %w[stripe_connect crypto extra_storage ai_features custom_connectors enterprise_extras],
                 css_select("#{group} [data-test='integration-entry']").map { |e| e["data-entry"] }
    assert_select "#{group} [data-test='entry-price']", 0
    assert_no_match(/Scoped on a call/, css_select(group).to_s)
    css_select("#{group} [data-test='integration-entry']").each do |card|
      ctas = card.css("[data-test='entry-cta']")
      assert_equal [ "Talk to us" ], ctas.map { |c| c.text.strip }, card["data-entry"]
      assert_equal "custom", ctas.first["data-intent"]
    end
    assert_select "#{entry('stripe_connect')} [data-test='coming-soon']"
    assert_select "[data-test='integration-group'][data-group='integrations'] #{entry('stripe_connect')}", 0, "Stripe is listed once"
    assert_equal %w[google_workspace_connect discord github_org slack],
                 css_select("[data-test='integration-group'][data-group='integrations'] [data-test='integration-entry']").map { |e| e["data-entry"] }
    assert_equal %w[google_workspace_managed payments extra_builds],
                 css_select("[data-test='integration-group'][data-group='add_ons'] [data-test='integration-entry']").map { |e| e["data-entry"] }
  end

  test "[component] the page closes on Book a call and links back to /packages, and /packages links here" do
    get integrations_path
    assert_select "[data-test='not-listed'] [data-test='not-listed-cta'][href='#{schedule_index_path}']", text: "Book a call"
    assert_select "[data-test='packages-link'][href='#{packages_path}']"

    get packages_path
    assert_select "[data-test='integrations-link'][href='#{integrations_path}']"
  end
end
