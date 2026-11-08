require "test_helper"
require "support/quickbooks_connect_fakes"

# [integration] /admin/quickbooks: Connect sends the admin to Intuit with a
# state kept in the session; the callback checks it, takes the realmId,
# exchanges the code and stores the connection, then comes back where Connect
# was pressed; the standing page proves the read per company; Disconnect
# revokes at Intuit and deletes the row. Intuit is a stand-in throughout.
class Admin::QuickbooksControllerTest < ActionDispatch::IntegrationTest
  include QuickbooksConnectFakes

  setup { log_in_as users(:alex) }
  teardown { reset_quickbooks_connect }

  # Starts a connect; returns Intuit's authorize query (state, scope, ...).
  def begin_connect(return_to: nil)
    get admin_quickbooks_connect_path(return_to:)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  test "[integration] every action is admin only" do
    get logout_path
    get admin_quickbooks_connect_path
    assert_response :redirect
    assert_no_match(/intuit\.com/, response.location)
    get admin_quickbooks_path
    assert_response :redirect
    get admin_quickbooks_callback_path(code: "c", state: "s", realmId: REALM)
    assert_response :redirect
    connection = store_quickbooks
    delete admin_quickbooks_disconnect_path(connection)
    assert_response :redirect
    assert_equal 1, QuickbooksConnection.count, "a visitor deletes nothing"

    log_in_as users(:viewer)
    get admin_quickbooks_path
    assert_response :redirect
    assert_no_match(/quickbooks-connection-page/, response.body)
  end

  test "[integration] the callback keeps the path registered on the Intuit app" do
    assert_equal "/admin/quickbooks/callback", admin_quickbooks_callback_path
  end

  test "[integration] callback checks state, takes the realmId, exchanges the code and stores the connection" do
    with_quickbooks_env do
      query = begin_connect(return_to: "/integrations")
      assert_match %r{\Ahttps://appcenter\.intuit\.com/connect/oauth2\?}, response.location
      assert_equal admin_quickbooks_callback_url, query["redirect_uri"]
      assert_equal "com.intuit.quickbooks.accounting", query["scope"]
      assert query["state"].present?

      quickbooks_tokens([ 200, quickbooks_grant(refresh_token: "r-signin", access_token: "a-signin") ])
      quickbooks_reads("/companyinfo" => [ 200, COMPANY_INFO ])
      get admin_quickbooks_callback_path(code: "c0de", state: query["state"], realmId: REALM)

      assert_redirected_to "/integrations"
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "QuickBooks connected: Synthetic Co (sandbox).", flash[:notice]
      connection = QuickbooksConnection.sole
      assert_equal REALM, connection.realm_id
      assert_equal "Synthetic Co", connection.company_name, "the name CompanyInfo gave"
      assert_equal "sandbox", connection.environment
      assert_equal "r-signin", connection.refresh_token
      assert_not_nil connection.refresh_token_expires_at
      assert_equal users(:alex).reload.slug, connection.connected_by
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: admin_quickbooks_callback_url }, quickbooks_token_requests.sole[:form])
      assert_equal "a-signin", quickbooks_read_requests.sole.last, "the company read used the exchange's token; no refresh was spent"
    end
  end

  test "[integration] production keys store a production connection" do
    with_quickbooks_env(environment: "production") do
      state = begin_connect["state"]
      quickbooks_tokens
      quickbooks_reads("/companyinfo" => [ 200, COMPANY_INFO ])
      get admin_quickbooks_callback_path(code: "c0de", state:, realmId: REALM)

      assert_equal "production", QuickbooksConnection.sole.environment
      assert quickbooks_read_requests.sole.first.start_with?("https://quickbooks.api.intuit.com/")
    end
  end

  test "[integration] a wrong, missing or replayed state stores nothing and exchanges no code" do
    with_quickbooks_env do
      quickbooks_tokens
      state = begin_connect["state"]
      get admin_quickbooks_callback_path(code: "c0de", state: "#{state}x", realmId: REALM)
      assert_response :bad_request
      assert_match(/state mismatch/, response.body)

      get admin_quickbooks_callback_path(code: "c0de", state:, realmId: REALM) # the state was spent by the first callback
      assert_response :bad_request

      begin_connect
      get admin_quickbooks_callback_path(code: "c0de", realmId: REALM)
      assert_response :bad_request

      assert_empty quickbooks_token_requests
      assert_equal 0, QuickbooksConnection.count
    end
  end

  test "[integration] a callback without a realmId exchanges no code and stores nothing" do
    with_quickbooks_env do
      quickbooks_tokens
      state = begin_connect["state"]
      get admin_quickbooks_callback_path(code: "c0de", state:)

      assert_redirected_to admin_quickbooks_path
      assert_match(/without naming a company/, flash[:alert])
      assert_empty quickbooks_token_requests
      assert_equal 0, QuickbooksConnection.count
    end
  end

  test "[integration] a declined sign-in and a refused exchange say so plainly and store nothing" do
    with_quickbooks_env do
      state = begin_connect["state"]
      get admin_quickbooks_callback_path(error: "access_denied", state:)
      assert_redirected_to admin_quickbooks_path
      assert_equal "The sign-in was declined on Intuit. Nothing was connected.", flash[:alert]

      state = begin_connect["state"]
      quickbooks_tokens([ 400, { error: "invalid_request", error_description: "code expired" } ])
      assert_difference -> { ErrorLog.count }, 1, "the refusal is kept in the error log" do
        get admin_quickbooks_callback_path(code: "c0de", state:, realmId: REALM)
      end
      assert_redirected_to admin_quickbooks_path
      assert_match(/Intuit refused to exchange the sign-in code \(Intuit answered 400: code expired\)/, flash[:alert])
      assert_equal 0, QuickbooksConnection.count
    end
  end

  test "[integration] when CompanyInfo fails the connection stores under the label" do
    with_quickbooks_env do
      state = begin_connect["state"]
      quickbooks_tokens
      quickbooks_reads("/companyinfo" => [ 500, { Fault: { Error: [ { Message: "down" } ] } } ])
      get admin_quickbooks_callback_path(code: "c0de", state:, realmId: REALM)

      assert_equal QuickbooksConnection::LABEL, QuickbooksConnection.sole.company_name
    end
  end

  test "[integration] return_to is honoured only when it is exactly an allowed path" do
    with_quickbooks_env do
      [ "https://evil.example/integrations", "/integrations/../admin", "//evil.example", "/integrationsx" ].each do |bad|
        state = begin_connect(return_to: bad)["state"]
        quickbooks_tokens
        quickbooks_reads("/companyinfo" => [ 200, COMPANY_INFO ])
        get admin_quickbooks_callback_path(code: "c0de", state:, realmId: REALM)
        assert_redirected_to admin_quickbooks_path, bad
      end
    end
  end

  test "[integration] Connect renders disabled and refuses plainly when the Intuit app is not set" do
    with_quickbooks_env(creds: false) do
      get admin_quickbooks_path
      assert_select "[data-test='quickbooks-section'][data-state='none']"
      assert_select "button[data-test='quickbooks-connect-disabled'][disabled]"
      assert_select "a[data-test='quickbooks-connect']", 0
      assert_select "[data-test='quickbooks-server'] [data-field='client'][data-set='false']", text: /INTUIT_CLIENT_ID.*INTUIT_CLIENT_SECRET/m
      assert_select "[data-test='quickbooks-server']", text: /#{Regexp.escape(admin_quickbooks_callback_url)}/

      get admin_quickbooks_connect_path(return_to: "/integrations")
      assert_redirected_to "/integrations"
      assert_equal Admin::QuickbooksController::KEYS_NOT_SET, flash[:alert]
    end
  end

  test "[integration] the standing page proves the read per company: name, period and net income" do
    with_quickbooks_env do
      # Long, unique tokens: the page carries a random CSP nonce, and a short
      # fixture could match inside one by chance.
      stored, rotated, access = "qbo-stored-refresh-7f3c9a", "qbo-rotated-refresh-2b8e41", "qbo-page-access-d05a6e"
      store_quickbooks(refresh_token: stored)
      quickbooks_tokens([ 200, quickbooks_grant(refresh_token: rotated, access_token: access) ])
      quickbooks_reads_answer_everything
      get admin_quickbooks_path

      assert_response :success
      assert_select "[data-test='quickbooks-connection-page'][data-count='1']"
      assert_select "[data-test='quickbooks-section'][data-state='connected'][data-environment='sandbox']"
      assert_select "[data-field='company-info']", text: /Synthetic Co/
      assert_select "[data-test='quickbooks-read'][data-sections='3']"
      assert_select "[data-field='net-income']", text: "109.50 USD"
      assert_select "[data-test='quickbooks-disconnect']"
      assert_select "a[data-test='quickbooks-connect']", 1, "Connect adds another company"
      assert_equal rotated, QuickbooksConnection.sole.refresh_token, "the page's refresh stored the new token"
      assert_no_match(Regexp.union(stored, rotated, access, "qbo-synthetic", REALM), response.body)
      report_url = quickbooks_read_requests.map(&:first).find { _1.include?("ProfitAndLoss") }
      today = Time.current.in_time_zone("America/Denver").to_date
      assert_includes report_url, "start_date=#{today.beginning_of_year.iso8601}&end_date=#{today.iso8601}"
    end
  end

  test "[integration] a revoked or lapsed token shows Intuit's refusal plainly" do
    with_quickbooks_env do
      store_quickbooks
      quickbooks_tokens([ 400, { error: "invalid_grant" } ])
      get admin_quickbooks_path

      assert_select "[data-test='quickbooks-section'][data-state='read_failed']"
      assert_select "[data-test='quickbooks-read-error']", text: /no longer accepts this connection/
      log = ErrorLog.order(:id).last
      assert_equal "QuickbooksConnection", log.target_type, "kept in the error log against the connection"
      assert_match(/no longer accepts this connection/, log.message)
    end
  end

  test "[integration] Disconnect revokes at Intuit and deletes only that company" do
    with_quickbooks_env do
      first = store_quickbooks(refresh_token: "r-first")
      other = store_quickbooks(realm_id: "1234500000000002", company_name: "Other Co")
      quickbooks_tokens([ 200, "" ])
      delete admin_quickbooks_disconnect_path(first, return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_response :see_other
      assert_equal [ other ], QuickbooksConnection.all.to_a
      assert_equal({ token: "r-first" }, quickbooks_token_requests.sole[:form])
      assert_equal Quickbooks::OAuthClient::REVOKE_URL, quickbooks_token_requests.sole[:url]
      assert_match(/Intuit revoked the grant and the stored token was deleted here/, flash[:notice])

      delete admin_quickbooks_disconnect_path(first)
      assert_equal "That QuickBooks company was not connected, so nothing changed.", flash[:notice]
    end
  end

  test "[integration] a refused revoke still deletes the row and says to remove access in QuickBooks" do
    with_quickbooks_env do
      connection = store_quickbooks
      quickbooks_tokens([ 500, { error: "server_error" } ])
      assert_difference -> { ErrorLog.count }, 1 do
        delete admin_quickbooks_disconnect_path(connection)
      end

      assert_equal 0, QuickbooksConnection.count
      assert_match(/Intuit did not confirm the revoke/, flash[:notice])
    end
  end

  test "[integration] the callback's code is filtered from its Parameters line, and realmId everywhere" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("controller" => "admin/quickbooks", "action" => "callback", "code" => "secret-code", "realmId" => REALM, "state" => "s")
    assert_equal "[FILTERED]", filtered["code"]
    assert_equal "[FILTERED]", filtered["realmId"]
    assert_equal "secret-code", filter.filter("controller" => "pages", "code" => "secret-code")["code"], "the control: other pages keep code"
    assert_equal "[FILTERED]", filter.filter("controller" => "pages", "realmId" => REALM)["realmId"], "realmId is filtered by key, on any page"
  end

  test "[integration] the Started GET line's URL never carries the realmId" do
    env = Rack::MockRequest.env_for("/admin/quickbooks/callback?code=c0de&realmId=#{REALM}&state=s",
                                    "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters)
    path = ActionDispatch::Request.new(env).filtered_path

    assert_includes path, "realmId=[FILTERED]"
    assert_not_includes path, REALM
    assert_includes path, "state=s", "the control: the query string is still logged"
  end
end
