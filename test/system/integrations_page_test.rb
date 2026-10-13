require "application_system_test_case"

# [e2e] /integrations at phone and desktop width, light and dark: the page
# renders both groups and never scrolls sideways.
class IntegrationsPageTest < ApplicationSystemTestCase
  WIDTHS = [ 375, 1280 ].freeze

  # A headless window will not shrink below about 500px, so the width is set by
  # device emulation: innerWidth is then the width under test, asserted below.
  teardown { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  test "[e2e] /integrations loads light and dark at 375 and 1280 with no horizontal scroll" do
    %w[light dark].each do |theme|
      WIDTHS.each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)
        visit integrations_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_path

        assert_selector "[data-test='integration-group']", count: 2
        assert_equal width, page.evaluate_script("window.innerWidth"), "viewport is #{width}px"
        assert_equal theme == "dark", page.evaluate_script("document.documentElement.classList.contains('dark')"), "#{theme} at #{width}"
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "#{theme} at #{width}px scrolls sideways by #{overflow}px"
      end
    end
  end

  test "[e2e] a card's Connect opens the contact form prefilled, carrying where it came from" do
    visit integrations_path
    within("[data-test='integration-entry'][data-entry='github_org']") { click_on "Connect" }

    assert_current_path(/\A\/contact\?/)
    assert_field "contact_submission[message]", with: "I'd like to connect GitHub."
    hidden = all("[data-test='contact-source']", visible: :all).to_h { |input| [ input["data-source-key"], input.value ] }
    assert_equal({ "page" => "integrations", "item" => "github_org", "intent" => "connect", "ref" => "/integrations" }, hidden)
    assert_selector "[data-test='contact-consent'] input[type='checkbox']:checked", count: 0
  end
end
