require "test_helper"
require "support/quickbooks_connect_fakes"

# [unit] Quickbooks::OAuthClient: what the sign-in asks Intuit for, the code
# exchange, the refresh (which stores Intuit's answered refresh token under the
# row's lock before the access token is used) and the revoke. Intuit is a
# stand-in throughout.
class Quickbooks::OAuthClientTest < ActiveSupport::TestCase
  include QuickbooksConnectFakes

  teardown { reset_quickbooks_connect }

  BASIC = "Basic #{Base64.strict_encode64('test-intuit-id:test-intuit-secret')}".freeze

  test "[unit] the sign-in asks Intuit for the accounting scope with the state, as a code grant" do
    with_quickbooks_env do
      url = URI(Quickbooks::OAuthClient.authorize_url(redirect_uri: "https://hub.test/admin/quickbooks/callback", state: "st"))
      query = Rack::Utils.parse_query(url.query)

      assert_equal "https://appcenter.intuit.com/connect/oauth2", "#{url.scheme}://#{url.host}#{url.path}"
      assert_equal({ "client_id" => "test-intuit-id", "redirect_uri" => "https://hub.test/admin/quickbooks/callback",
                     "scope" => "com.intuit.quickbooks.accounting", "state" => "st", "response_type" => "code" }, query)
    end
  end

  test "[unit] the sign-in refuses with the env names when the app is not set" do
    with_quickbooks_env(creds: false) do
      error = assert_raises(Quickbooks::OAuthClient::NotConfigured) { Quickbooks::OAuthClient.authorize_url(redirect_uri: "x", state: "s") }
      assert_includes error.message, "INTUIT_CLIENT_ID and INTUIT_CLIENT_SECRET"
      assert_not Quickbooks::OAuthClient.configured?
      assert_not Quickbooks::OAuthClient.connectable?
    end
  end

  test "[unit] the environment is production only when said exactly; anything else is the sandbox" do
    with_quickbooks_env { assert_equal "sandbox", Quickbooks::OAuthClient.environment }
    with_quickbooks_env(environment: " Production ") { assert_equal "production", Quickbooks::OAuthClient.environment }
    with_quickbooks_env(environment: "prod") { assert_equal "sandbox", Quickbooks::OAuthClient.environment }
  end

  test "[unit] the code exchange posts Intuit's form with HTTP Basic client auth" do
    with_quickbooks_env do
      quickbooks_tokens
      grant = Quickbooks::OAuthClient.exchange_code(code: "c0de", redirect_uri: "https://hub.test/cb")

      assert_equal "qbo-synthetic-refresh", grant["refresh_token"]
      request = quickbooks_token_requests.sole
      assert_equal "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer", request[:url]
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: "https://hub.test/cb" }, request[:form],
                   "the secret rides the header, never the form")
      assert_equal BASIC, request[:headers]["Authorization"]
      assert_equal "application/json", request[:headers]["Accept"]
      assert_equal "application/x-www-form-urlencoded", request[:headers]["Content-Type"]
    end
  end

  test "[unit] connection stores and rotates the refresh token: each refresh spends the stored one and stores Intuit's answer" do
    with_quickbooks_env do
      connection = store_quickbooks(refresh_token: "r1")
      quickbooks_tokens([ 200, quickbooks_grant(refresh_token: "r2", access_token: "a2") ], [ 200, quickbooks_grant(refresh_token: "r3", access_token: "a3") ])

      assert_equal "a2", Quickbooks::OAuthClient.access_token(connection)
      assert_equal "r2", QuickbooksConnection.find(connection.id).refresh_token, "stored before the access token is handed back"
      assert_not_nil connection.reload.last_refreshed_at

      assert_equal "a3", Quickbooks::OAuthClient.access_token(connection)
      assert_equal "r3", connection.reload.refresh_token
      assert_equal %w[r1 r2], quickbooks_token_requests.map { _1[:form][:refresh_token] }, "each refresh spent the token the last one stored"
      assert_equal %w[refresh_token refresh_token], quickbooks_token_requests.map { _1[:form][:grant_type] }
      assert_equal [ BASIC ], quickbooks_token_requests.map { _1[:headers]["Authorization"] }.uniq
    end
  end

  test "[unit] a refresh that answers the same refresh token keeps it and stamps the refresh" do
    with_quickbooks_env do
      connection = store_quickbooks(refresh_token: "r1")
      quickbooks_tokens([ 200, quickbooks_grant(refresh_token: "r1", access_token: "a2") ])

      assert_equal "a2", Quickbooks::OAuthClient.access_token(connection)
      assert_equal "r1", connection.reload.refresh_token
      assert_not_nil connection.last_refreshed_at
    end
  end

  test "[unit] a refresh locks and re-reads the row, so a stale copy spends the newest token, not the superseded one" do
    with_quickbooks_env do
      stale = store_quickbooks(refresh_token: "r1")
      fresh = QuickbooksConnection.find(stale.id)
      quickbooks_tokens([ 200, quickbooks_grant(refresh_token: "r2") ], [ 200, quickbooks_grant(refresh_token: "r3") ])

      Quickbooks::OAuthClient.access_token(fresh)
      assert_equal "r1", stale.refresh_token, "the control: this copy still holds the old token in memory"
      Quickbooks::OAuthClient.access_token(stale)

      assert_equal %w[r1 r2], quickbooks_token_requests.map { _1[:form][:refresh_token] }
      assert_equal "r3", QuickbooksConnection.find(stale.id).refresh_token
    end
  end

  test "[unit] the refresh runs inside the row's lock" do
    with_quickbooks_env do
      connection = store_quickbooks
      quickbooks_tokens
      locked = false
      connection.define_singleton_method(:with_lock) { |*args, &block| locked = true; super(*args, &block) }

      Quickbooks::OAuthClient.access_token(connection)
      assert locked
    end
  end

  test "[unit] a refused refresh raises Revoked and keeps the stored token" do
    with_quickbooks_env do
      connection = store_quickbooks(refresh_token: "r1")
      quickbooks_tokens([ 400, { error: "invalid_grant" } ])

      assert_raises(Quickbooks::OAuthClient::Revoked) { Quickbooks::OAuthClient.access_token(connection) }
      assert_equal "r1", connection.reload.refresh_token
      assert_nil connection.last_refreshed_at
    end
  end

  test "[unit] a refresh answer without a refresh token is an error, not a blanked row" do
    with_quickbooks_env do
      connection = store_quickbooks(refresh_token: "r1")
      quickbooks_tokens([ 200, { access_token: "a2" } ])

      error = assert_raises(Quickbooks::OAuthClient::Error) { Quickbooks::OAuthClient.access_token(connection) }
      assert_match(/no refresh token/, error.message)
      assert_equal "r1", connection.reload.refresh_token
    end
  end

  test "[unit] a refresh answer without an access token still keeps the refresh token Intuit already rotated" do
    with_quickbooks_env do
      connection = store_quickbooks(refresh_token: "r1")
      quickbooks_tokens([ 200, { refresh_token: "r2" } ])

      assert_raises(Quickbooks::OAuthClient::Error) { Quickbooks::OAuthClient.access_token(connection) }
      assert_equal "r2", connection.reload.refresh_token, "rolling back to r1 would strand the company once it lapses"
    end
  end

  test "[unit] revoke posts the refresh token as JSON with Basic auth, and says Intuit's refusal plainly" do
    with_quickbooks_env do
      connection = store_quickbooks(refresh_token: "r-revoke")
      quickbooks_tokens([ 200, "" ], [ 400, { error: "invalid_request" } ])

      assert Quickbooks::OAuthClient.revoke(connection)
      request = quickbooks_token_requests.first
      assert_equal "https://developer.api.intuit.com/v2/oauth2/tokens/revoke", request[:url]
      assert_equal({ token: "r-revoke" }, request[:form])
      assert_equal "application/json", request[:headers]["Content-Type"]
      assert_equal BASIC, request[:headers]["Authorization"]

      error = assert_raises(Quickbooks::OAuthClient::Error) { Quickbooks::OAuthClient.revoke(connection) }
      assert_equal "Intuit answered 400: invalid_request", error.message
    end
  end

  test "[unit] the real call sends the Basic header and a form body; a JSON call sends JSON" do
    with_quickbooks_env do
      sent = []
      fake_http = Object.new
      fake_http.define_singleton_method(:request) do |req|
        sent << req
        Struct.new(:code, :body).new("200", { access_token: "a", refresh_token: "r" }.to_json)
      end
      Net::HTTP.stub(:start, ->(*, **, &block) { block.call(fake_http) }) do
        Quickbooks::OAuthClient.exchange_code(code: "c 1", redirect_uri: "https://hub.test/cb")
        Quickbooks::OAuthClient.revoke(store_quickbooks(refresh_token: "r-json"))
      end
      assert_equal BASIC, sent.first["Authorization"]
      assert_equal "grant_type=authorization_code&code=c+1&redirect_uri=https%3A%2F%2Fhub.test%2Fcb", sent.first.body
      assert_equal({ "token" => "r-json" }, JSON.parse(sent.second.body))
    end
  end

  test "[unit] a TLS or network failure says Intuit could not be reached, naming the class only" do
    with_quickbooks_env do
      Net::HTTP.stub(:start, ->(*) { raise OpenSSL::SSL::SSLError, "secret detail" }) do
        error = assert_raises(Quickbooks::OAuthClient::Error) { Quickbooks::OAuthClient.exchange_code(code: "c", redirect_uri: "r") }
        assert_equal "Intuit could not be reached: OpenSSL::SSL::SSLError", error.message
      end
    end
  end
end
