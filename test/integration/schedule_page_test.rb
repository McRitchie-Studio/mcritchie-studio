require "test_helper"

# /schedule is where every "Schedule a call" link on the site lands: a public
# page that embeds the studio's Google Calendar booking page.
class SchedulePageTest < ActionDispatch::IntegrationTest
  test "a visitor can open the booking page without signing in" do
    get schedule_index_path

    assert_response :success
    assert_select "h1", "Schedule a call"
    # The URL waits in data-src: the page's script assigns src after `load`.
    assert_select "iframe[data-booking-frame]", 1 do |frames|
      assert_equal "#{ScheduleController::BOOKING_URL}?gv=true", frames.first["data-src"]
      assert_nil frames.first["src"]
    end
    assert_select "a[href='#{ScheduleController::BOOKING_URL}'][target='_blank']", text: "Open the booking page"
    assert_select "footer[data-site-footer]", 1
  end

  test "public pages carry the booking popup, its frame not yet requested" do
    [ root_path, about_path, privacy_path ].each do |path|
      get path

      assert_select "dialog[data-booking-dialog]", { count: 1 }, path
      assert_select "dialog[data-booking-dialog] iframe[data-booking-popup-frame]", 1 do |frames|
        assert_equal "#{ScheduleController::BOOKING_URL}?gv=true", frames.first["data-src"]
        assert_nil frames.first["src"]
      end
    end
  end

  test "the home page books through the same frame" do
    get root_path

    assert_select "iframe[data-booking-frame]", 1 do |frames|
      assert_equal "#{ScheduleController::BOOKING_URL}?gv=true", frames.first["data-src"]
      assert_nil frames.first["src"]
    end
  end

  test "neither page loads the Sprintful widget any more" do
    [ schedule_index_path, root_path ].each do |path|
      get path
      assert_no_match(/sprintful/i, response.body, path)
    end
  end
end
