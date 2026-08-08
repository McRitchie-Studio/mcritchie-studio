require "test_helper"

# End-to-end coverage of the unified /l/<token> link flow (Studio::Link), the
# [integration] tier for the engine's standard-link-model. mcritchie-studio runs
# with Studio.magic_link_store = :database, so magic-link sign-in goes through
# Studio::LinksController + /l, and referral links share the same entry point.
class StudioLinkTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  setup { ActiveJob::Base.queue_adapter = :test }

  # --- the harness itself ---------------------------------------------------

  # log_in_as is what the rest of the suite stands on, and it now rides /l. A
  # helper that silently stopped establishing a session would not fail loudly —
  # it would leave every authenticated test quietly asserting against a signed-
  # OUT app and still passing. So the helper gets its own assertion.
  test "log_in_as really establishes a session" do
    log_in_as(users(:alex))

    assert_equal users(:alex).id, session[Studio.session_key],
                 "the shared sign-in helper must leave a real session behind"
  end

  # --- magic link via /l ---------------------------------------------------

  test "request mints a short Studio::Link magic link (database store)" do
    assert_equal :database, Studio.magic_link_store
    assert_difference -> { Studio::Link.magic_links.count }, 1 do
      post magic_link_request_path, params: { email: "fresh@example.com" }
    end
    link = Studio::Link.magic_links.order(:created_at).last
    assert_equal "fresh@example.com", link.email
    assert_operator link.token.length, :<=, 24, "token should be short"
    assert_redirected_to login_path
  end

  test "GET /l/:token magic-link confirm is inert (no consume, no sign-in)" do
    link = Studio::Link.create_magic_link(email: users(:alex).email)
    get link_path(link.token)
    assert_response :success
    assert_select "form[action=?][method=post]", link_consume_path(token: link.token)
    assert_nil session[Studio.session_key]
    assert_nil link.reload.consumed_at
  end

  test "POST /l/:token consumes + signs in an existing user, honoring return_to" do
    link = Studio::Link.create_magic_link(email: users(:alex).email, return_to: "/")
    post link_consume_path(token: link.token)
    assert_redirected_to "/"
    assert_equal users(:alex).id, session[Studio.session_key]
    assert link.reload.consumed_at.present?
  end

  test "POST /l/:token for a brand-new email creates + verifies the account" do
    assert_difference "User.count", 1 do
      link = Studio::Link.create_magic_link(email: "brandnew-l@example.com")
      post link_consume_path(token: link.token)
    end
    user = User.find_by(email: "brandnew-l@example.com")
    assert user.email_verified_at.present?
    assert_equal user.id, session[Studio.session_key]
  end

  # Replayed from a FRESH session, deliberately. A replay by the visitor who
  # already consumed it is a different case with a different right answer —
  # engine 0.30 turns that one into a silent redirect, because bouncing a
  # signed-in visitor to the login page is what made a second click read as
  # being logged out. What must never work is a spent token letting a
  # STRANGER in, and that is what this pins.
  test "replay of a consumed magic link by a fresh visitor is rejected" do
    link = Studio::Link.create_magic_link(email: users(:alex).email)
    post link_consume_path(token: link.token)
    reset!

    post link_consume_path(token: link.token)

    assert_redirected_to login_path
    assert_match(/expired|already used/i, flash[:alert])
    assert_nil session[Studio.session_key]
  end

  test "consuming a magic link stores the solana address for sso awareness" do
    user = users(:alex)
    user.update!(solana_address: "Wa11etAddressBase58Example1111111111111111")

    post link_consume_path(token: Studio::Link.create_magic_link(email: user.email).token)

    assert_equal user.solana_address, session[:sso_wallet]
  end

  test "garbage token is friendly + inert on both verbs" do
    get link_path("garbage")
    assert_redirected_to login_path
    post link_consume_path(token: "garbage")
    assert_redirected_to login_path
  end

  # --- referral via /l -----------------------------------------------------

  test "GET /l/:token referral captures attribution + redirects to target (reusable)" do
    ref = Studio::Link.referral_for(users(:alex), target: "/")
    get link_path(ref.token)
    assert_redirected_to "/"
    assert cookies[:reference].present?, "referral should set the :reference attribution cookie"
    assert_nil ref.reload.consumed_at, "referral links are reusable, never burned"
    assert_nil session[Studio.session_key], "a referral click must not sign anyone in"
  end

  test "referral_for is stable per target and distinct across targets" do
    a1 = Studio::Link.referral_for(users(:alex), target: "/contests/a")
    a2 = Studio::Link.referral_for(users(:alex), target: "/contests/a")
    b  = Studio::Link.referral_for(users(:alex), target: "/contests/b")
    assert_equal a1.token, a2.token, "same (user, target) reuses one link"
    refute_equal a1.token, b.token, "different targets get distinct links"
  end

  test "an expired magic link is rejected on consume" do
    link = Studio::Link.create_magic_link(email: users(:alex).email)
    travel(Studio.magic_link_ttl + 1.minute) do
      post link_consume_path(token: link.token)
    end
    assert_redirected_to login_path
    assert_match(/expired/i, flash[:alert])
    assert_nil session[Studio.session_key]
  end
end
