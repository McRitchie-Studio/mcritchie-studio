require "test_helper"

# /schedule is where every "Schedule a call" link on the site lands: a public
# page that embeds the studio's Google Calendar booking page.
class SchedulePageTest < ActionDispatch::IntegrationTest
  test "a visitor can open the booking page without signing in" do
    get schedule_index_path

    assert_response :success
    assert_select "h1", "Schedule a call"
    assert_select "iframe[data-booking-frame][loading='lazy']", 1 do |frames|
      assert_equal "#{ScheduleController::BOOKING_URL}?gv=true", frames.first["src"]
    end
    assert_select "a[href='#{ScheduleController::BOOKING_URL}'][target='_blank']", text: "Open the booking page"
    assert_select "footer[data-site-footer]", 1
  end

  test "the page no longer loads the Sprintful widget" do
    get schedule_index_path

    assert_no_match(/sprintful/i, response.body)
  end
end
