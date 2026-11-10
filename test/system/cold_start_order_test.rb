require "application_system_test_case"

# Guards ApplicationSystemTestCase.warm_browser_once (ci-cause-mcritchie-studio-reviewfollowupguardtest).
#
# CAUSE. `Capybara.current_session` builds the Rails-registered selenium driver, and that
# driver launches Chrome AT ONCE (ActionDispatch::SystemTesting::Driver#register_selenium
# reads `driver.browser` to size the window). It launches on Selenium's default HTTP
# client: Net::HTTP's 60s read timeout. The warm-up called `current_session` FIRST, so the
# run's cold Chrome launch was paid on the 60s budget, and the throwaway browser with the
# 180s budget only ever launched a warm Chrome (0.5s in every sampled run, while the
# "server" phase carried the 1-13s cold launch). CI run 42767245996 attempt 1: the first
# test died with Net::ReadTimeout at `current_session`, ~104s into the run; attempt 2 at
# the same SHA paid it in 2.4s.
#
# A plain ActiveSupport::TestCase, so it opens no browser of its own; it lives under
# test/system because it needs the system case loaded and runs in the system job.
class ColdStartOrderTest < ActiveSupport::TestCase
  FakeDriver = Struct.new(:visited) do
    def navigate = self
    def to(url) = visited << url
    def quit = nil
  end

  test "[unit] the run's first Chrome launch is on the cold-start budget, before the Capybara session" do
    events = []
    driver = FakeDriver.new([])
    launch = lambda do |browser, **kwargs|
      events << [ :throwaway_launch, browser, kwargs[:http_client].read_timeout ]
      driver
    end
    session = Struct.new(:server).new(Struct.new(:base_url).new("http://127.0.0.1:9"))
    open_session = lambda do
      events << [ :capybara_session ]
      session
    end

    with_warm_up_armed do
      Selenium::WebDriver.stub(:for, launch) do
        Capybara.stub(:current_session, open_session) do
          capture_io { ApplicationSystemTestCase.warm_browser_once }
        end
      end
    end

    assert_equal [ :throwaway_launch, :chrome, ApplicationSystemTestCase::COLD_START_READ_TIMEOUT ], events.first,
                 "the cold Chrome launch must come before Capybara.current_session, whose driver launches " \
                 "Chrome on Selenium's default 60s read timeout"
    assert_equal [ :capybara_session ], events.second
    assert_equal [ "http://127.0.0.1:9/" ], driver.visited, "the first render is still paid on the cold budget"
  end

  private

  # Run the warm-up for real in this test, then put the run-wide flag back, so a seed that
  # runs this test first still warms the real browser before the first system test.
  def with_warm_up_armed
    flag = :@browser_warmed
    saved = ApplicationSystemTestCase.instance_variable_get(flag)
    ApplicationSystemTestCase.instance_variable_set(flag, false)
    yield
  ensure
    ApplicationSystemTestCase.instance_variable_set(flag, saved)
  end
end
