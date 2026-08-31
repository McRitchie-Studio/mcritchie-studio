require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # Two methods, not three: :wallet was dropped from config.auth_methods, which
  # removes the engine's Solana routes outright. The wallet CTA is refuted here
  # so the picker cannot creep back in without the routes behind it.
  test "signin page renders both auth methods and no wallet CTA" do
    get signin_path
    assert_response :success
    assert_select "form[action=?]", "/auth/google_oauth2"          # Google (button_to)
    assert_match "Email Link", response.body                       # magic-link email
    refute_match "wallet-connect", response.body                   # wallet picker dropped
    assert_select "input[type=password]", false                    # passwordless: no password field
  end

  test "legacy /login redirects to unified /signin" do
    get login_path
    assert_redirected_to "/signin"
  end

  test "magic-link login signs an existing user in" do
    log_in_as users(:alex)
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  test "logout clears session" do
    log_in_as users(:alex)
    get logout_path
    assert_redirected_to login_path
  end
end
