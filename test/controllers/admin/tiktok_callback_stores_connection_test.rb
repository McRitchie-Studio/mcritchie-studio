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
    assert_select "[data-tiktok-refusal]", text: /TikTok answered, but the connection was not saved/
    assert_select "[data-tiktok-refusal]", text: /Refresh token can.t be blank/
    assert_not_includes response.body, ACCESS
  end

  test "[integration] the callback's page is never cached, stored or refused" do
    log_in_as users(:alex)
    finish_connect(answer)
    assert_equal "no-store", response.headers["Cache-Control"]

    finish_connect(answer(refresh_token: nil))
    assert_equal "no-store", response.headers["Cache-Control"]

    get admin_dashboard_path
    assert_not_equal "no-store", response.headers["Cache-Control"], "the control: another admin page is not no-store"
  end

  test "[integration] the auth code is filtered from the callback's logged parameters, and only there" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    logged = filter.filter("controller" => "admin/tiktok", "action" => "callback", "code" => "synthetic-code", "state" => "s1")
    assert_equal "[FILTERED]", logged["code"]
    assert_equal "s1", logged["state"]

    other = filter.filter("controller" => "tasks", "action" => "index", "code" => "synthetic-code")
    assert_equal "synthetic-code", other["code"], "the control: a code elsewhere is not masked"
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

  # Unsets this environment's fixed encryption keys for the block: production
  # as it stood on 2026-10-08. The real predicate reads the real config.
  def without_encryption_keys
    config = ActiveRecord::Encryption.config
    originals = [config.primary_key, config.key_derivation_salt]
    assert Fact.encryption_ready?, "the control: this environment has keys until they are unset"
    config.primary_key = nil
    config.key_derivation_salt = nil
    assert_not Fact.encryption_ready?, "the no-keys path is reached for real, with no stub"
    yield
  ensure
    config.primary_key, config.key_derivation_salt = originals
  end

  NAMES = /ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY, ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT/

  test "[integration] without encryption keys connect refuses before TikTok, naming the three keys, and logs no error" do
    log_in_as users(:alex)

    without_encryption_keys do
      assert_no_difference -> { ErrorLog.count } do
        get admin_tiktok_connect_path
      end

      assert_redirected_to admin_dashboard_path
      assert_no_match(/tiktok\.com/, response.location)
      assert_match NAMES, flash[:alert]
      assert_match(/cannot store a TikTok connection/, flash[:alert])
      assert_nil session[:tiktok_oauth_state], "no sign-in was started"
    end

    # The control: with the keys back, the same request does go to TikTok.
    get admin_tiktok_connect_path
    assert_match %r{\Ahttps://www\.tiktok\.com/}, response.location
  end

  test "[integration] without encryption keys the callback refuses before the exchange: no code spent, no row, no error log" do
    log_in_as users(:alex)
    state = begin_connect # the keys were lost between the redirect and the return

    without_encryption_keys do
      assert_no_difference [-> { ErrorLog.count }, -> { TiktokConnection.count }] do
        finish_connect(answer, state:)
      end

      assert_response :service_unavailable
      assert_empty @exchanges, "TikTok was not asked: the grant could not have been kept"
      assert_select "[data-tiktok-refusal]", text: /cannot store a TikTok connection/
      assert_select "[data-tiktok-refusal]", text: NAMES
      assert_select "[data-tiktok-refusal]", text: /Nothing was asked of TikTok/
    end

    # The control: with the keys back, the same walk exchanges the code and stores the row.
    assert_difference -> { TiktokConnection.count }, 1 do
      finish_connect(answer)
    end
    assert_equal 1, @exchanges.size
  end

  test "[integration] a state mismatch is still refused first, keys or no keys" do
    log_in_as users(:alex)
    begin_connect

    without_encryption_keys { finish_connect(answer, state: "forged") }

    assert_response :bad_request
    assert_empty @exchanges
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[integration] the connected page carries a confirmed Disconnect, and disconnecting deletes the connection" do
    log_in_as users(:alex)
    finish_connect(answer)

    assert_select "form[data-test='tiktok-disconnect'][action='#{admin_tiktok_disconnect_path}'][data-turbo-confirm]" do
      assert_select "input[name='_method'][value='delete']"
      assert_select "button", "Disconnect TikTok"
    end

    assert_difference -> { TiktokConnection.count }, -1 do
      delete admin_tiktok_disconnect_path
    end

    assert_redirected_to admin_tiktok_path
    assert_response :see_other # a Turbo form submission must be answered with a redirect
    assert_match(/TikTok disconnected: the stored connection was deleted/, flash[:notice])
    assert_match(/Drafting is off: TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID are not set/, flash[:notice])
    assert_nil flash[:alert]
    assert_not Tiktok::OAuthClient.runtime_creds_present?
    follow_redirect!
    assert_includes response.body, "TikTok disconnected: the stored connection was deleted"
    assert_not_includes response.body, REFRESH
  end

  test "[integration] disconnecting says plainly when the env pair is still set and drafting carries on from it" do
    log_in_as users(:alex)
    finish_connect(answer)
    ENV["TIKTOK_REFRESH_TOKEN"] = "rft.synthetic-env-NEVER-RENDERED"
    ENV["TIKTOK_OPEN_ID"] = "open-synthetic-env"

    delete admin_tiktok_disconnect_path

    assert_redirected_to admin_tiktok_path
    assert_match(/Drafting is still on: TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID are set on this server, and it drafts from them/,
                 flash[:notice])
    assert_nil flash[:alert], "the delete succeeded: an alert is a toast titled Error"
    follow_redirect!
    assert_includes response.body, "Drafting is still on"
    # The engine's toast is seeded from the flash by type, and only `alert` is titled "Error".
    toasts = JSON.parse(css_select("[data-toast-initial-value]").first["data-toast-initial-value"])
    assert_equal ["notice"], toasts.map { |toast| toast["type"] }
    assert_match(/TikTok disconnected.*Drafting is still on/, toasts.first["message"])
    assert_select "[data-test='tiktok-connection'][data-source='env']"
    assert_not_includes response.body, "rft.synthetic-env-NEVER-RENDERED"
    assert Tiktok::OAuthClient.runtime_creds_present?, "and it is true: the env pair now answers"
    assert_not Tiktok::OAuthClient.token_source.stored?
  end

  test "[integration] disconnecting with nothing stored deletes nothing and says so" do
    log_in_as users(:alex)

    delete admin_tiktok_disconnect_path

    assert_redirected_to admin_tiktok_path
    assert_match(/No TikTok connection was stored on this server, so nothing was deleted/, flash[:notice])
  end

  test "[integration] disconnect removes a connection that can no longer be read" do
    log_in_as users(:alex)
    finish_connect(answer)

    with_other_encryption_key do
      assert_difference -> { TiktokConnection.count }, -1 do
        delete admin_tiktok_disconnect_path
      end
      assert_redirected_to admin_tiktok_path
    end
  end

  test "[integration] a viewer and a visitor cannot disconnect" do
    log_in_as users(:alex)
    finish_connect(answer)
    get logout_path

    assert_no_difference -> { TiktokConnection.count } do
      delete admin_tiktok_disconnect_path
      assert_response :redirect

      log_in_as users(:viewer)
      delete admin_tiktok_disconnect_path
      assert_response :redirect
    end
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
