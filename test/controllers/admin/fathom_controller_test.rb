require "test_helper"
require "support/fathom_connect_fakes"

# [integration] /admin/fathom: Connect sends the admin to Fathom with a state
# kept in the session, the callback checks it, exchanges the code and stores
# the connection, then comes back where Connect was pressed; the standing page
# proves the read; Disconnect deletes the stored connection. Fathom is a
# stand-in throughout.
class Admin::FathomControllerTest < ActionDispatch::IntegrationTest
  include FathomConnectFakes

  setup { log_in_as users(:alex) }
  teardown { reset_fathom_connect }

  # Starts a connect; returns Fathom's authorize query (state, scope, ...).
  def begin_connect(return_to: nil)
    get admin_fathom_connect_path(return_to:)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  test "[integration] every action is admin only" do
    get logout_path
    get admin_fathom_connect_path
    assert_response :redirect
    assert_no_match(/fathom\.video/, response.location)
    get admin_fathom_path
    assert_response :redirect
    get admin_fathom_callback_path(code: "c", state: "s")
    assert_response :redirect
    store_fathom
    delete admin_fathom_disconnect_path
    assert_response :redirect
    assert_equal 1, FathomConnection.count, "a visitor deletes nothing"

    log_in_as users(:viewer)
    get admin_fathom_path
    assert_response :redirect
    assert_no_match(/fathom-connection-page/, response.body)
  end

  test "[integration] the callback keeps the path registered on both Fathom apps" do
    assert_equal "/admin/fathom/callback", admin_fathom_callback_path
  end

  test "[integration] callback checks state, exchanges the code and stores the connection" do
    with_fathom_env do
      query = begin_connect(return_to: "/integrations")
      assert_match %r{\Ahttps://fathom\.video/external/v1/oauth2/authorize\?}, response.location
      assert_equal admin_fathom_callback_url, query["redirect_uri"]
      assert_equal "public_api", query["scope"]
      assert query["state"].present?

      fathom_tokens([ 200, fathom_grant(refresh_token: "r-signin", access_token: "a-signin") ])
      fathom_reads("/meetings" => [ 200, MEETINGS ])
      get admin_fathom_callback_path(code: "c0de", state: query["state"])

      assert_redirected_to "/integrations"
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "Fathom connected for alex@mcritchie.studio.", flash[:notice]
      connection = FathomConnection.sole
      assert_equal "alex@mcritchie.studio", connection.account, "the recorder Fathom named"
      assert_equal "r-signin", connection.refresh_token
      assert_equal users(:alex).reload.slug, connection.connected_by
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: admin_fathom_callback_url,
                     client_id: "test-fathom-id", client_secret: "test-fathom-secret" }, fathom_token_requests.sole[:form])
      assert_equal "a-signin", fathom_read_requests.sole.last, "the identity read used the exchange's token; no refresh was spent"
    end
  end

  test "[integration] a wrong, missing or replayed state stores nothing and exchanges no code" do
    with_fathom_env do
      fathom_tokens
      state = begin_connect["state"]
      get admin_fathom_callback_path(code: "c0de", state: "#{state}x")
      assert_response :bad_request
      assert_match(/state mismatch/, response.body)

      get admin_fathom_callback_path(code: "c0de", state:) # the state was spent by the first callback
      assert_response :bad_request

      begin_connect
      get admin_fathom_callback_path(code: "c0de")
      assert_response :bad_request

      assert_empty fathom_token_requests
      assert_equal 0, FathomConnection.count
    end
  end

  test "[integration] a declined sign-in and a refused exchange say so plainly and store nothing" do
    with_fathom_env do
      state = begin_connect["state"]
      get admin_fathom_callback_path(error: "access_denied", state:)
      assert_redirected_to admin_fathom_path
      assert_equal "The sign-in was declined on Fathom. Nothing was connected.", flash[:alert]

      state = begin_connect["state"]
      fathom_tokens([ 400, { error: "invalid_request", error_description: "code expired" } ])
      get admin_fathom_callback_path(code: "c0de", state:)
      assert_redirected_to admin_fathom_path
      assert_match(/Fathom refused to exchange the sign-in code \(Fathom answered 400: code expired\)/, flash[:alert])
      assert_equal 0, FathomConnection.count
    end
  end

  test "[integration] when Fathom names nobody the connection stores under the label" do
    with_fathom_env do
      state = begin_connect["state"]
      fathom_tokens
      fathom_reads("/meetings" => [ 500, { message: "down" } ])
      get admin_fathom_callback_path(code: "c0de", state:)

      assert_equal FathomConnection::LABEL.downcase, FathomConnection.sole.account
    end
  end

  test "[integration] return_to is honoured only when it is exactly an allowed path" do
    with_fathom_env do
      [ "https://evil.example/integrations", "/integrations/../admin", "//evil.example", "/integrationsx" ].each do |bad|
        state = begin_connect(return_to: bad)["state"]
        fathom_tokens
        fathom_reads("/meetings" => [ 200, MEETINGS ])
        get admin_fathom_callback_path(code: "c0de", state:)
        assert_redirected_to admin_fathom_path, bad
      end
    end
  end

  test "[integration] connect refuses plainly when the OAuth app is not set" do
    with_fathom_env(creds: false) do
      get admin_fathom_connect_path(return_to: "/integrations")
      assert_redirected_to "/integrations"
      assert_equal Admin::FathomController::KEYS_NOT_SET, flash[:alert]
    end
  end

  test "[integration] the standing page proves the read: meetings, newest title, transcript size and summary length" do
    with_fathom_env do
      store_fathom(refresh_token: "r1")
      fathom_tokens([ 200, fathom_grant(refresh_token: "r2", access_token: "a-page") ])
      fathom_reads_answer_everything
      get admin_fathom_path

      assert_response :success
      assert_select "[data-test='fathom-section'][data-state='connected']"
      assert_select "[data-test='fathom-read'][data-count='2'][data-more='true']"
      assert_select "[data-field='newest-title']", text: "Lender call"
      assert_select "[data-field='transcript'][data-lines='3'][data-speakers='2']"
      assert_select "[data-field='summary'][data-length='#{SUMMARY.dig(:summary, :markdown_formatted).length}']"
      assert_select "[data-test='fathom-disconnect']"
      assert_equal "r2", FathomConnection.sole.refresh_token, "the page's refresh stored the new token"
      assert_no_match(/r1|r2|a-page|fathom-synthetic/, response.body)
    end
  end

  test "[integration] a spent or revoked token shows Fathom's refusal plainly" do
    with_fathom_env do
      store_fathom
      fathom_tokens([ 400, { error: "invalid_grant" } ])
      get admin_fathom_path

      assert_select "[data-test='fathom-section'][data-state='read_failed']"
      assert_select "[data-test='fathom-read-error']", text: /no longer accepts this connection/
    end
  end

  test "[integration] Disconnect deletes the stored connection and says Fathom has no revoke" do
    with_fathom_env do
      store_fathom
      delete admin_fathom_disconnect_path(return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_response :see_other
      assert_equal 0, FathomConnection.count
      assert_match(/stored token was deleted here/, flash[:notice])

      delete admin_fathom_disconnect_path
      assert_equal "Fathom was not connected, so nothing changed.", flash[:notice]
    end
  end

  test "[integration] the callback's code is filtered from the request log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("controller" => "admin/fathom", "action" => "callback", "code" => "secret-code", "state" => "s")
    assert_equal "[FILTERED]", filtered["code"]
    assert_equal "secret-code", filter.filter("controller" => "pages", "code" => "secret-code")["code"], "the control: other pages keep code"
  end
end
