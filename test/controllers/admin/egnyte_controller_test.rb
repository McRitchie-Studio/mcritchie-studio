require "test_helper"
require "support/egnyte_connect_fakes"

# [integration] /admin/egnyte: Connect takes a domain, sends the admin to that
# domain's Egnyte sign-in with a state kept in the session, the callback checks
# it, exchanges the code on the domain kept in the session and stores the
# connection, then comes back where Connect was pressed; the standing page
# proves the read per domain and browses a folder; Disconnect revokes on
# Egnyte and deletes one domain's row. Egnyte is a stand-in throughout.
class Admin::EgnyteControllerTest < ActionDispatch::IntegrationTest
  include EgnyteConnectFakes

  setup { log_in_as users(:alex) }
  teardown { reset_egnyte_connect }

  # Starts a connect; returns Egnyte's authorize URL.
  def begin_connect(domain: "example", return_to: nil)
    post admin_egnyte_connect_path, params: { egnyte_domain: domain, return_to: }.compact
    assert_response :redirect
    URI(response.location)
  end

  def state_of(url) = Rack::Utils.parse_query(url.query)["state"]

  test "[integration] every action is admin only" do
    get logout_path
    post admin_egnyte_connect_path, params: { egnyte_domain: "example" }
    assert_response :redirect
    assert_no_match(/egnyte\.com/, response.location)
    get admin_egnyte_path
    assert_response :redirect
    get admin_egnyte_callback_path(code: "c", state: "s")
    assert_response :redirect
    store_egnyte
    delete admin_egnyte_disconnect_path(egnyte_domain: "example")
    assert_response :redirect
    assert_equal 1, EgnyteConnection.count, "a visitor deletes nothing"

    log_in_as users(:viewer)
    get admin_egnyte_path
    assert_response :redirect
    assert_no_match(/egnyte-connection-page/, response.body)
  end

  test "[integration] the callback keeps the path registered on the developer key" do
    assert_equal "/admin/egnyte/callback", admin_egnyte_callback_path
  end

  test "[integration] callback checks state, exchanges the code on the session's domain and stores the connection" do
    with_egnyte_env do
      url = begin_connect(domain: "Example.egnyte.com", return_to: "/integrations")
      assert_equal [ "example.egnyte.com", "/puboauth/token" ], [ url.host, url.path ]
      query = Rack::Utils.parse_query(url.query)
      assert_equal [ admin_egnyte_callback_url, "Egnyte.filesystem", "code" ], query.values_at("redirect_uri", "scope", "response_type")

      egnyte_tokens([ 200, egnyte_grant(access_token: "a-signin", refresh_token: "r-signin") ])
      egnyte_reads([ :get, "/whoami" ] => [ 200, WHOAMI ])
      get admin_egnyte_callback_path(code: "c0de", state: query["state"], egnyte_domain: "evil")

      assert_redirected_to "/integrations"
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "Egnyte connected: example.egnyte.com as alex.", flash[:notice]
      connection = EgnyteConnection.sole
      assert_equal [ "example", "alex", "a-signin", "r-signin" ], [ connection.domain, connection.username, connection.access_token, connection.refresh_token ]
      assert_equal users(:alex).reload.slug, connection.connected_by
      assert_equal "https://example.egnyte.com/puboauth/token", egnyte_token_requests.sole[:url], "the session's domain, not the query's"
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: admin_egnyte_callback_url, scope: "Egnyte.filesystem",
                     client_id: "test-egnyte-id", client_secret: "test-egnyte-secret" }, egnyte_token_requests.sole[:form])
      assert_equal [ "https://example.egnyte.com/pubapi/v1/whoami", "a-signin" ], egnyte_read_requests.sole.values_at(:url, :token),
                   "the identity read used the exchange's token; no refresh was spent"
    end
  end

  test "[integration] a domain that is not one is refused before Egnyte is asked" do
    with_egnyte_env do
      [ "", "evil.com/x", "a.b.c", "https://evil.example" ].each do |domain|
        post admin_egnyte_connect_path, params: { egnyte_domain: domain, return_to: "/integrations" }
        assert_redirected_to "/integrations", domain
        assert_equal Admin::EgnyteController::BAD_DOMAIN, flash[:alert]
      end
      assert_nil session[:egnyte_connect_domain]
    end
  end

  test "[integration] a wrong, missing or replayed state stores nothing and exchanges no code" do
    with_egnyte_env do
      egnyte_tokens
      state = state_of(begin_connect)
      get admin_egnyte_callback_path(code: "c0de", state: "#{state}x")
      assert_response :bad_request
      assert_match(/state mismatch/, response.body)

      get admin_egnyte_callback_path(code: "c0de", state:) # the state was spent by the first callback
      assert_response :bad_request

      begin_connect
      get admin_egnyte_callback_path(code: "c0de")
      assert_response :bad_request

      assert_empty egnyte_token_requests
      assert_equal 0, EgnyteConnection.count
    end
  end

  test "[integration] a declined sign-in and a refused exchange say so plainly and store nothing" do
    with_egnyte_env do
      state = state_of(begin_connect)
      get admin_egnyte_callback_path(error: "access_denied", state:)
      assert_redirected_to admin_egnyte_path
      assert_equal "The sign-in was declined on Egnyte. Nothing was connected.", flash[:alert]

      state = state_of(begin_connect)
      egnyte_tokens([ 400, { error: "invalid_request", error_description: "code expired" } ])
      assert_difference -> { ErrorLog.count }, 1, "the refusal is kept in the error log" do
        get admin_egnyte_callback_path(code: "c0de", state:)
      end
      assert_redirected_to admin_egnyte_path
      assert_match(/Egnyte refused to exchange the sign-in code \(Egnyte answered 400: code expired\)/, flash[:alert])
      assert_equal 0, EgnyteConnection.count
    end
  end

  test "[integration] when whoami fails the connection still stores, with no username" do
    with_egnyte_env do
      state = state_of(begin_connect)
      egnyte_tokens
      egnyte_reads([ :get, "/whoami" ] => [ 500, { message: "down" } ])
      get admin_egnyte_callback_path(code: "c0de", state:)

      assert_equal "Egnyte connected: example.egnyte.com.", flash[:notice]
      assert_nil EgnyteConnection.sole.username
    end
  end

  test "[integration] return_to is honoured only when it is exactly an allowed path" do
    with_egnyte_env do
      [ "https://evil.example/integrations", "/integrations/../admin", "//evil.example", "/integrationsx" ].each do |bad|
        state = state_of(begin_connect(return_to: bad))
        egnyte_tokens
        egnyte_reads([ :get, "/whoami" ] => [ 200, WHOAMI ])
        get admin_egnyte_callback_path(code: "c0de", state:)
        assert_redirected_to admin_egnyte_path, bad
      end
    end
  end

  test "[integration] connect refuses plainly when the developer key is not set" do
    with_egnyte_env(creds: false) do
      post admin_egnyte_connect_path, params: { egnyte_domain: "example", return_to: "/integrations" }
      assert_redirected_to "/integrations"
      assert_equal Admin::EgnyteController::KEYS_NOT_SET, flash[:alert]
    end
  end

  test "[integration] the page with no developer key shows setup by name and no Connect" do
    with_egnyte_env(creds: false) do
      get admin_egnyte_path

      assert_response :success
      assert_select "[data-test='egnyte-section'][data-state='none']"
      assert_select "[data-test='egnyte-server'] [data-field='client'][data-set='false']", text: /EGNYTE_CLIENT_ID.*EGNYTE_CLIENT_SECRET/m
      assert_select "[data-test='egnyte-server']", text: /#{Regexp.escape(admin_egnyte_callback_url)}/
      assert_select "form[data-test='egnyte-connect']", 0
    end
  end

  test "[integration] the standing page proves the read per domain and browses a folder" do
    with_egnyte_env do
      access = "egnyte-page-access-5c1d9e7a"
      store_egnyte(domain: "example", access_token: access)
      store_egnyte(domain: "second", access_token: access)
      projects = { name: "Projects", path: "/Shared/Projects", is_folder: true, total_count: 1, offset: 0, folders: [],
                   files: [ { name: "Plan.pdf", path: "/Shared/Projects/Plan.pdf", size: 52_000 } ] }
      egnyte_reads([ :get, "/fs/Shared/Projects" ] => [ 200, projects ], [ :get, "/fs/Shared" ] => [ 200, SHARED ])
      egnyte_tokens
      get admin_egnyte_path

      assert_response :success
      assert_select "[data-test='egnyte-connection-page'][data-count='2']"
      assert_select "[data-test='egnyte-section'][data-domain='example'][data-state='connected'] [data-test='egnyte-read'][data-path='/Shared'][data-folders='2'][data-files='1']"
      assert_select "[data-test='egnyte-section'][data-domain='example'] a[href=?]", admin_egnyte_path(egnyte_domain: "example", path: "/Shared/Projects")
      assert_select "[data-test='egnyte-section'][data-domain='example'] [data-test='egnyte-file']", text: /Read me\.txt/
      assert_select "[data-test='egnyte-disconnect']", 2
      assert_select "form[data-test='egnyte-connect']", 1
      assert_empty egnyte_token_requests, "fresh tokens: no refresh"
      assert_no_match(/#{access}|egnyte-synthetic/, response.body)

      get admin_egnyte_path(egnyte_domain: "example", path: "/Shared/Projects")
      assert_select "[data-test='egnyte-section'][data-domain='example'] [data-test='egnyte-read'][data-path='/Shared/Projects'][data-files='1']"
      assert_select "[data-test='egnyte-section'][data-domain='second'] [data-test='egnyte-read'][data-path='/Shared']", 1, "the other domain stays at the root"
      assert_select "[data-test='egnyte-up'][href=?]", admin_egnyte_path(egnyte_domain: "example", path: "/Shared"), 1, "a subfolder links up to its parent"
    end
  end

  test "[integration] a path with a dot segment is said plainly, not sent" do
    with_egnyte_env do
      store_egnyte
      egnyte_reads({})
      get admin_egnyte_path(egnyte_domain: "example", path: "/Shared/../Private")

      assert_select "[data-test='egnyte-read-error']", text: /Not a folder this page can read/
      assert_empty egnyte_read_requests
    end
  end

  test "[integration] a revoked token shows Egnyte's refusal plainly and is kept in the error log" do
    with_egnyte_env do
      store_egnyte(now: 40.days.ago)
      egnyte_tokens([ 400, { message: "Invalid Refresh Token" } ])
      get admin_egnyte_path

      assert_select "[data-test='egnyte-section'][data-state='read_failed']"
      assert_select "[data-test='egnyte-read-error']", text: /no longer accepts this connection/
      log = ErrorLog.order(:id).last
      assert_equal "EgnyteConnection", log.target_type, "kept in the error log against the connection"
    end
  end

  test "[integration] Disconnect revokes one domain's tokens on Egnyte and deletes only its row" do
    with_egnyte_env do
      store_egnyte(domain: "example", refresh_token: "r-example")
      store_egnyte(domain: "second")
      egnyte_tokens([ 200, "" ])
      delete admin_egnyte_disconnect_path(egnyte_domain: "example", return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_response :see_other
      assert_equal %w[second], EgnyteConnection.pluck(:domain)
      assert_equal [ "https://example.egnyte.com/pubapi/v1/tokens/revoke", "r-example" ], egnyte_token_requests.sole.then { [ _1[:url], _1[:form][:token] ] }
      assert_match(/tokens were revoked on Egnyte and deleted here/, flash[:notice])

      delete admin_egnyte_disconnect_path(egnyte_domain: "example")
      assert_equal "That Egnyte domain was not connected, so nothing changed.", flash[:notice]
    end
  end

  test "[integration] a refused revoke still deletes the row and says to remove the access in Egnyte" do
    with_egnyte_env do
      store_egnyte
      egnyte_tokens([ 500, { message: "down" } ])
      delete admin_egnyte_disconnect_path(egnyte_domain: "example")

      assert_equal 0, EgnyteConnection.count
      assert_match(/did not confirm the revoke/, flash[:notice])
    end
  end

  test "[integration] the callback's code is filtered from the request log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("controller" => "admin/egnyte", "action" => "callback", "code" => "secret-code", "state" => "s")
    assert_equal "[FILTERED]", filtered["code"]
    assert_equal "secret-code", filter.filter("controller" => "pages", "code" => "secret-code")["code"], "the control: other pages keep code"
  end
end
