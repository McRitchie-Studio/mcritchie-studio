require "test_helper"

# REQUESTING a magic link — POST /magic_link, the front door of the passwordless
# flow. That is all this controller does now.
#
# The token-bearing half used to live here too (GET/POST /magic_link/:token,
# against the stateless MessageVerifier store). This app has minted Studio::Link
# rows at /l/<token> for a while, so those tests were exercising a door no real
# visitor used — and studio-engine 0.30 removes it outright. The consume side is
# covered end to end, against the door this app actually serves, in
# test/integration/studio_link_test.rb.
class MagicLinksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { ActiveJob::Base.queue_adapter = :test }

  test "create records and enqueues a sign-in email for a well-formed address" do
    delivery = nil
    assert_enqueued_with(job: Studio::EmailDeliveryJob) do
      assert_difference "Studio::EmailDelivery.count", 1 do
        post magic_link_request_path, params: { email: "fresh@example.com" }
        delivery = Studio::EmailDelivery.recent.first
      end
    end
    assert_equal "UserMailer#magic_link", delivery.email_key
    assert_equal "fresh@example.com", delivery.to
    assert_redirected_to login_path
  end

  test "create sends nothing for a malformed address (no enumeration)" do
    assert_no_enqueued_jobs only: Studio::EmailDeliveryJob do
      assert_no_difference "Studio::EmailDelivery.count" do
        post magic_link_request_path, params: { email: "not-an-email" }
      end
    end
    assert_redirected_to login_path
  end
end
