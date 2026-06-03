require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { ActiveJob::Base.queue_adapter = :test }

  test "signup page redirects to the unified signin and renders" do
    get signup_path
    assert_redirected_to "/signin"
    follow_redirect!
    assert_response :success
    assert_match "Email Link", response.body
  end

  # Passwordless: a signup POST does NOT create-and-log-in by form (that would
  # skip proof of email ownership). It sends a magic link; the create-or-login
  # happens only when the recipient clicks it.
  test "signup sends a magic link without creating an account" do
    assert_no_difference "User.count" do
      assert_enqueued_emails 1 do
        post signup_path, params: { user: { name: "New User", email: "new@example.com" } }
      end
    end
    assert_redirected_to login_path
  end

  test "signup with a malformed email sends nothing" do
    assert_no_enqueued_emails do
      post signup_path, params: { user: { email: "nope" } }
    end
    assert_redirected_to login_path
  end
end
