require "test_helper"
require "support/google_connect_fakes"

# [integration] /integrations/google: any signed-in user connects, sees and
# disconnects their OWN Google account (/tasks/every-user-connects-google).
# Connect goes to Google with the one registered callback; the callback
# stores the row as theirs and comes back to /integrations; Disconnect reaches
# only their rows; an account another user connected is refused; and the
# agent reader (GoogleConnection.for) never answers a non-admin's row.
# Google is a stand-in throughout.
class Integrations::GoogleControllerTest < ActionDispatch::IntegrationTest
  include GoogleConnectFakes

  ALL_SCOPES = "openid email #{CALENDAR} #{GMAIL} #{DRIVE}".freeze

  setup { log_in_as users(:viewer) }
  teardown { reset_google_connect }

  def viewer = users(:viewer)

  # Starts a connect from the integrations door; returns Google's authorize query.
  def begin_connect(ability = "calendar", return_to: "/integrations")
    get integrations_google_connect_path(ability:, return_to:)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  # Connects all the way as `email`: Google grants `scope`.
  def connect!(ability = "calendar", email: "viewer@gmail.test", scope: "openid email #{CALENDAR}", return_to: "/integrations")
    state = begin_connect(ability, return_to:)["state"]
    google_answers(200, token_grant(email:, scope:, refresh_token: "1//viewer-synthetic"))
    get admin_google_callback_path(code: "c0de", state:)
  end

  test "[integration] a non-admin connects their own account through the one registered callback" do
    with_connect_env do
      query = begin_connect("calendar")
      assert_match %r{\Ahttps://accounts\.google\.com/o/oauth2/v2/auth\?}, response.location
      assert_equal admin_google_callback_url, query["redirect_uri"], "the redirect URI the console already registered"
      assert_equal [ "openid", "email", CALENDAR ], query["scope"].split, "read-only, as for an admin"

      google_answers(200, token_grant(email: "viewer@gmail.test", scope: "openid email #{CALENDAR}"))
      get admin_google_callback_path(code: "c0de", state: query["state"])

      assert_redirected_to "/integrations"
      assert_equal "Google Calendar connected for viewer@gmail.test.", flash[:notice]
      row = GoogleConnection.sole
      assert_equal viewer, row.user
      assert_equal [ :calendar ], row.abilities
    end
  end

  test "[integration] Connect Google asks a non-admin for all three and stores what was granted" do
    with_connect_env do
      connect!(GoogleConnection::ALL, scope: ALL_SCOPES)

      assert_redirected_to "/integrations"
      assert_equal %i[calendar gmail drive], viewer.google_connections.sole.abilities
    end
  end

  test "[integration] the agent reader ignores a non-admin's connection, even the newest" do
    store_google(scope: "openid #{CALENDAR}", now: 1.day.ago) # the household's, owned by the admin
    household = GoogleConnection.sole
    with_connect_env do
      connect!("calendar")
      assert_equal 2, GoogleConnection.count # the control: the viewer's newer row landed

      assert_equal household, GoogleConnection.for(:calendar)
      assert_nil GoogleConnection.for(:drive)
    end
  end

  test "[integration] a non-admin's return_to is /integrations only: never the admin page, never off-site" do
    with_connect_env do
      [ "/admin/google", "https://evil.example/", "//evil.example" ].each do |return_to|
        connect!(return_to:)
        assert_redirected_to "/integrations", return_to
      end
    end
  end

  test "[integration] signing in an account another user connected is refused, with no takeover" do
    store_google(email: "alex@mcritchie.studio", scope: "openid #{CALENDAR}", refresh_token: "1//household")
    with_connect_env do
      connect!("calendar", email: "alex@mcritchie.studio")

      assert_redirected_to "/integrations"
      assert_equal "That Google account is already connected by another user.", flash[:alert]
      row = GoogleConnection.sole
      assert_equal users(:alex), row.user
      assert_equal "1//household", row.refresh_token
    end
  end

  test "[integration] the same non-admin signing in again adds abilities to their own row" do
    with_connect_env do
      connect!("calendar")
      connect!("drive", scope: "openid email #{DRIVE}")

      assert_equal %i[calendar drive], viewer.google_connections.sole.abilities
    end
  end

  test "[integration] a non-admin's disconnect drops only their own rows; the household's stay" do
    store_google(scope: "openid #{CALENDAR}") # the household's
    store_google(email: "viewer@gmail.test", scope: "openid #{CALENDAR}", user: viewer)
    google_answers(200, {})

    delete integrations_google_disconnect_path(ability: "calendar", return_to: "/integrations")

    assert_redirected_to "/integrations"
    assert_equal "Google Calendar disconnected: deleted here and revoked at Google.", flash[:notice]
    assert_empty viewer.google_connections.reload
    assert_equal [ "alex@mcritchie.studio" ], GoogleConnection.pluck(:email)
    assert_equal 1, google_requests.size, "one revoke, the viewer's"
  end

  test "[integration] a non-admin cannot disconnect another user's connection" do
    other = User.create!(email: "other@example.com", name: "Other Viewer", role: "viewer")
    store_google(email: "other@gmail.test", scope: "openid #{CALENDAR}", user: other)
    google_answers(200, {})

    delete integrations_google_disconnect_path(ability: "calendar", return_to: "/integrations")

    assert_redirected_to "/integrations"
    assert_equal "Google Calendar was not connected, so nothing changed.", flash[:notice]
    assert_equal [ "other@gmail.test" ], GoogleConnection.pluck(:email)
    assert_empty google_requests, "Google was asked to revoke nothing"
  end

  test "[integration] an admin's household disconnect leaves a non-admin's connection alone" do
    store_google(scope: "openid #{CALENDAR}")
    store_google(email: "viewer@gmail.test", scope: "openid #{CALENDAR}", user: viewer)
    google_answers(200, {})
    log_in_as users(:alex)

    delete admin_google_disconnect_path(ability: "calendar")

    assert_equal [ "viewer@gmail.test" ], GoogleConnection.pluck(:email)
  end

  test "[integration] a non-admin still cannot open the admin household page or its connect" do
    get admin_google_path
    assert_redirected_to root_path
    get admin_google_connect_path(ability: "calendar")
    assert_redirected_to root_path
    delete admin_google_disconnect_path(ability: "calendar")
    assert_redirected_to root_path
  end

  test "[integration] a non-admin's callback with no connect in the session is refused before any exchange" do
    google_answers(200, token_grant(email: "viewer@gmail.test"))
    with_connect_env do
      get admin_google_callback_path(code: "c0de", state: "forged")
    end
    assert_response :bad_request
    assert_empty google_requests
    assert_equal 0, GoogleConnection.count
  end

  test "[integration] a visitor is sent to sign in, and Google is never asked" do
    get logout_path
    get integrations_google_connect_path(ability: "calendar")
    assert_redirected_to login_path
    get admin_google_callback_path(code: "c0de", state: "x")
    assert_redirected_to login_path
    delete integrations_google_disconnect_path(ability: "calendar")
    assert_response :redirect
    assert_no_match(/accounts\.google\.com/, response.location)
  end
  # --- /tasks/google-connect-hardening-polish: the callback's four guards ---
  # Google's revoke drops the whole grant (every token the account gave this
  # OAuth client), so a refused sign-in revokes its token only when no stored
  # connection holds that account's grant: revoking then would cut the
  # connection someone already has.

  def revokes = google_requests.select { _1[:url] == GoogleConnect::OAuthClient::REVOKE_URL }

  # Connects as `email` with Google answering `grant` to the exchange and 200 to the revoke.
  def connect_with!(grant, ability = "calendar")
    state = begin_connect(ability)["state"]
    google_answers(200, grant)
    get admin_google_callback_path(code: "c0de", state:)
  end

  test "[unit] GoogleSignIn: a sign-in refused for an unverified email stores nothing and revokes the issued token" do
    with_connect_env do
      connect_with!(token_grant(email: "unverified@gmail.test", scope: "openid email #{CALENDAR}", refresh_token: "1//issued", verified: false))

      assert_redirected_to "/integrations"
      assert_equal "Google has not verified unverified@gmail.test, so it was not connected. Verify the address with Google, then connect again.", flash[:alert]
      assert_equal 0, GoogleConnection.count
      assert_equal [ { token: "1//issued" } ], revokes.map { _1[:form] }, "the just-issued token is revoked, not left live"
    end
  end

  test "[unit] GoogleSignIn: an id_token with no email_verified claim is refused too" do
    with_connect_env do
      connect_with!(token_grant(email: "silent@gmail.test", scope: "openid email #{CALENDAR}", verified: :absent))

      assert_match(/not verified/, flash[:alert])
      assert_equal 0, GoogleConnection.count
      assert_equal 1, revokes.size
    end
  end

  test "[unit] GoogleSignIn: a verified email connects and revokes nothing (the control)" do
    with_connect_env do
      connect_with!(token_grant(email: "viewer@gmail.test", scope: "openid email #{CALENDAR}"))

      assert_equal "Google Calendar connected for viewer@gmail.test.", flash[:notice]
      assert_equal 1, GoogleConnection.count
      assert_empty revokes
    end
  end

  test "[unit] GoogleSignIn: a sign-in granting nothing revokes the token it was issued" do
    with_connect_env do
      connect_with!(token_grant(email: "viewer@gmail.test", scope: "openid email", refresh_token: "1//issued"))

      assert_match(/did not grant Google Calendar/, flash[:alert])
      assert_equal 0, GoogleConnection.count
      assert_equal [ { token: "1//issued" } ], revokes.map { _1[:form] }
    end
  end

  test "[unit] GoogleSignIn: granting nothing on an account already connected keeps that connection's grant" do
    store_google(email: "viewer@gmail.test", scope: "openid #{CALENDAR}", user: viewer, refresh_token: "1//kept")
    with_connect_env do
      connect_with!(token_grant(email: "viewer@gmail.test", scope: "openid email", refresh_token: "1//issued"), "drive")

      assert_match(/did not grant Google Drive/, flash[:alert])
      assert_empty revokes, "a revoke would cut the Calendar connection this account already has"
      assert_equal "1//kept", GoogleConnection.sole.refresh_token
    end
  end

  test "[unit] GoogleSignIn: an account another user connected is refused without revoking that user's grant" do
    store_google(email: "alex@mcritchie.studio", scope: "openid #{CALENDAR}", refresh_token: "1//household")
    with_connect_env do
      connect_with!(token_grant(email: "alex@mcritchie.studio", scope: "openid email #{CALENDAR}", refresh_token: "1//issued"))

      assert_equal "That Google account is already connected by another user.", flash[:alert]
      assert_empty revokes, "Google revokes per grant: revoking would disconnect the household"
      assert_equal "1//household", GoogleConnection.sole.refresh_token
    end
  end

  test "[unit] GoogleSignIn: the race's unique-row collision resolves to one row and a friendly message, not a 500" do
    with_connect_env do
      state = begin_connect("calendar")["state"]
      google_answers(200, token_grant(email: "viewer@gmail.test", scope: "openid email #{CALENDAR}", refresh_token: "1//issued"))
      collide = lambda do |*, **|
        store_google(email: "viewer@gmail.test", scope: "openid #{CALENDAR}", user: viewer, refresh_token: "1//winner")
        raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
      end
      GoogleConnection.stub(:store!, collide) { get admin_google_callback_path(code: "c0de", state:) }

      assert_redirected_to "/integrations"
      assert_equal "viewer@gmail.test was connecting in another tab at the same moment. It is connected once; nothing else changed.", flash[:alert]
      assert_equal "1//winner", GoogleConnection.sole.refresh_token
      assert_empty revokes, "the row that won holds this grant"
    end
  end

  test "[unit] GoogleSignIn: the OAuth state is bound to the user who pressed Connect" do
    other = User.create!(email: "other@example.com", name: "Other Viewer", role: "viewer")
    with_connect_env do
      state = begin_connect("calendar")["state"]
      log_in_as other # a different user signs in on the same browser mid-flow
      google_answers(200, token_grant(email: "viewer@gmail.test", scope: "openid email #{CALENDAR}", refresh_token: "1//issued"))
      get admin_google_callback_path(code: "c0de", state:)

      assert_redirected_to "/integrations"
      assert_equal "This Google sign-in was started by someone else signed in on this browser, so nothing was connected. Press Connect again.", flash[:alert]
      assert_equal 0, GoogleConnection.count
      assert_empty other.google_connections
      assert_equal [ { token: "1//issued" } ], revokes.map { _1[:form] }, "the grant the other person's consent issued is revoked"
    end
  end

  test "[unit] GoogleSignIn: the same user returning completes the bound sign-in (the control)" do
    with_connect_env do
      state = begin_connect("calendar")["state"]
      log_in_as viewer # signing in again as the same person keeps the binding
      google_answers(200, token_grant(email: "viewer@gmail.test", scope: "openid email #{CALENDAR}"))
      get admin_google_callback_path(code: "c0de", state:)

      assert_equal "Google Calendar connected for viewer@gmail.test.", flash[:notice]
      assert_equal viewer, GoogleConnection.sole.user
    end
  end
end
