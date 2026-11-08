require "test_helper"
require "support/egnyte_connect_fakes"

# [unit] Egnyte::OAuthClient: the per-domain authorize URL, the code exchange
# and refresh on that domain's token endpoint, the cached 30-day access token
# (refreshed only near expiry or after a 401), the rotated pair stored before
# use, and revoke. Egnyte is a stand-in at the HTTP layer throughout.
class Egnyte::OAuthClientTest < ActiveSupport::TestCase
  include EgnyteConnectFakes

  NOW = Time.utc(2026, 11, 6, 18, 0, 0)
  REDIRECT = "https://hub.test/admin/egnyte/callback".freeze

  teardown { reset_egnyte_connect }

  def token_url = "https://example.egnyte.com/puboauth/token"

  test "[unit] the authorize URL is the domain's own puboauth path, asking for the code flow and the filesystem scope" do
    with_egnyte_env do
      url = URI(Egnyte::OAuthClient.authorize_url(domain: "Example.egnyte.com", redirect_uri: REDIRECT, state: "s1"))

      assert_equal [ "https", "example.egnyte.com", "/puboauth/token" ], [ url.scheme, url.host, url.path ]
      assert_equal({ "client_id" => "test-egnyte-id", "redirect_uri" => REDIRECT, "scope" => "Egnyte.filesystem",
                     "state" => "s1", "response_type" => "code" }, Rack::Utils.parse_query(url.query))
    end
  end

  test "[unit] a domain that is not one never reaches a URL" do
    with_egnyte_env do
      [ "evil.com/", "a.b", "" ].each do |domain|
        assert_raises(ArgumentError, domain) { Egnyte::OAuthClient.authorize_url(domain:, redirect_uri: REDIRECT, state: "s") }
      end
    end
  end

  test "[unit] without the developer key nothing is asked of Egnyte" do
    with_egnyte_env(creds: false) do
      assert_not Egnyte::OAuthClient.configured?
      assert_not Egnyte::OAuthClient.connectable?
      assert_raises(Egnyte::OAuthClient::NotConfigured) { Egnyte::OAuthClient.authorize_url(domain: "example", redirect_uri: REDIRECT, state: "s") }
      assert_raises(Egnyte::OAuthClient::NotConfigured) { Egnyte::OAuthClient.exchange_code(domain: "example", code: "c", redirect_uri: REDIRECT) }
    end
  end

  test "[unit] the code exchange posts the documented form to the domain's token endpoint" do
    with_egnyte_env do
      egnyte_tokens([ 200, egnyte_grant(access_token: "a1", refresh_token: "r1") ])
      grant = Egnyte::OAuthClient.exchange_code(domain: "example", code: "c0de", redirect_uri: REDIRECT)

      assert_equal "a1", grant["access_token"]
      request = egnyte_token_requests.sole
      assert_equal token_url, request[:url]
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: REDIRECT, scope: "Egnyte.filesystem",
                     client_id: "test-egnyte-id", client_secret: "test-egnyte-secret" }, request[:form])
    end
  end

  test "[unit] a refused exchange says Egnyte's reason; a throttle says so" do
    with_egnyte_env do
      egnyte_tokens([ 400, { error: "invalid_request", error_description: "redirect_uri mismatch" } ])
      error = assert_raises(Egnyte::OAuthClient::Error) { Egnyte::OAuthClient.exchange_code(domain: "example", code: "c", redirect_uri: REDIRECT) }
      assert_equal "Egnyte answered 400: redirect_uri mismatch", error.message

      egnyte_tokens([ 409, "" ])
      assert_raises(Egnyte::OAuthClient::RateLimited) { Egnyte::OAuthClient.exchange_code(domain: "example", code: "c", redirect_uri: REDIRECT) }
    end
  end

  test "[unit] a fresh stored access token is used as is: no refresh is spent" do
    with_egnyte_env do
      connection = store_egnyte(access_token: "a1", now: NOW)
      egnyte_tokens

      assert_equal "a1", Egnyte::OAuthClient.access_token(connection, now: NOW + 20.days)
      assert_empty egnyte_token_requests
    end
  end

  test "[unit] near expiry it refreshes on the domain and stores the rotated pair before handing back the token" do
    with_egnyte_env do
      connection = store_egnyte(access_token: "a1", refresh_token: "r1", now: NOW)
      egnyte_tokens([ 200, egnyte_grant(access_token: "a2", refresh_token: "r2") ])

      assert_equal "a2", Egnyte::OAuthClient.access_token(connection, now: NOW + 29.5.days)
      assert_equal({ grant_type: "refresh_token", refresh_token: "r1", client_id: "test-egnyte-id", client_secret: "test-egnyte-secret" },
                   egnyte_token_requests.sole[:form])
      assert_equal token_url, egnyte_token_requests.sole[:url]
      stored = EgnyteConnection.find(connection.id)
      assert_equal [ "a2", "r2", NOW + 59.5.days ], [ stored.access_token, stored.refresh_token, stored.access_expires_at ]
    end
  end

  test "[unit] a 401's stale token is refreshed once; a token another caller already replaced is not" do
    with_egnyte_env do
      connection = store_egnyte(access_token: "a1", refresh_token: "r1", now: NOW)
      egnyte_tokens([ 200, egnyte_grant(access_token: "a2", refresh_token: "r2") ])

      assert_equal "a2", Egnyte::OAuthClient.access_token(connection, stale: "a1", now: NOW + 1.day)
      assert_equal 1, egnyte_token_requests.size
      assert_equal "a2", Egnyte::OAuthClient.access_token(connection, stale: "a1", now: NOW + 1.day), "a1 is already replaced: no second refresh"
      assert_equal 1, egnyte_token_requests.size
    end
  end

  test "[unit] a refused refresh raises Revoked and keeps the stored pair" do
    with_egnyte_env do
      connection = store_egnyte(access_token: "a1", refresh_token: "r1", now: NOW)
      egnyte_tokens([ 400, { message: "Invalid Refresh Token" } ])

      assert_raises(Egnyte::OAuthClient::Revoked) { Egnyte::OAuthClient.access_token(connection, now: NOW + 30.days) }
      assert_equal [ "a1", "r1" ], EgnyteConnection.find(connection.id).then { [ _1.access_token, _1.refresh_token ] }
    end
  end

  test "[unit] a refused token with no refresh token raises Revoked without asking Egnyte" do
    with_egnyte_env do
      connection = store_egnyte(access_token: "a1", refresh_token: nil, expires_in: -1, now: NOW)
      egnyte_tokens

      assert_raises(Egnyte::OAuthClient::Revoked) { Egnyte::OAuthClient.access_token(connection, stale: "a1") }
      assert_empty egnyte_token_requests
    end
  end

  test "[unit] an unreachable Egnyte is said, not raised raw" do
    with_egnyte_env do
      Net::HTTP.stub(:start, ->(*, **) { raise SocketError, "getaddrinfo" }) do
        error = assert_raises(Egnyte::OAuthClient::Error) { Egnyte::OAuthClient.exchange_code(domain: "example", code: "c", redirect_uri: REDIRECT) }
        assert_equal "Egnyte could not be reached: SocketError", error.message
      end
    end
  end

  test "[unit] revoke posts the refresh token and the secret to the domain's revoke endpoint" do
    with_egnyte_env do
      connection = store_egnyte(access_token: "a1", refresh_token: "r1", now: NOW)
      egnyte_tokens([ 200, "" ])

      assert Egnyte::OAuthClient.revoke(connection)
      assert_equal "https://example.egnyte.com/pubapi/v1/tokens/revoke", egnyte_token_requests.sole[:url]
      assert_equal({ token: "r1", client_secret: "test-egnyte-secret" }, egnyte_token_requests.sole[:form])

      egnyte_tokens([ 400, { error: "invalid_token" } ])
      assert_raises(Egnyte::OAuthClient::Error) { Egnyte::OAuthClient.revoke(connection) }
    end
  end
end
