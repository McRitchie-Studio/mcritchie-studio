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
end
