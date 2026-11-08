require "test_helper"
require "support/msgraph_connect_fakes"

# [unit] Msgraph::OAuthClient: the admin-consent URL, the client-credentials
# token request as Microsoft documents it, the in-memory token cache, and how
# refusals are said. Microsoft is a stand-in throughout.
class Msgraph::OAuthClientTest < ActiveSupport::TestCase
  include MsgraphConnectFakes

  NOW = Time.utc(2026, 11, 6, 20, 0, 0)
  teardown { reset_msgraph_connect }

  test "[unit] configured? needs both env names; connectable? also takes the stand-in" do
    with_msgraph_env(creds: false) do
      assert_not Msgraph::OAuthClient.configured?
      assert_not Msgraph::OAuthClient.connectable?
      Msgraph::OAuthClient.sign_in_stand_in = Object.new
      assert Msgraph::OAuthClient.connectable?
    end
    with_msgraph_env { assert Msgraph::OAuthClient.configured? }
    assert_equal %w[MSGRAPH_CLIENT_ID MSGRAPH_CLIENT_SECRET], Msgraph::OAuthClient::ENV_NAMES
    assert_empty Msgraph::OAuthClient::ENV_NAMES.grep(/TEAMS_BOT/), "the Teams bot's credentials are not reused"
  end

  test "[unit] the consent URL is the documented admin-consent endpoint with client id, redirect and state" do
    with_msgraph_env do
      url = URI(Msgraph::OAuthClient.authorize_url(redirect_uri: "https://hub.example/admin/msgraph/callback", state: "s1"))
      assert_equal "https://login.microsoftonline.com/common/adminconsent", "#{url.scheme}://#{url.host}#{url.path}"
      assert_equal({ "client_id" => "test-msgraph-id", "redirect_uri" => "https://hub.example/admin/msgraph/callback", "state" => "s1" },
                   Rack::Utils.parse_query(url.query))
    end
  end

  test "[unit] without the env names a Connect is refused before Microsoft is asked" do
    with_msgraph_env(creds: false) do
      assert_raises(Msgraph::OAuthClient::NotConfigured) { Msgraph::OAuthClient.authorize_url(redirect_uri: "x", state: "s") }
      assert_raises(Msgraph::OAuthClient::NotConfigured) { Msgraph::OAuthClient.access_token(TENANT) }
    end
  end

  test "[unit] a token is a client-credentials grant on the tenant's own endpoint for the Graph default scope" do
    with_msgraph_env do
      msgraph_tokens([ 200, msgraph_grant(access_token: "a1") ])
      assert_equal "a1", Msgraph::OAuthClient.access_token(TENANT, now: NOW)

      request = msgraph_token_requests.sole
      assert_equal "https://login.microsoftonline.com/#{TENANT}/oauth2/v2.0/token", request[:url]
      assert_equal({ grant_type: "client_credentials", scope: "https://graph.microsoft.com/.default",
                     client_id: "test-msgraph-id", client_secret: "test-msgraph-secret" }, request[:form])
    end
  end

  test "[unit] the token is cached in memory per tenant until shortly before it expires" do
    with_msgraph_env do
      msgraph_tokens([ 200, msgraph_grant(access_token: "a1", expires_in: 3599) ], [ 200, msgraph_grant(access_token: "a2") ],
                     [ 200, msgraph_grant(access_token: "b1") ])
      assert_equal "a1", Msgraph::OAuthClient.access_token(TENANT, now: NOW)
      assert_equal "a1", Msgraph::OAuthClient.access_token(TENANT.upcase, now: NOW + 50.minutes), "cached, case-blind"
      assert_equal 1, msgraph_token_requests.size

      assert_equal "a2", Msgraph::OAuthClient.access_token(TENANT, now: NOW + 55.minutes), "inside the margin a new token is asked for"
      assert_equal "b1", Msgraph::OAuthClient.access_token(OTHER_TENANT, now: NOW), "each tenant has its own token"
      assert_equal 3, msgraph_token_requests.size
      assert_equal 2, Msgraph::OAuthClient.cached_count

      Msgraph::OAuthClient.forget!(TENANT)
      assert_equal 1, Msgraph::OAuthClient.cached_count
      assert_equal 0, MsgraphConnection.count, "no token, and no row, is written by a token request"
    end
  end

  test "[unit] a tenant that refuses the app is Revoked; any other refusal says Microsoft's first line" do
    with_msgraph_env do
      msgraph_tokens([ 400, { error: "unauthorized_client", error_description: "AADSTS700016: Application not found.\r\nTrace ID: x" } ])
      error = assert_raises(Msgraph::OAuthClient::Revoked) { Msgraph::OAuthClient.access_token(TENANT) }
      assert_match(/unauthorized_client/, error.message)

      msgraph_tokens([ 401, { error: "invalid_client", error_description: "AADSTS7000215: Invalid client secret.\r\nTrace ID: x" } ])
      error = assert_raises(Msgraph::OAuthClient::Error) { Msgraph::OAuthClient.access_token(TENANT) }
      assert_not_kind_of Msgraph::OAuthClient::Revoked, error
      assert_equal "Microsoft answered 401: AADSTS7000215: Invalid client secret.", error.message

      msgraph_tokens([ 200, { token_type: "Bearer", expires_in: 3599 } ])
      assert_raises(Msgraph::OAuthClient::Error) { Msgraph::OAuthClient.access_token(TENANT) }
      assert_equal 0, Msgraph::OAuthClient.cached_count, "a refusal caches nothing"
    end
  end

  test "[unit] an unreachable Microsoft is said by error class, never by secret" do
    with_msgraph_env do
      Msgraph::OAuthClient.stub(:http, nil) do
        Net::HTTP.stub(:start, ->(*) { raise SocketError, "getaddrinfo" }) do
          error = assert_raises(Msgraph::OAuthClient::Error) { Msgraph::OAuthClient.access_token(TENANT) }
          assert_equal "Microsoft could not be reached: SocketError", error.message
        end
      end
    end
  end
end
