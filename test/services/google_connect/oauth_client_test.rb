require "test_helper"
require "support/google_connect_fakes"

# [unit] GoogleConnect::OAuthClient: what each ability's sign-in asks Google
# for, the code exchange, the refresh and the revoke. Google is a stand-in
# throughout.
class GoogleConnect::OAuthClientTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  teardown { reset_google_connect }

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def connection = GoogleConnection.store!(token_grant.transform_keys(&:to_s), email: "alex@mcritchie.studio", user: users(:alex), abilities: [ :calendar ])

  test "[unit] each ability's sign-in asks for identity and its one read scope, offline, adding to past grants" do
    with_connect_env do
      GoogleConnection::ABILITIES.each do |ability, scope|
        url = URI(GoogleConnect::OAuthClient.authorize_url(redirect_uri: "https://hub.test/cb", state: "st", abilities: [ ability ]))
        query = Rack::Utils.parse_query(url.query)

        assert_equal "accounts.google.com", url.host
        assert_equal "test-connect-id", query["client_id"]
        assert_equal [ "openid", "email", scope ], query["scope"].split, ability
        assert_equal "true", query["include_granted_scopes"], "incremental consent keeps the other abilities"
        assert_equal "offline", query["access_type"]
        assert_equal "consent", query["prompt"]
        assert_equal "st", query["state"]
        assert_match(/readonly\z/, query["scope"].split.last, "never a write scope")
      end
    end
  end

  test "[unit] Connect Google's sign-in asks for identity and all three read scopes in one consent" do
    with_connect_env do
      url = URI(GoogleConnect::OAuthClient.authorize_url(redirect_uri: "https://hub.test/cb", state: "st", abilities: GoogleConnection::ABILITIES.keys))
      query = Rack::Utils.parse_query(url.query)

      assert_equal [ "openid", "email", CALENDAR, GMAIL, DRIVE ], query["scope"].split
      assert_equal "true", query["include_granted_scopes"]
    end
  end

  test "[unit] an unknown ability builds no sign-in" do
    with_connect_env do
      assert_raises(KeyError) { GoogleConnect::OAuthClient.authorize_url(redirect_uri: "https://hub.test/cb", state: "st", abilities: [ :contacts ]) }
    end
  end

  test "[unit] it refuses to build a sign-in without its own OAuth client" do
    with_connect_env(creds: false) do
      assert_raises(GoogleConnect::OAuthClient::NotConfigured) do
        GoogleConnect::OAuthClient.authorize_url(redirect_uri: "https://hub.test/cb", state: "st", abilities: [ :calendar ])
      end
    end
  end

  test "[unit] client_id is the public client id, nil when unset or blank" do
    with_connect_env { assert_equal "test-connect-id", GoogleConnect::OAuthClient.client_id }
    with_connect_env(creds: false) { assert_nil GoogleConnect::OAuthClient.client_id }
    with_connect_env do
      ENV["GOOGLE_CONNECT_CLIENT_ID"] = ""
      assert_nil GoogleConnect::OAuthClient.client_id
    end
  end

  test "[unit] the exchange posts the code with the connections client and returns Google's JSON" do
    with_connect_env do
      google_answers
      grant = GoogleConnect::OAuthClient.exchange_code(code: "c0de", redirect_uri: "https://hub.test/cb")

      assert_equal "1//synthetic-refresh", grant["refresh_token"]
      form = google_requests.last[:form]
      assert_equal "authorization_code", form[:grant_type]
      assert_equal "test-connect-secret", form[:client_secret]
      assert_equal "alex@mcritchie.studio", GoogleConnect::OAuthClient.email_from(grant)
    end
  end

  test "[unit] a refused refresh token raises Revoked, distinct from any other error" do
    with_connect_env do
      conn = connection
      google_answers(400, { error: "invalid_grant", error_description: "Token has been expired or revoked." })
      assert_raises(GoogleConnect::OAuthClient::Revoked) { GoogleConnect::OAuthClient.access_token(conn) }

      google_answers(500, { error: "internal_failure" })
      error = assert_raises(GoogleConnect::OAuthClient::Error) { GoogleConnect::OAuthClient.access_token(conn) }
      refute_kind_of GoogleConnect::OAuthClient::Revoked, error
    end
  end

  test "[unit] email_from is nil for a missing or malformed id_token" do
    assert_nil GoogleConnect::OAuthClient.email_from({})
    assert_nil GoogleConnect::OAuthClient.email_from({ "id_token" => "a.%%%.c" })
  end

  test "[unit] revoke posts the refresh token and reports Google's answer" do
    conn = connection
    google_answers(200, {})
    assert GoogleConnect::OAuthClient.revoke(conn)
    assert_equal GoogleConnect::OAuthClient::REVOKE_URL, google_requests.last[:url]

    google_answers(400, { error: "invalid_token" })
    refute GoogleConnect::OAuthClient.revoke(conn)
  end

  test "[unit] revoke rescues SSL/network errors: it logs the class and answers false, never raises" do
    conn = connection
    [ OpenSSL::SSL::SSLError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError ].each do |klass|
      GoogleConnect::OAuthClient.http = ->(_method, _url, _form) { raise klass, "synthetic" }
      logged = capture_log { assert_equal false, GoogleConnect::OAuthClient.revoke(conn), klass.name }
      assert_match(/revoke failed: GoogleConnect::OAuthClient::Error|revoke failed: #{klass}/, logged, klass.name)
      assert_no_match(/synthetic-refresh/, logged, "the token never reaches the log")
    end
  end
  # --- /tasks/google-connect-hardening-polish ---

  test "[unit] email_verified? is true only when Google's id_token says email_verified true" do
    verified = ->(claim) { GoogleConnect::OAuthClient.email_verified?({ "id_token" => id_token_for("a@b.test", verified: claim) }) }
    assert verified.(true)
    assert verified.("true"), "Google's older tokens carry the claim as a string"
    refute verified.(false)
    refute verified.("false")
    refute verified.(:absent), "no claim is not a verified email"
    refute GoogleConnect::OAuthClient.email_verified?({})
    refute GoogleConnect::OAuthClient.email_verified?({ "id_token" => "a.%%%.c" })
  end

  test "[unit] revoke_grant revokes a just-issued grant's refresh token and reports Google's answer" do
    google_answers(200, {})
    assert GoogleConnect::OAuthClient.revoke_grant({ "refresh_token" => "1//issued", "access_token" => "ya29.issued" })
    assert_equal GoogleConnect::OAuthClient::REVOKE_URL, google_requests.last[:url]
    assert_equal({ token: "1//issued" }, google_requests.last[:form])

    google_answers(400, { error: "invalid_token" })
    refute GoogleConnect::OAuthClient.revoke_grant({ "refresh_token" => "1//issued" })
  end

  test "[unit] revoke_grant falls back to the access token, and asks Google nothing for an empty grant" do
    google_answers(200, {})
    assert GoogleConnect::OAuthClient.revoke_grant({ "access_token" => "ya29.only" })
    assert_equal({ token: "ya29.only" }, google_requests.last[:form])

    google_requests.clear
    refute GoogleConnect::OAuthClient.revoke_grant({})
    refute GoogleConnect::OAuthClient.revoke_grant(nil)
    assert_empty google_requests
  end

  test "[unit] revoke_grant never raises: a network error logs its class and answers false" do
    GoogleConnect::OAuthClient.http = ->(_method, _url, _form) { raise Errno::ECONNREFUSED, "synthetic" }
    logged = capture_log { assert_equal false, GoogleConnect::OAuthClient.revoke_grant({ "refresh_token" => "1//issued-secret" }) }
    assert_match(/revoke failed/, logged)
    assert_no_match(/issued-secret/, logged, "the token never reaches the log")
  end
end
