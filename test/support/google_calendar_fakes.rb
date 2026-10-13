# Stand-ins for Google's token, revoke and events endpoints, for tests of the
# Google Calendar connection. No test here reaches Google.
module GoogleCalendarFakes
  CREDS = { "GOOGLE_CONNECT_CLIENT_ID" => "test-connect-id", "GOOGLE_CONNECT_CLIENT_SECRET" => "test-connect-secret" }.freeze
  SCOPE = "openid https://www.googleapis.com/auth/userinfo.email #{GoogleCalendar::OAuthClient::CALENDAR_SCOPE}".freeze

  def with_connect_env(creds: true)
    originals = CREDS.keys.index_with { |k| ENV[k] }
    CREDS.each { |k, v| creds ? ENV[k] = v : ENV.delete(k) }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # An id_token whose payload names `email` (Google signs it; nothing here checks).
  def id_token_for(email) = "h.#{Base64.urlsafe_encode64({ email: }.to_json, padding: false)}.s"

  def token_grant(email: "alex@mcritchie.studio", scope: SCOPE, refresh_token: "1//synthetic-refresh")
    { access_token: "ya29.synthetic", refresh_token:, scope:, id_token: id_token_for(email), token_type: "Bearer" }
  end

  # Answers every POST with `answer` ([status, body Hash]) and records it.
  def google_answers(status = 200, body = token_grant)
    google_requests.clear
    GoogleCalendar::OAuthClient.http = lambda do |method, url, form|
      google_requests << { method:, url:, form: }
      [ status, JSON.generate(body) ]
    end
  end

  def google_requests = (@google_requests ||= [])

  def reset_google_calendar
    GoogleCalendar::OAuthClient.http = nil
    GoogleCalendar::OAuthClient.sign_in_stand_in = nil
    GoogleCalendar::Reader.http = nil
  end
end
