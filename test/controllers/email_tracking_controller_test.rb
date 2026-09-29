require "test_helper"

class EmailTrackingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @broadcast = Broadcast.create!(
      subject: "Tracking smoke",
      template_key: "new_game_announcement",
      hero_url: "https://example.com/hero",
      survivor_url: "https://example.com/survivor",
      turf_totals_url: "https://example.com/turf"
    )
    @contact = Contact.create!(email: "tracking-#{SecureRandom.hex(4)}@example.com", first_name: "Track")
    @delivery = @broadcast.deliveries.create!(contact: @contact)
  end

  test "open pixel records an open and returns a transparent gif" do
    get email_open_path(token: @delivery.token)

    assert_response :success
    assert_equal "image/gif", response.media_type
    assert_equal 1, @delivery.reload.open_count
    assert_not_nil @delivery.opened_at
  end

  test "open pixel ignores invalid tokens without leaking state" do
    get email_open_path(token: "not-real")

    assert_response :success
    assert_equal "image/gif", response.media_type
  end

  test "click endpoint records valid tracked links and redirects to the server-side url" do
    get email_click_path(token: @delivery.token, l: "turf_totals")

    assert_redirected_to "https://example.com/turf"
    assert_equal 1, @delivery.reload.click_count
    assert_not_nil @delivery.clicked_at
  end

  test "click endpoint falls back home for invalid link keys" do
    get email_click_path(token: @delivery.token, l: "unknown")

    assert_redirected_to root_url
    assert_equal 0, @delivery.reload.click_count
  end

  # [integration] The event log: which link, and whether a person clicked.
  test "a person's click logs its link and sets the human click time" do
    get email_click_path(token: @delivery.token, l: "turf_totals"), headers: { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" }

    event = @delivery.events.of_kind("clicked").sole
    assert_equal ["turf_totals", false], [event.link_key, event.machine]
    assert_not_nil @delivery.reload.human_clicked_at
  end

  test "a scanner's click is logged as a machine and leaves the human click time empty" do
    get email_click_path(token: @delivery.token, l: "turf_totals"), headers: { "User-Agent" => "Barracuda Sentinel" }

    assert @delivery.events.of_kind("clicked").sole.machine
    assert_nil @delivery.reload.human_clicked_at
  end

  test "Apple's privacy prefetch of the pixel is a machine open" do
    get email_open_path(token: @delivery.token), headers: { "User-Agent" => "Mozilla/5.0" }

    assert @delivery.events.of_kind("opened").sole.machine
    assert_equal 1, @delivery.reload.open_count
    assert_nil @delivery.human_opened_at
  end

  # [integration] Result tracking: a click that lands on one of our sites
  # carries the email's ref; a beacon credits a goal once.
  test "a tracked Cyvasse link lands with the email's ref" do
    cyvasse = Broadcast.create!(subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    delivery = cyvasse.deliveries.create!(contact: @contact)
    get email_click_path(token: delivery.token, l: "play")

    assert_redirected_to "https://cyvasse.mcritchie.studio/?ref=#{delivery.token}"
    assert_equal "play", delivery.events.of_kind("clicked").sole.link_key
  end

  test "a link to someone else's site carries no ref" do
    get email_click_path(token: @delivery.token, l: "turf_totals")
    assert_redirected_to "https://example.com/turf"
  end

  test "a result beacon credits its goal once and answers a gif" do
    2.times { get email_goal_path(token: @delivery.token, g: "signed_in") }

    assert_response :success
    assert_equal "image/gif", response.media_type
    assert_equal 1, @delivery.events.of_kind("converted").count
  end

  test "a beacon with an unknown goal or token records nothing" do
    get email_goal_path(token: @delivery.token, g: "nope")
    get email_goal_path(token: "not-real", g: "signed_in")
    assert_response :success
    assert_equal 0, EmailEvent.count
  end
end
