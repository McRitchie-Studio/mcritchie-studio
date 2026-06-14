require "test_helper"

module Studio
  class LocalEmailsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Studio.local_email_capture = true
    end

    teardown do
      Studio.local_email_capture = nil
    end

    test "shows recent local emails with magic-link proof URLs" do
      token = MagicLink.generate(email: users(:alex).email)
      Studio::Email.deliver(UserMailer, :magic_link, users(:alex).email, token, to: users(:alex).email)

      get studio_local_emails_path

      assert_response :success
      assert_includes response.body, "UserMailer#magic_link"
      assert_includes response.body, "/magic_link/"
      assert_includes response.body, "Capture enabled"
    end

    test "json includes action URLs for agents" do
      token = MagicLink.generate(email: users(:alex).email)
      Studio::Email.deliver(UserMailer, :magic_link, users(:alex).email, token, to: users(:alex).email)

      get studio_local_emails_path(format: :json)

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal true, body["capture_enabled"]
      assert_equal "UserMailer#magic_link", body["deliveries"].first["email_key"]
      assert_match %r{/magic_link/}, body["deliveries"].first["action_url"]
    end
  end
end
