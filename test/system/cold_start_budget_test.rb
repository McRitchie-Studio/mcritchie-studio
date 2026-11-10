require "application_system_test_case"

# Guards ApplicationSystemTestCase::COLD_START_READ_TIMEOUT
# (ci-cause-mcritchie-studio-reviewfollowupguardtest): the cold-start budget must sit on
# the browser that actually pays the run's cold Chrome launch, the Capybara session's own.
# Before the fix it sat on a throwaway browser that launched only after the session had
# already paid that launch on Selenium's stock budget: this read nil, Net::HTTP's 60s.
class ColdStartBudgetTest < ApplicationSystemTestCase
  test "[unit] the session's own browser launches and runs on the cold-start budget" do
    http = page.driver.browser.send(:bridge).http

    assert_equal ApplicationSystemTestCase::COLD_START_READ_TIMEOUT, http.read_timeout,
                 "the Capybara session's Chrome must carry the cold-start read budget, not Selenium's stock 60s"
  end
end
