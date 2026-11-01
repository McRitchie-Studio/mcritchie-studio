require "application_system_test_case"

# [e2e] The four-style scoreboard loads for an admin, drawing all four styles,
# and never scrolls sideways at phone width outside its table.
class CyvasseFourScoreboardTest < ApplicationSystemTestCase
  teardown { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  test "[e2e] the scoreboard loads at phone and desktop width" do
    Broadcasts::CyvasseFour::STYLES.each do |style, (key, _)|
      Broadcast.create!(slug: "cyvasse-four-#{style}", subject: style, template_key: key)
    end
    [ 375, 1280 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      visit cyvasse_four_scoreboard_path
      assert_text "Nothing sent yet"
      assert_selector "tr[data-style]", count: 4, visible: :all
      assert_operator evaluate_script("document.documentElement.scrollWidth"), :<=, evaluate_script("document.documentElement.clientWidth")
    end
  end
end
