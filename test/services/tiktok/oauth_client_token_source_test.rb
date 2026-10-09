require "test_helper"

# [unit] Tiktok::OAuthClient: where the refresh token and the open id come from
# (the stored TiktokConnection first, the env pair second), and what a token
# refresh writes back. TikTok's token endpoint is a stand-in; every token is
# synthetic.
class Tiktok::OAuthClientTokenSourceTest < ActiveSupport::TestCase
  KEYS = %w[TIKTOK_CLIENT_KEY TIKTOK_CLIENT_SECRET TIKTOK_REFRESH_TOKEN TIKTOK_OPEN_ID].freeze
  STORED = "rft.synthetic-stored".freeze
  FROM_ENV = "rft.synthetic-from-env".freeze
  NOW = Time.utc(2026, 10, 8, 12, 0, 0)

  setup { @sent = [] }

  # Pins the four keys for the block; a nil removes one.
  def with_tiktok_env(pair: true, app: true)
    pins = { "TIKTOK_CLIENT_KEY" => app ? "synthetic-client-key" : nil, "TIKTOK_CLIENT_SECRET" => app ? "synthetic-client-secret" : nil,
             "TIKTOK_REFRESH_TOKEN" => pair ? FROM_ENV : nil, "TIKTOK_OPEN_ID" => pair ? "open-from-env" : nil }
    originals = KEYS.index_with { |k| ENV[k] }
    pins.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def connect(open_id: "open-stored", token: STORED, now: NOW)
    TiktokConnection.store!({ "open_id" => open_id, "refresh_token" => token, "scope" => "user.info.basic,video.upload",
                              "refresh_expires_in" => 1000 }, by: "alex", now:)
  end

  # TikTok answers every token request with `answer`, and @sent keeps the form
  # params each one carried. No request leaves the process.
  def tiktok_answers(answer = {}, &block)
    json = { "access_token" => "act.synthetic", "scope" => "user.info.basic,video.upload", "expires_in" => 86_400 }.merge(answer)
    endpoint = lambda do |params|
      @sent << params
      json
    end
    Tiktok::OAuthClient.stub(:post_token, endpoint, &block)
  end

  def with_memory_cache(&block) = Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)

  test "[unit] the stored connection beats the env pair" do
    connect
    with_tiktok_env do
      tiktok_answers { assert_equal "act.synthetic", Tiktok::OAuthClient.access_token }

      assert_equal [STORED], @sent.map { |p| p[:refresh_token] }
      assert_equal "refresh_token", @sent.first[:grant_type]
      assert_equal "open-stored", Tiktok::OAuthClient.open_id
      assert Tiktok::OAuthClient.token_source.stored?
    end
  end

  test "[unit] the env pair answers when no connection is stored" do
    with_tiktok_env do
      tiktok_answers { Tiktok::OAuthClient.access_token }

      assert_equal [FROM_ENV], @sent.map { |p| p[:refresh_token] }
      assert_equal "open-from-env", Tiktok::OAuthClient.open_id
      assert_not Tiktok::OAuthClient.token_source.stored?
    end
  end

  test "[unit] configured for either source, and never without the app's keys" do
    with_tiktok_env(pair: false) do
      assert_not Tiktok::OAuthClient.runtime_creds_present?, "neither a connection nor the env pair"
      assert_nil Tiktok::OAuthClient.token_source
    end
    with_tiktok_env(pair: true) { assert Tiktok::OAuthClient.runtime_creds_present?, "the env pair alone" }

    connect
    with_tiktok_env(pair: false) { assert Tiktok::OAuthClient.runtime_creds_present?, "a stored connection alone" }
    with_tiktok_env(pair: false, app: false) do
      assert_not Tiktok::OAuthClient.runtime_creds_present?, "a connection cannot refresh without the client key and secret"
    end
  end

  test "[unit] half an env pair is no source" do
    with_tiktok_env do
      ENV.delete("TIKTOK_OPEN_ID")
      assert_nil Tiktok::OAuthClient.token_source
      assert_not Tiktok::OAuthClient.runtime_creds_present?
    end
  end

  test "[unit] with nothing connected, the refusal names the sign-in and the open id is refused too" do
    with_tiktok_env(pair: false) do
      error = assert_raises(Tiktok::OAuthClient::NotConfigured) { tiktok_answers { Tiktok::OAuthClient.access_token } }
      assert_includes error.message, "/admin/tiktok/connect"
      assert_empty @sent
      assert_raises(Tiktok::OAuthClient::NotConfigured) { Tiktok::OAuthClient.open_id }
    end
  end

  test "[unit] a refresh token TikTok rotated replaces the stored one" do
    connection = connect
    with_tiktok_env(pair: false) do
      travel_to NOW + 1.day do
        tiktok_answers("refresh_token" => "rft.synthetic-rotated", "refresh_expires_in" => 500) { Tiktok::OAuthClient.access_token }
      end
    end

    connection.reload
    assert_equal "rft.synthetic-rotated", connection.refresh_token
    assert_equal NOW + 1.day, connection.refreshed_at
    assert_equal NOW + 1.day + 500, connection.refresh_expires_at

    # The next refresh sends the rotated token, not the one the sign-in stored.
    with_tiktok_env(pair: false) { tiktok_answers { Tiktok::OAuthClient.access_token } }
    assert_equal [STORED, "rft.synthetic-rotated"], @sent.map { |p| p[:refresh_token] }
  end

  test "[unit] the same refresh token back writes nothing" do
    connection = connect
    before = connection.updated_at
    with_tiktok_env(pair: false) do
      tiktok_answers("refresh_token" => STORED, "refresh_expires_in" => 500) { Tiktok::OAuthClient.access_token }
    end

    connection.reload
    assert_equal before, connection.updated_at
    assert_nil connection.refreshed_at
  end

  test "[unit] with the env pair as the source a rotated token is written nowhere" do
    with_tiktok_env do
      writes = []
      counter = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        tiktok_answers("refresh_token" => "rft.synthetic-rotated") { Tiktok::OAuthClient.access_token }
      end

      assert_empty writes
      assert_equal 0, TiktokConnection.count
      assert_equal FROM_ENV, ENV["TIKTOK_REFRESH_TOKEN"]
    end
  end

  test "[unit] the write counter sees a rotation on a stored connection (the control)" do
    connect
    with_tiktok_env do
      writes = []
      counter = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        tiktok_answers("refresh_token" => "rft.synthetic-rotated") { Tiktok::OAuthClient.access_token }
      end

      assert_equal 1, writes.size
      assert_match(/UPDATE "tiktok_connections"/, writes.first)
    end
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] an unreadable stored connection is not connected, says why, and the env pair does not stand in" do
    connect
    with_tiktok_env do # the env pair IS set
      assert Tiktok::OAuthClient.runtime_creds_present? # the control: readable, it is connected
      assert_nil Tiktok::OAuthClient.connection_problem

      with_other_encryption_key do
        assert_nil Tiktok::OAuthClient.token_source, "no fallback to the env pair behind a dead row"
        assert_not Tiktok::OAuthClient.runtime_creds_present?
        assert_not Tiktok::DraftClip.available?
        assert_equal "the stored TikTok connection cannot be read; sign in again at /admin/tiktok/connect",
                     Tiktok::OAuthClient.connection_problem
        assert_equal Tiktok::OAuthClient.connection_problem, Tiktok::DraftClip.unavailable_reason

        error = assert_raises(Tiktok::OAuthClient::NotConfigured) { tiktok_answers { Tiktok::OAuthClient.access_token } }
        assert_includes error.message, "cannot be read; sign in again"
        assert_raises(Tiktok::OAuthClient::NotConfigured) { Tiktok::OAuthClient.open_id }
        assert_empty @sent, "TikTok was not asked with the env pair's token"
      end
    end
  end

  test "[unit] once the unreadable row is deleted the env pair answers again" do
    connect
    with_tiktok_env do
      with_other_encryption_key do
        TiktokConnection.delete_all
        assert Tiktok::OAuthClient.runtime_creds_present?
        assert_not Tiktok::OAuthClient.token_source.stored?
      end
    end
  end

  test "[unit] a refresh that answers after a new sign-in does not overwrite the sign-in's token" do
    connection = connect
    with_tiktok_env(pair: false) do
      endpoint = lambda do |params|
        @sent << params
        connect(token: "rft.synthetic-new-sign-in", now: NOW + 1.hour) # the sign-in lands while TikTok is answering
        { "access_token" => "act.synthetic", "refresh_token" => "rft.synthetic-from-old-refresh" }
      end
      Tiktok::OAuthClient.stub(:post_token, endpoint) { Tiktok::OAuthClient.access_token }
    end

    assert_equal [STORED], @sent.map { |p| p[:refresh_token] }
    assert_equal "rft.synthetic-new-sign-in", connection.reload.refresh_token
  end

  # The four below go through the token endpoint's own stand-in (OAuthClient.http),
  # so the answer is parsed and checked exactly as TikTok's is.
  def tiktok_http(status: 200, **answer)
    Tiktok::OAuthClient.http = lambda do |params|
      @sent << params
      [status, JSON.generate(answer)]
    end
    yield
  ensure
    Tiktok::OAuthClient.http = nil
  end

  test "[unit] a rotated refresh token in TikTok's own answer is saved, not discarded" do
    connection = connect
    with_tiktok_env(pair: false) do
      tiktok_http(access_token: "act.synthetic", refresh_token: "rft.synthetic-rotated", scope: "user.info.basic,video.upload",
                  refresh_expires_in: 500) do
        assert_equal "act.synthetic", Tiktok::OAuthClient.access_token
      end
    end

    assert_equal [STORED], @sent.map { |p| p[:refresh_token] }
    assert_equal "rft.synthetic-rotated", connection.reload.refresh_token
  end

  test "[unit] a refresh answer with no scope still returns the access token; a direct post is refused" do
    connect
    with_tiktok_env(pair: false) do
      tiktok_http(access_token: "act.synthetic") do
        assert_equal "act.synthetic", Tiktok::OAuthClient.access_token, "drafts keep working"
        assert_empty Tiktok::OAuthClient.granted_scopes
        error = assert_raises(Tiktok::OAuthClient::MissingScope) { Tiktok::OAuthClient.ensure_direct_post! }
        assert_includes error.message, "video.publish"
      end
    end
  end

  test "[unit] a granted scope is split on commas and on whitespace" do
    connect
    with_tiktok_env(pair: false) do
      tiktok_http(access_token: "act.synthetic", scope: "user.info.basic video.upload,\n video.publish") do
        assert_equal %w[user.info.basic video.upload video.publish], Tiktok::OAuthClient.granted_scopes
        assert_nothing_raised { Tiktok::OAuthClient.ensure_direct_post! }
      end
      tiktok_http(access_token: "act.synthetic", scope: "user.info.basic video.upload") do
        assert_raises(Tiktok::OAuthClient::MissingScope) { Tiktok::OAuthClient.ensure_direct_post! }
      end
    end
    assert_equal %w[a b], TiktokConnection.new(scope: "a, b").scopes
  end

  test "[unit] a refusal prints TikTok's error only when it is a string, never a nested object" do
    connect
    with_tiktok_env(pair: false) do
      tiktok_http(status: 400, error: { refresh_token: "rft.synthetic-nested-leak" }, error_description: "Refresh token is invalid.") do
        error = assert_raises(Tiktok::OAuthClient::Error) { Tiktok::OAuthClient.access_token }
        assert_includes error.message, "Refresh token is invalid.", "the control: a string part is still printed"
        assert_not_includes error.message, "rft.synthetic-nested-leak"
        assert_not_includes error.message, "refresh_token"
      end
      tiktok_http(status: 400, error: ["rft.synthetic-nested-leak"], error_description: { "x" => "rft.synthetic-nested-leak" }) do
        error = assert_raises(Tiktok::OAuthClient::Error) { Tiktok::OAuthClient.access_token }
        assert_includes error.message, "TikTok gave no reason"
        assert_not_includes error.message, "rft.synthetic-nested-leak"
      end
    end
  end

  test "[unit] a rotation keeps the cached access token; a new sign-in drops it" do
    connect
    with_memory_cache do
      with_tiktok_env(pair: false) do
        tiktok_answers("refresh_token" => "rft.synthetic-rotated") do
          2.times { Tiktok::OAuthClient.access_token }
          assert_equal 1, @sent.size, "the rotated token did not rename the cache"

          connect(token: "rft.synthetic-second-sign-in", now: NOW + 1.day)
          Tiktok::OAuthClient.access_token
          assert_equal [STORED, "rft.synthetic-second-sign-in"], @sent.map { |p| p[:refresh_token] }
        end
      end
    end
  end

  test "[unit] a connection stored over the env pair is not answered from the env pair's cache" do
    with_memory_cache do
      with_tiktok_env do
        tiktok_answers do
          Tiktok::OAuthClient.access_token
          connect
          Tiktok::OAuthClient.access_token
        end
      end
    end

    assert_equal [FROM_ENV, STORED], @sent.map { |p| p[:refresh_token] }
  end
  # A Struct prints its members: without a mask, a console that echoed
  # Tiktok::OAuthClient.token_source would print the refresh token.
  test "[unit] a token source never prints its token: inspect, to_s, pp and string interpolation" do
    require "pp"
    stored = Tiktok::OAuthClient::TokenSource.new(STORED, "open-stored", connect)
    from_env = Tiktok::OAuthClient::TokenSource.new(FROM_ENV, "open-from-env", nil)

    { stored => STORED, from_env => FROM_ENV }.each do |source, token|
      printed = [source.inspect, source.to_s, "#{source}", source.pretty_inspect, [source].inspect, { source: }.inspect,
                 (raise "boom #{source.inspect}" rescue $ERROR_INFO.message)]
      printed.each do |text|
        assert_not_includes text, token
        assert_no_match(/rft\.|synthetic-(stored|from-env)/, text)
        assert_includes text, "refresh_token=[FILTERED]"
      end
    end

    assert_equal "#<Tiktok::OAuthClient::TokenSource env open_id=\"open-from-env\" refresh_token=[FILTERED]>", from_env.inspect
    assert_match(/\A#<Tiktok::OAuthClient::TokenSource connection=\d+ open_id="open-stored" refresh_token=\[FILTERED\]>\z/, stored.inspect)
    # The mask is only on what is printed: the client still reads the token.
    assert_equal STORED, stored.refresh_token
    assert_equal [FROM_ENV, "open-from-env", nil], from_env.to_a
  end

  # THE CONTROL: a plain Struct of the same shape does print it, which is what
  # the check above would catch.
  test "[unit] a Struct with no mask prints its token (the control)" do
    plain = Struct.new(:refresh_token, :open_id, :connection).new(FROM_ENV, "open-from-env", nil)

    assert_includes plain.inspect, FROM_ENV
  end

end
