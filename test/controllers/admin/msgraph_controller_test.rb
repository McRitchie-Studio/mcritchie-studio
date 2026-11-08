require "test_helper"
require "support/msgraph_connect_fakes"

# [integration] /admin/msgraph: Connect sends the admin to Microsoft's
# admin-consent page with a state kept in the session; the callback checks it
# and admin_consent=True, names the tenant from Graph and stores the
# connection, then comes back where Connect was pressed; the standing page
# proves the read; Disconnect deletes one tenant and its cached token.
# Microsoft is a stand-in throughout, and no page renders a tenant id.
class Admin::MsgraphControllerTest < ActionDispatch::IntegrationTest
  include MsgraphConnectFakes

  setup { log_in_as users(:alex) }
  teardown { reset_msgraph_connect }

  def begin_connect(return_to: nil)
    get admin_msgraph_connect_path(return_to:)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  def consent(state, tenant: TENANT, admin_consent: "True")
    get admin_msgraph_callback_path(tenant:, admin_consent:, state:)
  end

  test "[integration] every action is admin only" do
    get logout_path
    get admin_msgraph_connect_path
    assert_response :redirect
    assert_no_match(/microsoftonline/, response.location)
    get admin_msgraph_path
    assert_response :redirect
    get admin_msgraph_callback_path(tenant: TENANT, admin_consent: "True", state: "s")
    assert_response :redirect
    connection = store_msgraph
    delete admin_msgraph_disconnect_path(connection)
    assert_response :redirect
    assert_equal 1, MsgraphConnection.count, "a visitor deletes nothing"

    log_in_as users(:viewer)
    get admin_msgraph_path
    assert_response :redirect
    assert_no_match(/msgraph-connection-page/, response.body)
  end

  test "[integration] the callback keeps the path registered on the Entra app" do
    assert_equal "/admin/msgraph/callback", admin_msgraph_callback_path
  end

  test "[integration] consent: state checked, tenant named from Graph, connection stored, no id shown" do
    with_msgraph_env do
      query = begin_connect(return_to: "/integrations")
      assert_match %r{\Ahttps://login\.microsoftonline\.com/common/adminconsent\?}, response.location
      assert_equal admin_msgraph_callback_url, query["redirect_uri"]
      assert_equal "test-msgraph-id", query["client_id"]
      assert query["state"].present?

      msgraph_tokens
      msgraph_reads("/organization/" => [ 200, ORGANIZATION ])
      consent(query["state"], tenant: TENANT.upcase)

      assert_redirected_to "/integrations"
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "Microsoft 365 connected for Synthetic Org.", flash[:notice]
      connection = MsgraphConnection.sole
      assert_equal TENANT, connection.tenant_id
      assert_equal "Synthetic Org", connection.display_name
      assert_equal users(:alex).reload.slug, connection.connected_by
      assert_includes msgraph_token_requests.sole[:url], "/#{TENANT}/oauth2/v2.0/token"

      msgraph_reads_answer_everything
      get admin_msgraph_path
      assert_no_match(/#{TENANT}/i, response.body)
      get integrations_path
      assert_no_match(/#{TENANT}/i, response.body)
    end
  end

  test "[integration] a wrong, missing or replayed state stores nothing and asks Microsoft nothing" do
    with_msgraph_env do
      msgraph_tokens
      state = begin_connect["state"]
      consent("#{state}x")
      assert_response :bad_request
      assert_match(/state mismatch/, response.body)

      consent(state)
      assert_response :bad_request

      begin_connect
      consent(nil)
      assert_response :bad_request

      assert_empty msgraph_token_requests
      assert_equal 0, MsgraphConnection.count
    end
  end

  test "[integration] a declined, unapproved or tenant-less answer says so and stores nothing" do
    with_msgraph_env do
      msgraph_tokens
      state = begin_connect["state"]
      get admin_msgraph_callback_path(error: "access_denied", error_description: "The admin canceled the request", state:)
      assert_redirected_to admin_msgraph_path
      assert_equal "The approval was declined on Microsoft. Nothing was connected.", flash[:alert]

      state = begin_connect["state"]
      get admin_msgraph_callback_path(error: "invalid_request", state:)
      assert_match(/defederated/, flash[:alert], "the GoDaddy-federation block is named as a likely cause")

      consent(begin_connect["state"], admin_consent: "False")
      assert_match(/did not report an approval/, flash[:alert])

      consent(begin_connect["state"], tenant: "common")
      assert_match(/named no valid tenant/, flash[:alert])

      assert_empty msgraph_token_requests
      assert_equal 0, MsgraphConnection.count
    end
  end

  test "[integration] when Graph cannot name the tenant yet the connection stores under the label" do
    with_msgraph_env do
      state = begin_connect["state"]
      msgraph_tokens([ 400, { error: "unauthorized_client" } ])
      assert_difference -> { ErrorLog.count }, 1, "the failed name read is kept in the error log" do
        consent(state)
      end

      assert_equal MsgraphConnection::LABEL, MsgraphConnection.sole.display_name
      assert_match(/not found in, or not enabled for/, ErrorLog.order(:id).last.message)
      assert_no_match(/#{TENANT}/i, ErrorLog.order(:id).last.message.to_s)
    end
  end

  test "[integration] return_to is honoured only when it is exactly an allowed path" do
    with_msgraph_env do
      [ "https://evil.example/integrations", "/integrations/../admin", "//evil.example", "/integrationsx" ].each do |bad|
        state = begin_connect(return_to: bad)["state"]
        msgraph_tokens
        msgraph_reads("/organization/" => [ 200, ORGANIZATION ])
        consent(state)
        assert_redirected_to admin_msgraph_path, bad
      end
    end
  end

  test "[integration] connect refuses plainly when the app registration is not set, and the page names what to set" do
    with_msgraph_env(creds: false) do
      get admin_msgraph_connect_path(return_to: "/integrations")
      assert_redirected_to "/integrations"
      assert_equal Admin::MsgraphController::KEYS_NOT_SET, flash[:alert]

      get admin_msgraph_path
      assert_select "[data-test='msgraph-connect']", count: 0
      assert_select "[data-field='client'][data-set='false']", text: /MSGRAPH_CLIENT_ID.*Team\.ReadBasic\.All/m
      assert_select "[data-test='msgraph-section'][data-state='none']"
    end
  end

  test "[integration] the standing page proves the read: users, Teams, root site and drives" do
    with_msgraph_env do
      store_msgraph
      msgraph_tokens([ 200, msgraph_grant(access_token: "graph-page-access-d05a6e") ])
      msgraph_reads_answer_everything
      get admin_msgraph_path

      assert_response :success
      assert_select "[data-test='msgraph-section'][data-state='connected']"
      assert_select "[data-field='display-name']", text: "Synthetic Org"
      assert_select "[data-field='users'][data-count='2'][data-more='true']"
      assert_select "[data-field='teams'][data-count='1'][data-more='false']"
      assert_select "[data-field='site']", text: "Home"
      assert_select "[data-field='drives'][data-count='1']", text: "Documents"
      assert_select "[data-test='msgraph-disconnect']"
      assert_select "[data-test='msgraph-connect']"
      assert_no_match(/graph-page-access-d05a6e/, response.body)

      get admin_msgraph_path
      assert_equal 1, msgraph_token_requests.size, "the second load used the cached token"
    end
  end

  test "[integration] a tenant that removed consent shows the refusal plainly and is kept in the error log" do
    with_msgraph_env do
      store_msgraph
      msgraph_tokens([ 400, { error: "unauthorized_client" } ])
      get admin_msgraph_path

      assert_select "[data-test='msgraph-section'][data-state='read_failed']"
      assert_select "[data-test='msgraph-read-error']", text: /not found in, or not enabled for, the tenant/
      log = ErrorLog.order(:id).last
      assert_equal "MsgraphConnection", log.target_type
      assert_no_match(/#{TENANT}/i, response.body)
    end
  end

  test "[integration] Disconnect deletes one tenant and its cached token and says how to revoke" do
    with_msgraph_env do
      kept = store_msgraph(tenant_id: OTHER_TENANT, display_name: "Kept Org")
      gone = store_msgraph
      msgraph_tokens
      Msgraph::OAuthClient.access_token(TENANT)
      Msgraph::OAuthClient.access_token(OTHER_TENANT)

      delete admin_msgraph_disconnect_path(gone, return_to: "/integrations")
      assert_redirected_to "/integrations"
      assert_response :see_other
      assert_equal [ kept ], MsgraphConnection.all.to_a
      assert_equal 1, Msgraph::OAuthClient.cached_count
      assert_match(/Synthetic Org: the stored connection was deleted here.*Enterprise applications/, flash[:notice])

      delete admin_msgraph_disconnect_path(gone)
      assert_equal "That tenant was not connected, so nothing changed.", flash[:notice]
    end
  end

  test "[integration] the callback's tenant is filtered from the request log, the Started GET line included" do
    path = "#{admin_msgraph_callback_path}?#{URI.encode_www_form(tenant: TENANT, state: 's', admin_consent: 'True')}"
    # The app's own env config carries the filter a real request logs with.
    request = ActionDispatch::Request.new(Rails.application.env_config.merge(Rack::MockRequest.env_for(path)))
    assert_not_includes request.filtered_path, TENANT, "the URL the request line prints"
    assert_includes request.filtered_path, "tenant=[FILTERED]"
    assert_includes request.filtered_path, "admin_consent=True" # the control: the line still prints the rest

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("controller" => "admin/msgraph", "tenant" => TENANT)["tenant"]
    nested = { "id" => "t-1", "name" => "Teams ingest" }
    assert_equal nested, filter.filter("tenant" => nested)["tenant"], "a nested tenant Hash (the Teams ingest) is spared"
  end

end
