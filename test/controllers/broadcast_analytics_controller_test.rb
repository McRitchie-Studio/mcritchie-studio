require "test_helper"

# [component] The analytics dashboard: admins only, and every section draws,
# with and without sends.
class BroadcastAnalyticsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @broadcast = Broadcast.create!(slug: "cyvasse-is-back", subject: "Cyvasse is back", template_key: "cyvasse_is_back")
  end

  test "only admins see it" do
    get broadcast_analytics_path
    assert_response :redirect
    log_in_as(@viewer)
    get broadcast_analytics_path
    assert_redirected_to root_path
  end

  test "with nothing sent every section says so" do
    log_in_as(@admin)
    get broadcast_analytics_path
    assert_response :success
    assert_select "[data-health=bounce-rate]", text: /No sends yet/
    assert_select "h2", text: "Funnel"
    assert_select "td", text: "Nothing sent yet.", minimum: 1
    assert_select "[data-unknown-filter]", count: 0
  end

  test "sends show their rates, and the filter narrows to one email" do
    delivery = @broadcast.deliveries.create!(contact: Contact.create!(email: "p@gmail.com"), sent_at: 1.hour.ago)
    delivery.record_event!(kind: "delivered", source: "resend")
    delivery.record_click!(link_key: "play")
    log_in_as(@admin)

    get broadcast_analytics_path
    assert_select "[data-health=bounce-rate]", text: /Healthy/
    assert_select "section[aria-label='By email'] a", text: "Cyvasse is back"
    assert_select "td", text: "play"
    assert_select "section[aria-label='By mailbox provider'] td", text: "Gmail"

    get broadcast_analytics_path(broadcast: "cyvasse-is-back")
    assert_select "p", text: /Cyvasse is back/
    assert_select "[data-unknown-filter]", count: 0, message: "a real email is not an unknown filter"
    assert_select "section[aria-label='By email']", count: 0
  end

  test "the broadcasts list links to it" do
    log_in_as(@admin)
    get broadcasts_path
    assert_select "a[href=?]", broadcast_analytics_path, text: "Analytics"
  end

  test "an unknown email filter says so and shows every broadcast" do
    log_in_as(@admin)
    get broadcast_analytics_path(broadcast: "no-such-email")
    assert_select "[data-unknown-filter]", text: /No email is called “no-such-email”/
    get broadcast_analytics_path(broadcast: "<b>x</b>")
    assert_select "[data-unknown-filter] b", count: 0, message: "the filter value is shown as text, never as markup"
    assert_select "section[aria-label='By email']"
  end
end
