require "test_helper"

# [component] /integrations: public, both groups, Coming soon tags on every
# entry not delivered, prices on add-ons, and a booking CTA on every entry.
class IntegrationsControllerTest < ActionDispatch::IntegrationTest
  def entry(key) = "[data-test='integration-entry'][data-entry='#{key}']"

  test "[component] anyone sees both groups, without signing in" do
    get integrations_path

    assert_response :success
    assert_select "h1", text: "Build smarter. Your backend runs itself."
    assert_equal %w[integrations add_ons], css_select("[data-test='integration-group']").map { |g| g["data-group"] }
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
    assert_select "[data-test='entry-cta'][data-cta='connect']", count: Integration.entries.count { |e| e.cta == "connect" }
    css_select("[data-test='entry-cta'][data-cta='connect']").each do |cta|
      assert_equal "live", cta.ancestors("[data-test='integration-entry']").first["data-status"]
    end
  end

  test "[component] integrations read Free, add-ons a price or Quote, each with its CTA" do
    get integrations_path

    assert_select "#{entry('discord')} [data-test='entry-price']", text: /Free/
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-price']", text: %r{\$10/user/month}
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-price-note']", text: /\$250 one-time setup/
    assert_select "#{entry('payments')} [data-test='entry-price']", text: /Quote/
    assert_select "#{entry('discord')} [data-test='entry-cta']", text: "Connect"
    assert_select "#{entry('slack')} [data-test='entry-cta']", text: "Talk to us"
    assert_select "#{entry('google_workspace_connect')} [data-test='entry-tier']", text: "From Pro"
    assert_select "#{entry('google_workspace_connect')} [data-test='entry-lead'][data-lead='google'] [data-test='brand-logo']"
    css_select("[data-test='entry-cta']").each { |cta| assert_equal schedule_index_path, cta["href"] }
  end

  test "[component] the page closes on Book a call and links back to /packages, and /packages links here" do
    get integrations_path
    assert_select "[data-test='not-listed'] [data-test='not-listed-cta'][href='#{schedule_index_path}']", text: "Book a call"
    assert_select "[data-test='packages-link'][href='#{packages_path}']"

    get packages_path
    assert_select "[data-test='integrations-link'][href='#{integrations_path}']"
  end
end
