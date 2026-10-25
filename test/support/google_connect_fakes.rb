# Stand-ins for Google's token, revoke and read endpoints, for tests of the
# Google connection (GoogleConnection, GoogleConnect::*). No test here reaches Google.
module GoogleConnectFakes
  CREDS = { "GOOGLE_CONNECT_CLIENT_ID" => "test-connect-id", "GOOGLE_CONNECT_CLIENT_SECRET" => "test-connect-secret" }.freeze
  CALENDAR = GoogleConnection::ABILITIES[:calendar]
  GMAIL = GoogleConnection::ABILITIES[:gmail]
  DRIVE = GoogleConnection::ABILITIES[:drive]
  # What Google writes in `scope` for a calendar sign-in (it spells email out).
  SCOPE = "openid https://www.googleapis.com/auth/userinfo.email #{CALENDAR}".freeze

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

  # A stored connection granting `scope` (the calendar sign-in's by default), as a
  # sign-in that asked for `abilities` (all of them by default) stores it, owned
  # by `user` (the admin, so the household's, by default).
  def store_google(email: "alex@mcritchie.studio", scope: SCOPE, refresh_token: "1//synthetic-refresh", abilities: GoogleConnection::ABILITIES.keys,
                   user: users(:alex), now: Time.current)
    GoogleConnection.store!(token_grant(email:, scope:, refresh_token:).transform_keys(&:to_s), email:, user:, abilities:, now:)
  end

  # Answers every POST with `answer` ([status, body Hash]) and records it.
  def google_answers(status = 200, body = token_grant)
    google_requests.clear
    GoogleConnect::OAuthClient.http = lambda do |method, url, form|
      google_requests << { method:, url:, form: }
      [ status, JSON.generate(body) ]
    end
  end

  def google_requests = (@google_requests ||= [])

  # Answers every read GET by the first matching URL prefix in `routes`
  # ({ prefix => [status, body Hash] }), and records each URL and token.
  def google_reads(routes)
    read_requests.clear
    GoogleConnect::Reader.http = lambda do |url, token|
      read_requests << [ url, token ]
      status, body = routes.find { |prefix, _| url.start_with?(prefix) }&.last || [ 404, { error: { message: "unrouted" } } ]
      [ status, JSON.generate(body) ]
    end
  end

  def read_requests = (@read_requests ||= [])

  def reset_google_connect
    GoogleConnect::OAuthClient.http = nil
    GoogleConnect::OAuthClient.sign_in_stand_in = nil
    GoogleConnect::Reader.http = nil
  end
end
