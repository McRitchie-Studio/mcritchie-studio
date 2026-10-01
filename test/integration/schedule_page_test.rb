require "test_helper"

# /schedule is where every "Schedule a call" link on the site lands: a public
# page that embeds the studio's Google Calendar booking page.
class SchedulePageTest < ActionDispatch::IntegrationTest
  # Written out, not read from Studio.booking_url: this is the schedule the
  # site booked through before the engine rendered the frame, and the
  # initializer must still name it.
  BOOKING_URL = "https://calendar.google.com/calendar/appointments/schedules/" \
                "AcZssZ3_1hQYaxXWJCG8T-AAuv6YHQN9w3aRBnp-rtQc10YqH6k6Yy6FjUTtZLnwoT27Sr30YcOuZI1K".freeze

  test "a visitor can open the booking page without signing in" do
    get schedule_index_path

    assert_response :success
    assert_select "title", "Schedule a Call · McRitchie Studio"
    assert_select "h1", "Schedule a call"
    assert_select "p", "Pick a time that works and it lands on Alex's calendar."
    # The URL waits in data-src: the page's script assigns src after `load`.
    # data-studio-booking marks the frame as one the engine's script arms.
    assert_select "[data-booking-wrap][data-studio-booking] iframe[data-booking-frame][data-studio-booking]", 1 do |frames|
      assert_equal "#{BOOKING_URL}?gv=true", frames.first["data-src"]
      assert_nil frames.first["src"]
      assert_equal "Book a call with Alex McRitchie", frames.first["title"]
    end
    # Cropped to the slot picker at rest (the engine's class for it).
    assert_select "[data-booking-wrap].booking-frame-cropped", 1
    assert_select "a[href='#{BOOKING_URL}'][target='_blank']", text: "Open the booking page"
    assert_select "footer[data-site-footer]", 1
  end

  test "public pages carry the booking popup, its frame not yet requested" do
    [ root_path, about_path, privacy_path ].each do |path|
      get path

      assert_select "dialog[data-booking-dialog]", { count: 1 }, path
      assert_select "dialog[data-booking-dialog][data-studio-booking][aria-label='Schedule a call']", { count: 1 }, path
      assert_select "dialog[data-booking-dialog] iframe[data-booking-popup-frame]", 1 do |frames|
        assert_equal "#{BOOKING_URL}?gv=true", frames.first["data-src"]
        assert_nil frames.first["src"]
        assert_equal "Book a call with Alex McRitchie", frames.first["title"]
      end
    end
  end

  test "the home page books through the same frame" do
    get root_path

    # Inside the tinted Get in Touch band, where it has always been.
    assert_select "section[data-get-in-touch] iframe[data-booking-frame][data-studio-booking]", 1 do |frames|
      assert_equal "#{BOOKING_URL}?gv=true", frames.first["data-src"]
      assert_nil frames.first["src"]
    end
    assert_select "iframe[data-booking-frame]", 1
    assert_select "section[data-get-in-touch] a[href='#{BOOKING_URL}'][target='_blank']", text: "Open the booking page"
  end

  test "the engine holds the schedule this app configured, and does not draw /schedule itself" do
    assert_equal BOOKING_URL, Studio.booking_url
    assert_not Studio.draw_booking_routes
    assert_equal({ controller: "schedule", action: "index" }, Rails.application.routes.recognize_path("/schedule"))
  end

  test "neither page loads the Sprintful widget any more" do
    [ schedule_index_path, root_path ].each do |path|
      get path
      assert_no_match(/sprintful/i, response.body, path)
    end
  end
end
