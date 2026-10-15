require "test_helper"
require "support/fathom_connect_fakes"

# [unit] Fathom::OAuthClient: what the sign-in asks Fathom for, the code
# exchange, and the refresh, which stores Fathom's new single-use refresh token
# under the row's lock before the access token is used. Fathom is a stand-in
# throughout.
class Fathom::OAuthClientTest < ActiveSupport::TestCase
  include FathomConnectFakes

  teardown { reset_fathom_connect }

  test "[unit] the sign-in asks Fathom for public_api with the state, as a code grant" do
    with_fathom_env do
      url = URI(Fathom::OAuthClient.authorize_url(redirect_uri: "https://hub.test/admin/fathom/callback", state: "st"))
      query = Rack::Utils.parse_query(url.query)

      assert_equal "https://fathom.video/external/v1/oauth2/authorize", "#{url.scheme}://#{url.host}#{url.path}"
      assert_equal({ "client_id" => "test-fathom-id", "redirect_uri" => "https://hub.test/admin/fathom/callback",
                     "scope" => "public_api", "state" => "st", "response_type" => "code" }, query)
    end
  end

  test "[unit] the sign-in refuses with the env names when the app is not set" do
    with_fathom_env(creds: false) do
      error = assert_raises(Fathom::OAuthClient::NotConfigured) { Fathom::OAuthClient.authorize_url(redirect_uri: "x", state: "s") }
      assert_includes error.message, "FATHOM_CLIENT_ID and FATHOM_CLIENT_SECRET"
      assert_not Fathom::OAuthClient.connectable?
    end
  end

  test "[unit] the code exchange posts the form Fathom documents" do
    with_fathom_env do
      fathom_tokens
      grant = Fathom::OAuthClient.exchange_code(code: "c0de", redirect_uri: "https://hub.test/cb")

      assert_equal "fathom-synthetic-refresh", grant["refresh_token"]
      request = fathom_token_requests.sole
      assert_equal Fathom::OAuthClient::TOKEN_URL, request[:url]
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: "https://hub.test/cb",
                     client_id: "test-fathom-id", client_secret: "test-fathom-secret" }, request[:form])
    end
  end

  test "[unit] connection stores and rotates the refresh token: a refresh spends the stored one and stores Fathom's new one" do
    with_fathom_env do
      connection = store_fathom(refresh_token: "r1")
      fathom_tokens([ 200, fathom_grant(refresh_token: "r2", access_token: "a2") ], [ 200, fathom_grant(refresh_token: "r3", access_token: "a3") ])

      assert_equal "a2", Fathom::OAuthClient.access_token(connection)
      assert_equal "r2", FathomConnection.find(connection.id).refresh_token, "stored before the access token is handed back"
      assert_not_nil connection.reload.last_refreshed_at

      assert_equal "a3", Fathom::OAuthClient.access_token(connection)
      assert_equal "r3", connection.reload.refresh_token
      assert_equal [ "r1", "r2" ], fathom_token_requests.map { _1[:form][:refresh_token] }, "each refresh spent the token the last one stored"
      assert_equal %w[refresh_token refresh_token], fathom_token_requests.map { _1[:form][:grant_type] }
    end
  end

  test "[unit] a refresh locks and re-reads the row, so a stale copy spends the newest token, not the spent one" do
    with_fathom_env do
      stale = store_fathom(refresh_token: "r1")
      fresh = FathomConnection.find(stale.id)
      fathom_tokens([ 200, fathom_grant(refresh_token: "r2") ], [ 200, fathom_grant(refresh_token: "r3") ])

      Fathom::OAuthClient.access_token(fresh)
      assert_equal "r1", stale.refresh_token, "the control: this copy still holds the spent token in memory"
      Fathom::OAuthClient.access_token(stale)

      assert_equal [ "r1", "r2" ], fathom_token_requests.map { _1[:form][:refresh_token] }
      assert_equal "r3", FathomConnection.find(stale.id).refresh_token
    end
  end

  test "[unit] the refresh runs inside the row's lock" do
    with_fathom_env do
      connection = store_fathom
      fathom_tokens
      locked = false
      connection.define_singleton_method(:with_lock) { |*args, &block| locked = true; super(*args, &block) }

      Fathom::OAuthClient.access_token(connection)
      assert locked
    end
  end

  test "[unit] a refused refresh raises Revoked and keeps the stored token" do
    with_fathom_env do
      connection = store_fathom(refresh_token: "r1")
      fathom_tokens([ 400, { error: "invalid_grant" } ])

      assert_raises(Fathom::OAuthClient::Revoked) { Fathom::OAuthClient.access_token(connection) }
      assert_equal "r1", connection.reload.refresh_token
      assert_nil connection.last_refreshed_at
    end
  end

  test "[unit] a refresh answer without a new refresh token is an error, not a blanked row" do
    with_fathom_env do
      connection = store_fathom(refresh_token: "r1")
      fathom_tokens([ 200, { access_token: "a2" } ])

      error = assert_raises(Fathom::OAuthClient::Error) { Fathom::OAuthClient.access_token(connection) }
      assert_match(/no new refresh token/, error.message)
      assert_equal "r1", connection.reload.refresh_token
    end
  end

  test "[unit] a refresh answer without an access token still keeps the new refresh token Fathom already rotated" do
    with_fathom_env do
      connection = store_fathom(refresh_token: "r1")
      fathom_tokens([ 200, { refresh_token: "r2" } ])

      assert_raises(Fathom::OAuthClient::Error) { Fathom::OAuthClient.access_token(connection) }
      assert_equal "r2", connection.reload.refresh_token, "r1 is spent at Fathom; rolling back to it would strand the account"
    end
  end

  test "[unit] a TLS or network failure says Fathom could not be reached, naming the class only" do
    with_fathom_env do
      Net::HTTP.stub(:start, ->(*) { raise OpenSSL::SSL::SSLError, "secret detail" }) do
        error = assert_raises(Fathom::OAuthClient::Error) { Fathom::OAuthClient.exchange_code(code: "c", redirect_uri: "r") }
        assert_equal "Fathom could not be reached: OpenSSL::SSL::SSLError", error.message
      end
    end
  end
end
