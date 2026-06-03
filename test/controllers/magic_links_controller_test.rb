require "test_helper"

class MagicLinksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { ActiveJob::Base.queue_adapter = :test }

  test "create enqueues a sign-in email for a well-formed address" do
    assert_enqueued_emails 1 do
      post magic_link_request_path, params: { email: "fresh@example.com" }
    end
    assert_redirected_to login_path
  end

  test "create sends nothing for a malformed address (no enumeration)" do
    assert_no_enqueued_emails do
      post magic_link_request_path, params: { email: "not-an-email" }
    end
    assert_redirected_to login_path
  end

  test "consuming a valid token signs an existing user in" do
    token = MagicLink.generate(email: users(:alex).email)
    get magic_link_path(token)
    assert_redirected_to root_path
  end

  test "consuming a valid token for a new email creates the account" do
    assert_difference "User.count", 1 do
      token = MagicLink.generate(email: "brandnew@example.com")
      get magic_link_path(token)
    end
    assert User.find_by(email: "brandnew@example.com").email_verified_at.present?
  end

  test "an invalid token is rejected" do
    get magic_link_path("garbage")
    assert_redirected_to login_path
    assert_match(/invalid or has expired/i, flash[:alert])
  end
end
