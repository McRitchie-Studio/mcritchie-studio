require "application_system_test_case"

# [e2e] /integrations at phone and desktop width, light and dark: the page
# renders both groups and never scrolls sideways.
class IntegrationsPageTest < ApplicationSystemTestCase
  WIDTHS = [ 375, 1280 ].freeze

  teardown { page.driver.browser.manage.window.resize_to(*SCREEN_SIZE) }

  test "[e2e] /integrations loads light and dark at 375 and 1280 with no horizontal scroll" do
    %w[light dark].each do |theme|
      WIDTHS.each do |width|
        page.driver.browser.manage.window.resize_to(width, 1000)
        visit integrations_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_path

        assert_selector "[data-test='integration-group']", count: 2
        assert_equal theme == "dark", page.evaluate_script("document.documentElement.classList.contains('dark')"), "#{theme} at #{width}"
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "#{theme} at #{width}px scrolls sideways by #{overflow}px"
      end
    end
  end
end
