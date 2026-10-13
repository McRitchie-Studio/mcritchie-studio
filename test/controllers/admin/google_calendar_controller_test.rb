require "test_helper"
require "support/google_calendar_fakes"

# [integration] /admin/google_calendar: Connect sends the admin to Google, the
# callback stores the connection, the standing page reads the next week, and
# Disconnect deletes and revokes. Google is a stand-in throughout.
class Admin::GoogleCalendarControllerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarFakes

  setup { log_in_as users(:alex) }
  teardown { reset_google_calendar }

  def begin_connect
    get admin_google_calendar_connect_path
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  test "[integration] every action is admin only" do
    get logout_path
    get admin_google_calendar_connect_path
    assert_response :redirect
    assert_no_match(/accounts\.google\.com/, response.location)
    get admin_google_calendar_path
    assert_response :redirect
  end

  test "[integration] connect sends the admin to Google with this server's callback" do
    with_connect_env do
      query = begin_connect

      assert_match %r{\Ahttps://accounts\.google\.com/o/oauth2/v2/auth\?}, response.location
      assert_equal admin_google_calendar_callback_url, query["redirect_uri"]
      assert query["state"].present?
    end
  end

  test "[integration] connect without the OAuth client says so and asks Google nothing" do
    with_connect_env(creds: false) do
      get admin_google_calendar_connect_path

      assert_redirected_to admin_google_calendar_path
      assert_match(/GOOGLE_CONNECT_CLIENT_ID and GOOGLE_CONNECT_CLIENT_SECRET are not set/, flash[:alert])
    end
  end

  test "[integration] the callback stores the account and the page shows it, the week, and no token" do
    with_connect_env do
      state = begin_connect["state"]
      google_answers
      get admin_google_calendar_callback_path(code: "c0de", state:)

      assert_redirected_to admin_google_calendar_path
      assert_equal "Google Calendar connected for alex@mcritchie.studio.", flash[:notice]
      connection = GoogleCalendarConnection.current
      assert_equal "alex@mcritchie.studio", connection.email
      assert_includes connection.connected_by.to_s, "alex", "who connected it"

      GoogleCalendar::Reader.http = ->(_url, _token) { [ 200, { items: [ { id: "e1", summary: "Lender call", start: { dateTime: 1.day.from_now.iso8601 }, end: { dateTime: (1.day.from_now + 1.hour).iso8601 } } ] }.to_json ] }
      google_answers(200, { access_token: "ya29.page" })
      get admin_google_calendar_path

      assert_response :success
      assert_select "[data-test='google-calendar-connection'][data-source='connected']"
      assert_select "[data-field='account']", "alex@mcritchie.studio"
      assert_select "[data-test='google-calendar-event']", text: /Lender call/
      assert_no_match(/synthetic-refresh|ya29\./, response.body)
    end
  end

  test "[integration] a state mismatch is refused before any exchange" do
    with_connect_env do
      begin_connect
      google_answers
      get admin_google_calendar_callback_path(code: "c0de", state: "forged")

      assert_response :bad_request
      assert_empty google_requests
      assert_equal 0, GoogleCalendarConnection.count
    end
  end

  test "[integration] an unticked calendar permission is stored but called out" do
    with_connect_env do
      state = begin_connect["state"]
      google_answers(200, token_grant(scope: "openid email"))
      get admin_google_calendar_callback_path(code: "c0de", state:)

      assert_equal Admin::GoogleCalendarController::NO_CALENDAR, flash[:alert]
      get admin_google_calendar_path
      assert_select "[data-test='google-calendar-connection'][data-source='no_calendar']"
    end
  end

  test "[integration] a declined sign-in connects nothing" do
    with_connect_env do
      state = begin_connect["state"]
      get admin_google_calendar_callback_path(error: "access_denied", state:)

      assert_match(/declined/, flash[:alert])
      assert_equal 0, GoogleCalendarConnection.count
    end
  end

  test "[integration] a revoked connection says connect again on the standing page" do
    with_connect_env do
      GoogleCalendarConnection.store!(token_grant.transform_keys(&:to_s), email: "alex@mcritchie.studio", by: "alex")
      google_answers(400, { error: "invalid_grant" })
      get admin_google_calendar_path

      assert_select "[data-test='google-calendar-connection'][data-source='read_failed']"
      assert_select "[data-test='google-calendar-detail']", /revoked or went unused/
    end
  end

  test "[integration] disconnect deletes the row and revokes it at Google" do
    with_connect_env do
      GoogleCalendarConnection.store!(token_grant.transform_keys(&:to_s), email: "alex@mcritchie.studio", by: "alex")
      google_answers(200, {})
      delete admin_google_calendar_disconnect_path

      assert_redirected_to admin_google_calendar_path
      assert_equal 0, GoogleCalendarConnection.count
      assert_equal GoogleCalendar::OAuthClient::REVOKE_URL, google_requests.last[:url]
      assert_equal "Google Calendar disconnected: deleted here and revoked at Google.", flash[:notice]
    end
  end

  test "[integration] the auth code is filtered from the callback's logged parameters" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    logged = filter.filter("controller" => "admin/google_calendar", "action" => "callback", "code" => "synthetic-code", "state" => "s1")

    assert_equal "[FILTERED]", logged["code"]
    assert_equal "s1", logged["state"]
  end
end
