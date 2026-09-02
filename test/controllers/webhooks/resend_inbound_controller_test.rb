require "test_helper"

# [integration] The Resend inbound webhook — its whole security story is the
# svix signature check, so that is what these tests bite on: a correctly
# signed email.received enqueues ingestion; everything else bounces with
# nothing enqueued.
class Webhooks::ResendInboundControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET_KEY = "test-signing-key-material"

  def sign(body, msg_id: "msg_1", timestamp: Time.current.to_i.to_s, key: SECRET_KEY)
    sig = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{msg_id}.#{timestamp}.#{body}"))
    { "svix-id" => msg_id, "svix-timestamp" => timestamp, "svix-signature" => "v1,#{sig}" }
  end

  def with_secret
    original = ENV["RESEND_WEBHOOK_SECRET"]
    ENV["RESEND_WEBHOOK_SECRET"] = "whsec_#{Base64.strict_encode64(SECRET_KEY)}"
    yield
  ensure
    original ? ENV["RESEND_WEBHOOK_SECRET"] = original : ENV.delete("RESEND_WEBHOOK_SECRET")
  end

  test "a signed email.received enqueues ingestion" do
    with_secret do
      body = { type: "email.received", data: { email_id: "re_abc123" } }.to_json
      assert_enqueued_with(job: DeskCaptureResendIngestJob, args: [ "re_abc123" ]) do
        post "/webhooks/resend/inbound", params: body,
             headers: sign(body).merge("CONTENT_TYPE" => "application/json")
      end
      assert_response :ok
    end
  end

  test "a bad signature bounces with nothing enqueued" do
    with_secret do
      body = { type: "email.received", data: { email_id: "re_abc123" } }.to_json
      assert_no_enqueued_jobs do
        post "/webhooks/resend/inbound", params: body,
             headers: sign(body, key: "wrong-key").merge("CONTENT_TYPE" => "application/json")
      end
      assert_response :unauthorized
    end
  end

  test "a stale timestamp bounces — replayed requests are dead requests" do
    with_secret do
      body = { type: "email.received", data: { email_id: "re_abc123" } }.to_json
      assert_no_enqueued_jobs do
        post "/webhooks/resend/inbound", params: body,
             headers: sign(body, timestamp: 1.hour.ago.to_i.to_s).merge("CONTENT_TYPE" => "application/json")
      end
      assert_response :unauthorized
    end
  end

  test "other event types are acknowledged and ignored" do
    with_secret do
      body = { type: "email.delivered", data: { email_id: "re_out1" } }.to_json
      assert_no_enqueued_jobs do
        post "/webhooks/resend/inbound", params: body,
             headers: sign(body).merge("CONTENT_TYPE" => "application/json")
      end
      assert_response :ok
    end
  end

  test "no configured secret means the door is closed, not open" do
    original = ENV["RESEND_WEBHOOK_SECRET"]
    ENV.delete("RESEND_WEBHOOK_SECRET")
    body = { type: "email.received", data: { email_id: "re_abc123" } }.to_json
    post "/webhooks/resend/inbound", params: body,
         headers: sign(body).merge("CONTENT_TYPE" => "application/json")
    assert_response :unauthorized
  ensure
    ENV["RESEND_WEBHOOK_SECRET"] = original if original
  end
end
