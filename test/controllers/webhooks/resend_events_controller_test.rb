require "test_helper"

# [integration] Resend's delivery and engagement webhooks: a signed event for
# a broadcast email lands in the event log once; a permanent bounce or a
# complaint takes the contact off the list; an unsigned request, or an event
# for an email that is not a broadcast, records nothing.
class Webhooks::ResendEventsControllerTest < ActionDispatch::IntegrationTest
  SECRET_KEY = "test-events-signing-key"

  setup do
    broadcast = Broadcast.create!(subject: "Hi", template_key: "cyvasse_is_back")
    @contact = Contact.create!(email: "events-#{SecureRandom.hex(3)}@example.com")
    @delivery = broadcast.deliveries.create!(contact: @contact, sent_at: 1.hour.ago, provider_message_id: "re_123")
    @original = ENV["RESEND_EVENTS_WEBHOOK_SECRET"]
    ENV["RESEND_EVENTS_WEBHOOK_SECRET"] = "whsec_#{Base64.strict_encode64(SECRET_KEY)}"
  end

  teardown do
    @original ? ENV["RESEND_EVENTS_WEBHOOK_SECRET"] = @original : ENV.delete("RESEND_EVENTS_WEBHOOK_SECRET")
  end

  def deliver(type, data = {}, msg_id: "msg_#{SecureRandom.hex(4)}", key: SECRET_KEY)
    body = { type: type, created_at: 5.minutes.ago.iso8601, data: { email_id: "re_123" }.merge(data) }.to_json
    timestamp = Time.current.to_i.to_s
    sig = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{msg_id}.#{timestamp}.#{body}"))
    post "/webhooks/resend/events", params: body,
         headers: { "svix-id" => msg_id, "svix-timestamp" => timestamp, "svix-signature" => "v1,#{sig}",
                    "CONTENT_TYPE" => "application/json" }
  end

  test "a signed delivered event is logged and stamps the delivery" do
    deliver("email.delivered")
    assert_response :ok
    event = @delivery.events.sole
    assert_equal ["delivered", "resend"], [event.kind, event.source]
    assert_not_nil @delivery.reload.delivered_at
  end

  test "a bad signature is refused and records nothing" do
    deliver("email.delivered", key: "wrong-key")
    assert_response :unauthorized
    assert_equal 0, EmailEvent.count
  end

  test "a permanent bounce is a hard bounce and unsubscribes the contact" do
    deliver("email.bounced", { bounce: { type: "Permanent", subType: "General", message: "No such user" } })
    assert_equal "hard", @delivery.reload.bounce_kind
    assert_not @contact.reload.subscribed?
    assert_equal "bounced", @contact.unsubscribe_reason
  end

  test "a temporary bounce is soft and keeps the contact" do
    deliver("email.bounced", { bounce: { type: "Transient", subType: "MailboxFull" } })
    assert_equal "soft", @delivery.reload.bounce_kind
    assert @contact.reload.subscribed?
  end

  test "a complaint unsubscribes the contact" do
    deliver("email.complained")
    assert_not_nil @delivery.reload.complained_at
    assert_equal "complained", @contact.reload.unsubscribe_reason
  end

  test "a redelivered webhook is recorded once" do
    2.times { deliver("email.delivered", msg_id: "msg_same") }
    assert_equal 1, @delivery.events.count
  end

  test "an event for an email that is not a broadcast is acknowledged and dropped" do
    body_for_other = { email_id: "re_signin_email" }
    deliver("email.delivered", body_for_other)
    assert_response :ok
    assert_equal 0, EmailEvent.count
  end

  test "a scanner's click on Resend's side is logged as a machine" do
    deliver("email.clicked", { click: { link: "https://cyvasse.mcritchie.studio/play", userAgent: "Barracuda Sentinel",
                                        timestamp: Time.current.iso8601 } })
    assert @delivery.events.of_kind("clicked").sole.machine
  end

  # [integration] Review follow-ups (PR #1654).
  test "a retried complaint still unsubscribes when the first attempt only logged it" do
    @delivery.record_event!(kind: "complained", source: "resend", provider_event_id: "msg_retry")
    assert @contact.reload.subscribed?, "the first attempt failed after logging"

    deliver("email.complained", msg_id: "msg_retry")
    assert_response :ok
    assert_equal "complained", @contact.reload.unsubscribe_reason
    assert_equal 1, @delivery.events.count
  end

  test "a blank secret refuses every request" do
    ENV["RESEND_EVENTS_WEBHOOK_SECRET"] = ""
    deliver("email.delivered")
    assert_response :unauthorized
  end

  test "a stale request is refused, so a captured one cannot be replayed" do
    body = { type: "email.delivered", data: { email_id: "re_123" } }.to_json
    old = 10.minutes.ago.to_i.to_s
    sig = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", SECRET_KEY, "msg_old.#{old}.#{body}"))
    post "/webhooks/resend/events", params: body,
         headers: { "svix-id" => "msg_old", "svix-timestamp" => old, "svix-signature" => "v1,#{sig}",
                    "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
    assert_equal 0, EmailEvent.count
  end

  test "an error is logged to ErrorLog and fails the request so Resend retries" do
    BroadcastDelivery.stub(:find_by, ->(*) { raise "boom" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_raises(RuntimeError) { deliver("email.delivered") }
      end
    end
  end
end
