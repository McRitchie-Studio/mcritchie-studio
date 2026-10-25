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
end
