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
      expected = item == "discord" ? integrations_discord_path : contact_form_path(source: { page: "integrations", item: item, intent: intent })
      assert_equal expected, cta["href"], item
    end
  end

  test "[component] the add-on is named Managed Workspace, keeps the Google logo and names Google Workspace" do
    get integrations_path

    assert_select "#{entry('google_workspace_managed')} [data-test='entry-name']", text: "Managed Workspace"
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-lead'][data-lead='google']"
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-blurb']", text: /Google Workspace/
    assert_no_match(/Google Workspace, managed/, response.body)
  end

  test "[component] the Discord card says two-way, stays On request, and opens its guide" do
    get integrations_path

    assert_select "#{entry('discord')} [data-test='entry-blurb']", text: /two-way/i
    assert_select "#{entry('discord')} [data-test='on-request']"
    assert_select "#{entry('discord')} [data-test='entry-cta'][href='#{integrations_discord_path}']", text: "Connect"
  end

  # --- /integrations/discord --------------------------------------------------

  test "[component] the Discord guide renders publicly with examples, setup and the permissions note" do
    get integrations_discord_path

    assert_response :success
    assert_select "h1", text: "Give your agents a home in Discord"
    assert_select "[data-test='discord-guide'] header [data-test='on-request']", text: "On request"
    assert_select "[data-test='examples-label']", text: /Examples/
    assert_select "[data-test='example-post']", minimum: 3
    assert_select "[data-test='example-exchange-line']", 2
    assert_select "[data-test='example-exchange']", text: /@Studio CTO why is checkout slow\?/
    assert_select "[data-test='setup-step']", 3
    assert_select "[data-test='setup-step']", text: /No links or passwords change hands/
    assert_select "[data-test='permissions-note']", text: /You approve exactly what the bot can do, and you can remove it any time from your server settings\./
    assert_select "[data-test='back-to-integrations'][href='#{integrations_path}']"
  end

  test "[component] the guide's button requests the bot through the contact form, never a Discord authorization link" do
    get integrations_discord_path

    assert_select "[data-test='discord-request-cta']", text: "Request the Discord bot" do |cta|
      assert_equal contact_form_path(source: { page: "integrations/discord", item: "discord", intent: "connect" }), cta.first["href"]
    end
    assert_no_match(%r{discord(app)?\.com/(api/)?oauth2}, response.body)
    assert_no_match(/webhook/i, response.body, "the webhook version is gone")
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
