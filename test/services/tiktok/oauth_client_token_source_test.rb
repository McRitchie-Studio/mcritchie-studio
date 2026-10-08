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
end
