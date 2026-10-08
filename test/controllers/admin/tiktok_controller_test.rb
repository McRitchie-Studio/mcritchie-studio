require "test_helper"
require "support/tiktok_oauth_fakes"

# [integration] /admin/tiktok/connect and its callback: the one-time sign-in
# that connects a TikTok account to the hub. TikTok is a stand-in throughout.
class Admin::TiktokControllerTest < ActionDispatch::IntegrationTest
  include TiktokOauthFakes

  setup { log_in_as users(:alex) }
  teardown { reset_tiktok_oauth }

  # Starts the handshake and returns the state TikTok would hand back.
  def begin_connect
    get admin_tiktok_connect_path
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  test "connect is admin only" do
    get logout_path
    get admin_tiktok_connect_path
    assert_response :redirect
    assert_no_match(/tiktok\.com/, response.location)
  end

  test "connect sends the admin to TikTok asking for drafts only" do
    with_tiktok_env("TIKTOK_SCOPES" => nil) do
      query = begin_connect

      assert_match %r{\Ahttps://www\.tiktok\.com/v2/auth/authorize/\?}, response.location
      assert_equal "user.info.basic,video.upload", query["scope"]
      assert_equal "test-client-key", query["client_key"]
      assert_equal admin_tiktok_callback_url, query["redirect_uri"]
    end
  end

  test "connect with keys absent says so in a flash and logs no error" do
    with_tiktok_env(creds: false) do
      assert_no_difference -> { ErrorLog.count } do
        get admin_tiktok_connect_path
      end

      assert_redirected_to admin_dashboard_path
      assert_equal "TikTok keys are not set on this server", flash[:alert]
    end
  end

  test "connect with an unknown scope in TIKTOK_SCOPES names it and logs no error" do
    with_tiktok_env("TIKTOK_SCOPES" => "user.info.basic,video.upload,video.everything") do
      assert_no_difference -> { ErrorLog.count } do
        get admin_tiktok_connect_path
      end

      assert_redirected_to admin_dashboard_path
      assert_includes flash[:alert], "video.everything"
    end
  end

  {
    "scope" => "The TikTok app lacks a permission this sign-in asked for",
    "redirect_uri" => "This callback address is not registered on the TikTok app",
    "client_key" => "TikTok does not accept this client key",
    "non_sandbox_target" => "The signed-in TikTok account is not a target user of the sandbox app",
    "access_denied" => "The sign-in was declined on TikTok"
  }.each do |code, sentence|
    test "callback explains TikTok's #{code} refusal in a plain sentence" do
      with_tiktok_env do
        state = begin_connect.fetch("state")
        assert_no_difference -> { ErrorLog.count } do
          get admin_tiktok_callback_path, params: { state:, error: code, error_description: "raw words" }
        end

        assert_response :bad_request
        assert_select "[data-tiktok-refusal]", text: /#{Regexp.escape(sentence)}/
        assert_select "[data-tiktok-refusal-code]", text: code
        assert_empty token_requests
      end
    end
  end

  test "callback names the scopes it asked for when TikTok refuses the scope" do
    with_tiktok_env("TIKTOK_SCOPES" => "user.info.basic,video.upload,video.publish") do
      state = begin_connect.fetch("state")
      get admin_tiktok_callback_path, params: { state:, error: "scope" }

      assert_select "[data-tiktok-refusal]", text: /user\.info\.basic, video\.upload, video\.publish/
    end
  end

  test "callback shows an unknown refusal in TikTok's own words, escaped" do
    with_tiktok_env do
      state = begin_connect.fetch("state")
      get admin_tiktok_callback_path,
          params: { state:, error: "<b>weird</b>", error_description: "<script>alert(1)</script> app paused" }

      assert_response :bad_request
      assert_not_includes response.body, "<script>alert(1)</script>"
      assert_not_includes response.body, "<b>weird</b>"
      assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt; app paused"
      assert_includes response.body, "&lt;b&gt;weird&lt;/b&gt;"
    end
  end

  test "callback refuses a state it did not issue" do
    with_tiktok_env do
      begin_connect
      get admin_tiktok_callback_path, params: { state: "forged", code: "c1" }

      assert_response :bad_request
      assert_match(/state mismatch/i, response.body)
      assert_empty token_requests
    end
  end

  test "callback shows the granted scope, the refresh token and the open id to file, and no access token" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      state = begin_connect.fetch("state")
      get admin_tiktok_callback_path, params: { state:, code: "code-1" }

      assert_response :success
      assert_equal "authorization_code", token_requests.last[:grant_type]
      assert_select "[data-tiktok-field='refresh-token']", text: "rft.test"
      assert_select "[data-tiktok-field='open-id']", text: "open-test"
      assert_select "[data-tiktok-field='scope']", text: "user.info.basic,video.upload"
      assert_select "[data-tiktok-grant]", text: /drafts only/i
      assert_not_includes response.body, "act.test"
      assert_includes response.body, "tiktok.studio.agents"
    end
  end

  test "callback says when the connection may also direct post" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload,video.publish")
      state = begin_connect.fetch("state")
      get admin_tiktok_callback_path, params: { state:, code: "code-1" }

      assert_select "[data-tiktok-grant]", text: /direct post/i
      assert_select "[data-tiktok-grant]", text: /drafts only/i, count: 0
    end
  end

  test "callback warns when the grant came back without the draft permission" do
    with_tiktok_env do
      tiktok_grants("user.info.basic")
      state = begin_connect.fetch("state")
      get admin_tiktok_callback_path, params: { state:, code: "code-1" }

      assert_response :success
      assert_select "[data-tiktok-grant]", text: /video\.upload was not granted/
    end
  end

  test "callback says so when TikTok cannot be reached, and logs no error" do
    with_tiktok_env do
      state = begin_connect.fetch("state")
      Net::HTTP.stub(:start, ->(*_args, **_opts) { raise SocketError, "getaddrinfo: nodename nor servname provided" }) do
        assert_no_difference -> { ErrorLog.count } do
          get admin_tiktok_callback_path, params: { state:, code: "code-1" }
        end
      end

      assert_response :bad_request
      assert_select "[data-tiktok-refusal]", text: /could not reach TikTok \(SocketError\)/
    end
  end

  test "callback reports a refused code exchange without a token and without an error log" do
    with_tiktok_env do
      tiktok_grants(nil, status: 400, body: JSON.generate(error: "invalid_grant", error_description: "Authorization code is expired."))
      state = begin_connect.fetch("state")
      assert_no_difference -> { ErrorLog.count } do
        get admin_tiktok_callback_path, params: { state:, code: "old" }
      end

      assert_response :bad_request
      assert_select "[data-tiktok-refusal]", text: /Authorization code is expired\./
    end
  end
end
