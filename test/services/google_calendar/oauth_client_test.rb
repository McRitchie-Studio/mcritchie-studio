require "test_helper"
require "support/google_calendar_fakes"

# [unit] GoogleCalendar::OAuthClient and Reader: what the sign-in asks Google
# for, the code exchange, the refresh, the revoke, and the events read. Google
# is a stand-in throughout.
class GoogleCalendar::OAuthClientTest < ActiveSupport::TestCase
  include GoogleCalendarFakes

  teardown { reset_google_calendar }

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def connection = GoogleCalendarConnection.store!(token_grant.transform_keys(&:to_s), email: "alex@mcritchie.studio", by: "alex")

  test "[unit] the sign-in asks for offline access to read events, identity, and nothing else" do
    with_connect_env do
      url = URI(GoogleCalendar::OAuthClient.authorize_url(redirect_uri: "https://hub.test/cb", state: "st"))
      query = Rack::Utils.parse_query(url.query)

      assert_equal "accounts.google.com", url.host
      assert_equal "test-connect-id", query["client_id"]
      assert_equal [ "openid", "email", "https://www.googleapis.com/auth/calendar.events.readonly" ], query["scope"].split
      assert_equal "offline", query["access_type"]
      assert_equal "consent", query["prompt"]
      assert_equal "st", query["state"]
      assert_no_match(/calendar(\.readonly)?\z|calendar\.events\z/, query["scope"].split.last, "never a write or the wider read scope")
    end
  end

  test "[unit] it refuses to build a sign-in without its own OAuth client" do
    with_connect_env(creds: false) do
      assert_raises(GoogleCalendar::OAuthClient::NotConfigured) do
        GoogleCalendar::OAuthClient.authorize_url(redirect_uri: "https://hub.test/cb", state: "st")
      end
    end
  end

  test "[unit] the exchange posts the code with the connections client and returns Google's JSON" do
    with_connect_env do
      google_answers
      grant = GoogleCalendar::OAuthClient.exchange_code(code: "c0de", redirect_uri: "https://hub.test/cb")

      assert_equal "1//synthetic-refresh", grant["refresh_token"]
      form = google_requests.last[:form]
      assert_equal "authorization_code", form[:grant_type]
      assert_equal "test-connect-secret", form[:client_secret]
      assert_equal "alex@mcritchie.studio", GoogleCalendar::OAuthClient.email_from(grant)
    end
  end

  test "[unit] a refused refresh token raises Revoked, distinct from any other error" do
    with_connect_env do
      conn = connection
      google_answers(400, { error: "invalid_grant", error_description: "Token has been expired or revoked." })
      assert_raises(GoogleCalendar::OAuthClient::Revoked) { GoogleCalendar::OAuthClient.access_token(conn) }

      google_answers(500, { error: "internal_failure" })
      error = assert_raises(GoogleCalendar::OAuthClient::Error) { GoogleCalendar::OAuthClient.access_token(conn) }
      refute_kind_of GoogleCalendar::OAuthClient::Revoked, error
    end
  end

  test "[unit] email_from is nil for a missing or malformed id_token" do
    assert_nil GoogleCalendar::OAuthClient.email_from({})
    assert_nil GoogleCalendar::OAuthClient.email_from({ "id_token" => "a.%%%.c" })
  end

  test "[unit] revoke posts the refresh token and reports Google's answer" do
    conn = connection
    google_answers(200, {})
    assert GoogleCalendar::OAuthClient.revoke(conn)
    assert_equal GoogleCalendar::OAuthClient::REVOKE_URL, google_requests.last[:url]

    google_answers(400, { error: "invalid_token" })
    refute GoogleCalendar::OAuthClient.revoke(conn)
  end

  test "[unit] revoke rescues SSL/network errors: it logs the class and answers false, never raises" do
    conn = connection
    [ OpenSSL::SSL::SSLError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError ].each do |klass|
      GoogleCalendar::OAuthClient.http = ->(_method, _url, _form) { raise klass, "synthetic" }
      logged = capture_log { assert_equal false, GoogleCalendar::OAuthClient.revoke(conn), klass.name }
      assert_match(/revoke failed: GoogleCalendar::OAuthClient::Error|revoke failed: #{klass}/, logged, klass.name)
      assert_no_match(/synthetic-refresh/, logged, "the token never reaches the log")
    end
  end

  test "[unit] the reader GETs the primary calendar with a bearer token and maps events" do
    with_connect_env do
      conn = connection
      google_answers(200, { access_token: "ya29.fresh" })
      seen = []
      GoogleCalendar::Reader.http = lambda do |url, token|
        seen << [ url, token ]
        [ 200, { items: [
          { id: "e1", summary: "Lender call", start: { dateTime: "2026-10-14T15:00:00Z" }, end: { dateTime: "2026-10-14T16:00:00Z" },
            attendees: [ {}, {} ], hangoutLink: "https://meet.google.com/x" },
          { id: "e2", start: { date: "2026-10-15" }, end: { date: "2026-10-16" } }
        ] }.to_json ]
      end

      events = GoogleCalendar::Reader.new(conn).events(from: Time.utc(2026, 10, 14), to: Time.utc(2026, 10, 21))

      assert_equal "ya29.fresh", seen.last[1]
      query = Rack::Utils.parse_query(URI(seen.last[0]).query)
      assert_equal "true", query["singleEvents"]
      assert_equal "2026-10-14T00:00:00Z", query["timeMin"]
      assert_equal [ "Lender call", "(no title)" ], events.map(&:title)
      assert_equal 2, events.first.attendees
      refute events.first.all_day
      assert events.last.all_day
    end
  end

  test "[unit] a refused events read raises with Google's message" do
    with_connect_env do
      conn = connection
      google_answers(200, { access_token: "ya29.fresh" })
      GoogleCalendar::Reader.http = ->(_url, _token) { [ 403, { error: { message: "Insufficient Permission" } }.to_json ] }

      error = assert_raises(GoogleCalendar::OAuthClient::Error) { GoogleCalendar::Reader.new(conn).events }
      assert_match(/403: Insufficient Permission/, error.message)
    end
  end
end
