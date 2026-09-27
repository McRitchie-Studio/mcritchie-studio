require "test_helper"

# [unit] The event log and the rollups the dashboard reads.
class BroadcastDeliveryTest < ActiveSupport::TestCase
  setup do
    broadcast = Broadcast.create!(subject: "Hi", template_key: "cyvasse_is_back")
    contact = Contact.create!(email: "rollup-#{SecureRandom.hex(3)}@example.com")
    @delivery = broadcast.deliveries.create!(contact: contact, sent_at: 1.hour.ago)
  end

  test "an open logs an event and keeps the first time, counting people apart from machines" do
    first = 30.minutes.ago
    @delivery.record_open!(machine: true, at: first - 20.minutes)
    @delivery.record_open!(at: first)
    @delivery.record_open!(at: first + 5.minutes)
    @delivery.reload

    assert_equal 3, @delivery.open_count
    assert_equal 3, @delivery.events.of_kind("opened").count
    assert_equal first.to_i, @delivery.human_opened_at.to_i
    assert_operator @delivery.opened_at, :<, @delivery.human_opened_at
  end

  test "a click keeps its link and a machine click never sets the human time" do
    @delivery.record_click!(link_key: "play", machine: true)
    @delivery.reload
    assert_equal 1, @delivery.click_count
    assert_nil @delivery.human_clicked_at
    assert_equal "play", @delivery.events.of_kind("clicked").last.link_key
  end

  test "Resend's own open and click reports are logged but never counted twice" do
    @delivery.record_open!(source: "resend")
    @delivery.record_click!(source: "resend", link_key: nil)
    @delivery.reload
    assert_equal 0, @delivery.open_count
    assert_equal 0, @delivery.click_count
    assert_equal 2, @delivery.events.count
  end

  test "delivery, bounce, complaint and unsubscribe stamp their first times" do
    @delivery.record_event!(kind: "delivered", source: "resend")
    @delivery.record_event!(kind: "bounced", source: "resend", data: { "bounce_kind" => "hard" })
    @delivery.record_event!(kind: "complained", source: "resend")
    @delivery.record_event!(kind: "unsubscribed", source: "page")
    @delivery.reload
    assert @delivery.delivered_at && @delivery.bounced_at && @delivery.complained_at && @delivery.unsubscribed_at
    assert_equal "hard", @delivery.bounce_kind
  end

  test "a webhook redelivered under the same event id is recorded once" do
    assert @delivery.record_event!(kind: "delivered", source: "resend", provider_event_id: "msg_1")
    assert_nil @delivery.record_event!(kind: "delivered", source: "resend", provider_event_id: "msg_1")
    assert_equal 1, @delivery.events.count
  end
end
