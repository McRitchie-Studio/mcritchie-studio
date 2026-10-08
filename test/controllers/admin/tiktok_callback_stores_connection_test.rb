require "test_helper"

# [integration] /admin/tiktok/callback stores the connection itself and renders
# no token. TikTok's code exchange is a stand-in; every token is synthetic.
class Admin::TiktokCallbackStoresConnectionTest < ActionDispatch::IntegrationTest
  REFRESH = "rft.synthetic-refresh-NEVER-RENDERED".freeze
  ACCESS = "act.synthetic-access-NEVER-RENDERED".freeze
  OPEN_ID = "open-synthetic-account-1".freeze
  KEYS = { "TIKTOK_CLIENT_KEY" => "synthetic-client-key", "TIKTOK_CLIENT_SECRET" => "synthetic-client-secret",
           "TIKTOK_REFRESH_TOKEN" => nil, "TIKTOK_OPEN_ID" => nil }.freeze

  setup do
    @originals = KEYS.keys.index_with { |k| ENV[k] }
    KEYS.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    @exchanges = []
  end

  teardown { @originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v } }

  def answer(**over)
    { "access_token" => ACCESS, "refresh_token" => REFRESH, "open_id" => OPEN_ID, "scope" => "user.info.basic,video.upload",
      "expires_in" => 86_400, "refresh_expires_in" => 31_536_000, "token_type" => "Bearer" }.merge(over.transform_keys(&:to_s))
  end

  # Starts the sign-in as the logged-in user and returns the state TikTok hands back.
  def begin_connect
    get admin_tiktok_connect_path
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query).fetch("state")
  end

  # Runs the callback with TikTok's code exchange answering `json`.
  def finish_connect(json, state: begin_connect)
    exchange = lambda do |code:, redirect_uri:|
      @exchanges << { code:, redirect_uri: }
      json
    end
    Tiktok::OAuthClient.stub(:exchange_code, exchange) do
      get admin_tiktok_callback_path, params: { state:, code: "synthetic-code" }
    end
  end

  test "[integration] the callback stores the connection, encrypted, under the admin who signed in" do
    log_in_as users(:alex)

    travel_to Time.utc(2026, 10, 8, 12, 0, 0) do
      assert_difference -> { TiktokConnection.count }, 1 do
        finish_connect(answer)
      end
    end

    assert_response :success
    assert_equal [{ code: "synthetic-code", redirect_uri: admin_tiktok_callback_url }], @exchanges
    connection = TiktokConnection.current
    assert_equal OPEN_ID, connection.open_id
    assert_equal REFRESH, connection.refresh_token
    assert_equal "user.info.basic,video.upload", connection.scope
    assert_equal users(:alex).reload.slug, connection.connected_by
    assert connection.connected_by.present?
    assert_equal Time.utc(2027, 10, 8, 12, 0, 0), connection.refresh_expires_at
    stored = TiktokConnection.connection.select_value("SELECT refresh_token FROM tiktok_connections")
    assert_not_includes stored, REFRESH
  end

  test "[integration] the page says it is connected and saved: the account, the scope, the expiry, and no token" do
    log_in_as users(:alex)
    travel_to(Time.utc(2026, 10, 8, 12, 0, 0)) { finish_connect(answer) }

    assert_response :success
    assert_select "[data-tiktok-connected] h1", text: /connected and saved/
    assert_select "[data-tiktok-field='account']", text: OPEN_ID
    assert_select "[data-tiktok-field='scope']", text: "user.info.basic,video.upload"
    assert_select "[data-tiktok-field='refresh-expires']", text: /October 8, 2027/

    assert_not_includes response.body, REFRESH
    assert_not_includes response.body, ACCESS
    assert_no_match(/rft\.|act\./, response.body)
    assert_no_match(/TIKTOK_REFRESH_TOKEN|TIKTOK_OPEN_ID|\.env/, response.body, "nothing on the page is to be copied")
    assert_select "pre", count: 0
    assert_no_match(/rft\.|act\./, flash.to_h.values.join(" "))
  end

  # The control for the test above: the same body check does see a token when
  # the answer carries one into something the page renders.
  test "[integration] the body check sees a token-shaped value the page does render (the control)" do
    log_in_as users(:alex)
    finish_connect(answer(scope: REFRESH))

    assert_response :success
    assert_includes response.body, REFRESH
  end

  test "[integration] signing the same account in again updates its row and the stored token" do
    log_in_as users(:alex)
    finish_connect(answer)

    assert_no_difference -> { TiktokConnection.count } do
      finish_connect(answer(refresh_token: "rft.synthetic-second", scope: "user.info.basic"))
    end

    assert_response :success
    connection = TiktokConnection.current
    assert_equal "rft.synthetic-second", connection.refresh_token
    assert_equal "user.info.basic", connection.scope
    assert_not_includes response.body, "rft.synthetic-second"
  end

  test "[integration] drafting is configured after the callback with no env pair set" do
    log_in_as users(:alex)
    assert_not Tiktok::OAuthClient.runtime_creds_present?

    finish_connect(answer)

    assert Tiktok::OAuthClient.runtime_creds_present?
    assert_equal OPEN_ID, Tiktok::OAuthClient.open_id
    assert Tiktok::DraftClip.available?
  end

  test "[integration] an answer with no refresh token stores nothing and says which field, with no token" do
    log_in_as users(:alex)

    assert_no_difference -> { TiktokConnection.count } do
      finish_connect(answer(refresh_token: nil))
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Refresh token can't be blank"
    assert_not_includes response.body, ACCESS
  end

  test "[integration] a state mismatch exchanges no code and stores nothing" do
    log_in_as users(:alex)
    begin_connect

    assert_no_difference -> { TiktokConnection.count } do
      finish_connect(answer, state: "not-the-state")
    end

    assert_response :bad_request
    assert_empty @exchanges
  end

  test "[integration] a signed-in viewer reaches neither action and stores nothing" do
    log_in_as users(:viewer)

    get admin_tiktok_connect_path
    assert_response :redirect
    assert_no_match(/tiktok\.com/, response.location)

    assert_no_difference -> { TiktokConnection.count } do
      finish_connect(answer, state: "any")
    end
    assert_response :redirect
    assert_empty @exchanges
  end

  test "[integration] a visitor with no session reaches neither action" do
    get admin_tiktok_connect_path
    assert_response :redirect
    assert_no_match(/tiktok\.com/, response.location)

    finish_connect(answer, state: "any")
    assert_response :redirect
    assert_empty @exchanges
    assert_equal 0, TiktokConnection.count
  end

  test "[integration] no sign-in stand-in is installed outside the e2e lane and a local demo" do
    assert_nil Tiktok::OAuthClient.sign_in_stand_in
  end

  test "[integration] the stand-in sign-in walks connect to a stored, named stand-in connection" do
    log_in_as users(:alex)
    Tiktok::OAuthClient.sign_in_stand_in = TiktokDraftStandIn::SignIn.new

    get admin_tiktok_connect_path
    assert_match(/\A#{Regexp.escape(admin_tiktok_callback_url)}\?code=stand-in-code&state=\h{32}\z/, response.location)
    follow_redirect!

    assert_response :success
    assert_select "[data-tiktok-field='account']", text: "stand-in-account"
    connection = TiktokConnection.current
    assert_match(/\Astand-in-refresh-\h{16}\z/, connection.refresh_token)
    assert_not_includes response.body, connection.refresh_token
    assert_no_match(/stand-in-(refresh|access)/, response.body)
  ensure
    Tiktok::OAuthClient.sign_in_stand_in = nil
  end

  test "[integration] nothing the callback logs holds a token" do
    log_in_as users(:alex)
    state = begin_connect
    log = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log))
    logger.level = Logger::DEBUG
    loggers = [ActionController::Base, ActiveRecord::Base, ActionView::Base]
    originals = loggers.map(&:logger)

    sql = []
    subscriber = ->(*, payload) { sql << [payload[:sql], Array(payload[:type_casted_binds]).join(" ")].join(" ") }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      assert_no_difference -> { ErrorLog.count } do
        loggers.each { |owner| owner.logger = logger }
        Rails.stub(:logger, logger) { finish_connect(answer, state:) }
      ensure
        loggers.zip(originals) { |owner, original| owner.logger = original }
      end
    end

    assert_response :success
    assert_includes log.string, %(INSERT INTO "tiktok_connections"), "the control: the log did record the write"
    assert_includes log.string, "Admin::TiktokController#callback", "the control: and the request"
    assert_not_includes log.string, REFRESH
    assert_not_includes log.string, ACCESS
    assert(sql.any? { |line| line.include?(%(INSERT INTO "tiktok_connections")) }, "the control: the subscriber saw the insert")
    assert(sql.none? { |line| line.include?(REFRESH) }, "the insert binds ciphertext, not the token")
  end
end
