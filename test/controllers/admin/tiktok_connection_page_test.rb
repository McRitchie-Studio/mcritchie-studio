require "test_helper"

# [integration] /admin/tiktok, the standing TikTok connection page: who may see
# it, what it says in each state the server can be in (a stored connection, a
# stored one that cannot be read, the fallback env pair, nothing), that it
# offers Sign in and Disconnect, and that it renders no token, no part of one
# and no env value. Nothing here reaches TikTok; every token is synthetic.
class Admin::TiktokConnectionPageTest < ActionDispatch::IntegrationTest
  REFRESH = "rft.synthetic-refresh-NEVER-RENDERED".freeze
  ENV_REFRESH = "rft.synthetic-env-NEVER-RENDERED".freeze
  ENV_OPEN_ID = "open-synthetic-env-NEVER-RENDERED".freeze
  OPEN_ID = "open-synthetic-account-1".freeze
  KEYS = { "TIKTOK_CLIENT_KEY" => "synthetic-client-key-NEVER-RENDERED", "TIKTOK_CLIENT_SECRET" => "synthetic-client-secret-NEVER-RENDERED",
           "TIKTOK_REFRESH_TOKEN" => nil, "TIKTOK_OPEN_ID" => nil }.freeze
  NOW = Time.utc(2026, 10, 8, 12, 0, 0)

  setup do
    @originals = KEYS.keys.index_with { |k| ENV[k] }
    KEYS.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  teardown { @originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v } }

  # A user's slug is written when they first sign in, so it is read after log_in_as.
  def admin_slug = users(:alex).reload.slug.presence || flunk("the admin has no slug yet: log in first")

  def connect(**over)
    grant = { "refresh_token" => REFRESH, "open_id" => OPEN_ID, "scope" => "user.info.basic,video.upload",
              "refresh_expires_in" => 31_536_000 }.merge(over.transform_keys(&:to_s))
    TiktokConnection.store!(grant, by: "synthetic-admin", now: NOW)
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  def without_encryption_keys
    config = ActiveRecord::Encryption.config
    originals = [config.primary_key, config.key_derivation_salt]
    config.primary_key = nil
    config.key_derivation_salt = nil
    assert_not Fact.encryption_ready?, "the no-keys path is reached for real, with no stub"
    yield
  ensure
    config.primary_key, config.key_derivation_salt = originals
  end

  # Every secret this test plants, none of which the page may carry.
  def assert_no_secret_in(body)
    [REFRESH, ENV_REFRESH, ENV_OPEN_ID, *KEYS.values.compact].each { |secret| assert_not_includes body, secret }
    assert_no_match(/rft\.|act\./, body)
    # Nothing on the page is a value to copy.
    assert_select "[data-test='tiktok-connection'] pre, [data-test='tiktok-connection'] input[type='text'], [data-test='tiktok-connection'] textarea", count: 0
  end

  test "[integration] admin TikTok connection page is admin gated and shows state" do
    connect

    get admin_tiktok_path
    assert_response :redirect, "a visitor is sent away"
    assert_no_match(/tiktok-connection/, response.body)

    log_in_as users(:viewer)
    get admin_tiktok_path
    assert_redirected_to root_path
    follow_redirect!
    assert_not_includes response.body, OPEN_ID, "a signed-in viewer sees nothing of the connection"

    get logout_path
    log_in_as users(:alex)
    get admin_tiktok_path
    assert_response :success
    assert_select "[data-test='tiktok-connection'][data-source='stored']"
    assert_select "[data-test='tiktok-status-badge']", text: "Connected"
    assert_select "[data-test='tiktok-status-detail']", text: /Drafts only/
    assert_select "[data-tiktok-field='account']", text: OPEN_ID
    assert_select "[data-tiktok-field='scope']", text: "user.info.basic,video.upload"
    assert_select "[data-tiktok-field='connected']", text: /October 8, 2026 at 12:00 UTC by synthetic-admin/
    assert_select "[data-tiktok-field='refresh-expires']", text: /October 8, 2027/
    assert_select "[data-tiktok-field='readable'][data-readable='true']", text: /Readable/
    assert_select "[data-tiktok-field='env-pair'][data-set='false']", text: /TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID:\s+not set/
    assert_select "[data-tiktok-field='app-keys'][data-set='true']", text: /TIKTOK_CLIENT_KEY and TIKTOK_CLIENT_SECRET:\s+set/
    assert_select "[data-tiktok-field='encryption'][data-ready='true']", text: /Ready/
    assert_select "a[data-test='tiktok-sign-in'][href='#{admin_tiktok_connect_path}'][data-turbo='false']", text: "Sign in again"
    assert_select "form[data-test='tiktok-disconnect'][action='#{admin_tiktok_disconnect_path}'][data-turbo-confirm]" do
      assert_select "input[name='_method'][value='delete']"
      assert_select "button", "Disconnect TikTok"
    end
    assert_no_secret_in response.body
  end

  # The control for every "no secret" check here: the same check does see a
  # token-shaped value when one reaches something the page renders.
  test "[integration] the page's secret check sees a token-shaped value the page does render (the control)" do
    connect(scope: REFRESH)
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_response :success
    assert_includes response.body, REFRESH
  end

  test "[integration] the display name is the account when the row has one" do
    connect.update!(display_name: "Synthetic Show")
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_select "[data-tiktok-field='account']", text: "Synthetic Show"
  end

  test "[integration] not connected: the page says so, offers Sign in, and has nothing to disconnect" do
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_response :success
    assert_select "[data-test='tiktok-connection'][data-source='none']"
    assert_select "[data-test='tiktok-status-badge']", text: "Not connected"
    assert_select "[data-test='tiktok-stored']", count: 0
    assert_select "a[data-test='tiktok-sign-in'][href='#{admin_tiktok_connect_path}']", text: "Sign in with TikTok"
    assert_select "form[data-test='tiktok-disconnect']", count: 0
    assert_select "[data-test='tiktok-disconnect-card']", text: /Nothing is stored here to delete/
    assert_no_secret_in response.body
  end

  test "[integration] the env pair, with no stored connection: named as the source, by name and never by value" do
    ENV["TIKTOK_REFRESH_TOKEN"] = ENV_REFRESH
    ENV["TIKTOK_OPEN_ID"] = ENV_OPEN_ID
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_select "[data-test='tiktok-connection'][data-source='env']"
    assert_select "[data-test='tiktok-status-badge']", text: "Connected from the server's config"
    assert_select "[data-tiktok-field='env-pair'][data-set='true']", text: /TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID:\s+set/
    assert_select "[data-test='tiktok-stored']", count: 0
    assert_select "form[data-test='tiktok-disconnect']", count: 0
    assert_select "[data-test='tiktok-disconnect-card']", text: /remove\s+TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID from the server's config/
    assert_no_secret_in response.body
    assert Tiktok::OAuthClient.token_source, "and it is true: the env pair answers"
  end

  test "[integration] half an env pair is not a pair" do
    ENV["TIKTOK_REFRESH_TOKEN"] = ENV_REFRESH
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_select "[data-test='tiktok-connection'][data-source='none']"
    assert_select "[data-tiktok-field='env-pair'][data-set='false']"
    assert_no_secret_in response.body
  end

  test "[integration] a stored connection is the source even with the env pair set, and the page says the pair is set too" do
    connect
    ENV["TIKTOK_REFRESH_TOKEN"] = ENV_REFRESH
    ENV["TIKTOK_OPEN_ID"] = ENV_OPEN_ID
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_select "[data-test='tiktok-connection'][data-source='stored']"
    assert_select "[data-tiktok-field='env-pair'][data-set='true']"
    assert_select "[data-test='tiktok-disconnect-card']", text: /Drafting then carries on from the pair/
    assert_no_secret_in response.body
  end

  test "[integration] a stored connection that cannot be read counts as not connected, and can be disconnected or replaced" do
    connect
    ENV["TIKTOK_REFRESH_TOKEN"] = ENV_REFRESH
    ENV["TIKTOK_OPEN_ID"] = ENV_OPEN_ID
    log_in_as users(:alex)

    with_other_encryption_key do
      get admin_tiktok_path

      assert_response :success
      assert_select "[data-test='tiktok-connection'][data-source='unreadable']"
      assert_select "[data-test='tiktok-status-badge']", text: /Not connected: the stored connection cannot be read/
      assert_select "[data-tiktok-field='readable'][data-readable='false']", text: /Cannot be read/
      assert_select "[data-tiktok-field='account']", text: OPEN_ID
      assert_select "a[data-test='tiktok-sign-in']", text: "Sign in again"
      assert_select "form[data-test='tiktok-disconnect']"
      assert_nil Tiktok::OAuthClient.token_source, "and it is true: the env pair does not stand in for it"
    end
    assert_no_secret_in response.body
  end

  test "[integration] without encryption keys the page says so by name and offers no sign-in" do
    log_in_as users(:alex)

    without_encryption_keys { get admin_tiktok_path }

    assert_response :success
    assert_select "[data-tiktok-field='encryption'][data-ready='false']",
                  text: /ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY, ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT/
    assert_select "a[data-test='tiktok-sign-in']", count: 0
    assert_select "[data-test='tiktok-sign-in-card']", text: /Off until this server's encryption keys are set/
  end

  test "[integration] without the app's keys the page names them and offers no sign-in" do
    ENV.delete("TIKTOK_CLIENT_KEY")
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_select "[data-tiktok-field='app-keys'][data-set='false']"
    assert_select "a[data-test='tiktok-sign-in']", count: 0
    assert_select "[data-test='tiktok-sign-in-card']", text: /Off until\s+TIKTOK_CLIENT_KEY and TIKTOK_CLIENT_SECRET are set/
  end

  # THE PAGE AND THE CLIP CARD ANSWER FROM ONE PREDICATE. An account with the
  # app's two keys missing cannot draft (the clip card says not connected), so
  # the page must not open on a green "Connected".
  test "[integration] a stored connection without the app keys reads drafting off, as the clip card does" do
    connect
    log_in_as users(:alex)

    get admin_tiktok_path
    assert_select "[data-test='tiktok-connection'][data-drafting='true']" # the control: keys set
    assert_select "[data-test='tiktok-status-badge']", text: "Connected"

    ENV.delete("TIKTOK_CLIENT_SECRET")
    get admin_tiktok_path

    assert_not Tiktok::DraftClip.available?, "the clip card's verdict"
    assert_select "[data-test='tiktok-connection'][data-source='stored'][data-drafting='false']"
    assert_select "[data-test='tiktok-status-badge']", text: "Drafting is off: the TikTok app keys are not set"
    assert_select "[data-test='tiktok-status-detail']", text: /cannot draft to it until\s+TIKTOK_CLIENT_KEY and TIKTOK_CLIENT_SECRET\s+are set/
    assert_select "[data-test='tiktok-status']", text: /Connected|can upload to the TikTok inbox/, count: 0
    assert_select "[data-tiktok-field='account']", text: OPEN_ID
    assert_no_secret_in response.body
  end

  test "[integration] the env pair without the app keys reads drafting off too" do
    ENV["TIKTOK_REFRESH_TOKEN"] = ENV_REFRESH
    ENV["TIKTOK_OPEN_ID"] = ENV_OPEN_ID
    ENV.delete("TIKTOK_CLIENT_KEY")
    log_in_as users(:alex)

    get admin_tiktok_path

    assert_not Tiktok::DraftClip.available?
    assert_select "[data-test='tiktok-connection'][data-source='env'][data-drafting='false']"
    assert_select "[data-test='tiktok-status-badge']", text: "Drafting is off: the TikTok app keys are not set"
    assert_select "[data-test='tiktok-status']", text: /Connected/, count: 0
    assert_no_secret_in response.body
  end

  test "[integration] with a stand-in for TikTok the keys are not needed, and the page says connected" do
    connect
    ENV.delete("TIKTOK_CLIENT_KEY")
    log_in_as users(:alex)
    uploader = Tiktok::DraftClip.uploader
    Tiktok::DraftClip.uploader = TiktokDraftStandIn::Uploader.new
    Tiktok::OAuthClient.sign_in_stand_in = TiktokDraftStandIn::SignIn.new

    get admin_tiktok_path

    assert Tiktok::DraftClip.available?
    assert_select "[data-test='tiktok-connection'][data-drafting='true']"
    assert_select "[data-test='tiktok-status-badge']", text: "Connected"
  ensure
    Tiktok::DraftClip.uploader = uploader
    Tiktok::OAuthClient.sign_in_stand_in = nil
  end

  # A stored row and no encryption keys: Sign in is off, so nothing on the page
  # may tell the admin to sign in again as if that were possible.
  test "[integration] a stored connection with no encryption keys says to set the keys first, wherever it spoke of signing in" do
    connect
    log_in_as users(:alex)
    names = /ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY, ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT/

    # The row was stored under keys this server no longer holds, and it holds
    # none now (this environment caches its key provider, so both are staged).
    with_other_encryption_key { without_encryption_keys { get admin_tiktok_path } }

    assert_response :success
    assert_select "[data-test='tiktok-connection'][data-source='unreadable']"
    assert_select "[data-tiktok-field='encryption'][data-ready='false']"
    assert_select "a[data-test='tiktok-sign-in']", count: 0
    assert_select "[data-test='tiktok-status-detail']", text: /Set this server's encryption keys first\s+\(#{names.source}\), then sign in again to replace it/
    assert_select "[data-test='tiktok-status-detail']", text: /\. Sign in again to replace it/, count: 0
    assert_select "[data-test='tiktok-disconnect-card']", text: /Connecting it back needs this server's encryption keys set first\s+\(#{names.source}\), then a sign-in/
    assert_select "[data-test='tiktok-disconnect-card']", text: /Signing in again connects it back/, count: 0
    assert_select "form[data-test='tiktok-disconnect']"
  end

  test "[integration] a refresh token past its expiry is said to be expired" do
    connect
    log_in_as users(:alex)

    travel_to(NOW + 2.years) { get admin_tiktok_path }

    assert_select "[data-tiktok-field='refresh-expires']", text: /Expired October 8, 2027/
  end

  test "[integration] Disconnect lands back on the page, which then says not connected, and the log names who and when" do
    connect
    log_in_as users(:alex)
    lines = []
    recorder = ->(message = nil, &blk) { lines << (message || blk&.call).to_s }

    travel_to NOW + 1.hour do
      Rails.logger.stub(:info, recorder) do
        assert_difference -> { TiktokConnection.count }, -1 do
          delete admin_tiktok_disconnect_path
        end
      end
    end

    assert_redirected_to admin_tiktok_path
    assert_response :see_other
    audit = lines.grep(/\A\[tiktok\] disconnect /)
    assert_equal ["[tiktok] disconnect by=#{admin_slug} at=2026-10-08T13:00:00Z deleted=1 env_pair=unset"], audit
    assert_no_match(/rft\.|#{Regexp.escape(OPEN_ID)}/, audit.first)

    follow_redirect!
    assert_response :success
    assert_select "[data-test='tiktok-connection'][data-source='none']"
    assert_includes response.body, "TikTok disconnected: the stored connection was deleted"
    assert_select "form[data-test='tiktok-disconnect']", count: 0
    assert_no_secret_in response.body
  end

  test "[integration] a refused disconnect writes no audit line" do
    connect
    log_in_as users(:viewer)
    lines = []
    recorder = ->(message = nil, &blk) { lines << (message || blk&.call).to_s }

    Rails.logger.stub(:info, recorder) do
      assert_no_difference -> { TiktokConnection.count } do
        delete admin_tiktok_disconnect_path
      end
    end

    assert_empty lines.grep(/\[tiktok\] disconnect/)
  end

  test "[integration] the sign-in's connected page links to the standing page" do
    log_in_as users(:alex)
    Tiktok::OAuthClient.sign_in_stand_in = TiktokDraftStandIn::SignIn.new

    get admin_tiktok_connect_path
    follow_redirect!

    assert_response :success
    assert_select "a[data-test='tiktok-connection-link'][href='#{admin_tiktok_path}']"

    get admin_tiktok_path
    assert_select "[data-test='tiktok-connection'][data-source='stored']"
    assert_select "[data-tiktok-field='account']", text: "stand-in-account"
    assert_select "[data-tiktok-field='stand-in']", text: /stand-in answers for TikTok/
    assert_no_match(/stand-in-(refresh|access)/, response.body)
  ensure
    Tiktok::OAuthClient.sign_in_stand_in = nil
  end

  test "[integration] the admin links hub lists the standing page, not the sign-in redirect" do
    log_in_as users(:alex)

    get admin_links_path

    assert_select "a[href='#{admin_tiktok_path}']", text: /TikTok connection/
    assert_select "a[href='#{admin_tiktok_connect_path}']", count: 0
  end
end
