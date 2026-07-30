require "openssl"
require "time"
require "test_helper"

class Github::AppTokenTest < ActiveSupport::TestCase
  # Mirrors the FakeResponse in Github::ClientTest: a Net::HTTPResponse stand-in
  # the injected executor returns, so no test ever touches real GitHub.
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key)
      headers[key] || headers[key.to_s.downcase]
    end
  end

  setup do
    # A real RSA key so the RS256 JWT is genuinely signed (the mint path is
    # exercised end to end); only the network edge is stubbed.
    @rsa_pem = OpenSSL::PKey::RSA.new(2048).to_pem
    @cache = ActiveSupport::Cache::MemoryStore.new
    @now = Time.utc(2026, 7, 30, 12, 0, 0)
    @installations_calls = 0
    @mint_calls = 0
  end

  # An executor answering the two App endpoints and counting how many tokens it
  # mints, so a test can prove a token was reused (0 extra mints) vs. refreshed.
  def app_executor
    lambda do |uri, _request|
      case uri.path
      when "/app/installations"
        @installations_calls += 1
        FakeResponse.new(
          "200",
          JSON.generate([{ "id" => 4242, "account" => { "login" => "McRitchie-Studio" } }]),
          { "x-ratelimit-remaining" => "50" }
        )
      when %r{\A/app/installations/\d+/access_tokens\z}
        @mint_calls += 1
        FakeResponse.new(
          "201",
          JSON.generate({ "token" => "ghs_minted_#{@mint_calls}", "expires_at" => (@now + 1.hour).iso8601 }),
          { "x-ratelimit-remaining" => "50" }
        )
      else
        raise "unexpected GitHub path in test: #{uri.path}"
      end
    end
  end

  def build(**overrides)
    executor = overrides.delete(:executor) || app_executor
    Github::AppToken.new(
      app_id: "123456",
      private_key_pem: @rsa_pem,
      fallback_token: "ghp_static_fallback",
      cache: @cache,
      logger: nil,
      now: -> { @now },
      # sleeper no-op so the Client's retry backoff never really sleeps in tests.
      client_factory: ->(jwt) { Github::Client.new(token: jwt, logger: nil, executor: executor, sleeper: ->(_s) { }) },
      **overrides
    )
  end

  test "[unit] mint returns an installation token via the JWT installation flow" do
    token = build.resolve

    assert_equal "ghs_minted_1", token
    assert_equal 1, @installations_calls, "should resolve the installation once"
    assert_equal 1, @mint_calls, "should mint exactly one installation token"
  end

  test "[unit] caches and reuses the minted token within its TTL" do
    first = build.resolve
    # A DIFFERENT AppToken instance sharing the same cache — models two
    # per-request Github::Client instances hitting the same board process.
    second = build.resolve

    assert_equal "ghs_minted_1", first
    assert_equal first, second
    assert_equal 1, @mint_calls, "the cached token must be reused, not re-minted"
  end

  test "[unit] refreshes the token after it nears expiry" do
    build.resolve
    assert_equal 1, @mint_calls

    # Advance to inside the 10-minute refresh skew of the 1-hour expiry.
    @now += 51.minutes
    refreshed = build.resolve

    assert_equal "ghs_minted_2", refreshed, "a fresh token should be minted near expiry"
    assert_equal 2, @mint_calls
  end

  test "[unit] falls back to GITHUB_TOKEN when App creds are absent" do
    subject = Github::AppToken.new(
      app_id: nil,
      private_key_pem: nil,
      fallback_token: "ghp_static_fallback",
      cache: @cache,
      logger: nil,
      now: -> { @now },
      client_factory: ->(_jwt) { raise "must not mint when App creds are absent" }
    )

    assert_not subject.configured?
    assert_equal "ghp_static_fallback", subject.resolve
    assert_equal 0, @mint_calls
  end

  test "[unit] reads the ENV contract for app id, private key, and fallback token" do
    with_env("GITHUB_APP_ID", "999") do
      with_env("GITHUB_APP_PRIVATE_KEY", @rsa_pem) do
        assert Github::AppToken.new.configured?, "configured? must read GITHUB_APP_ID + GITHUB_APP_PRIVATE_KEY"
      end
    end

    with_env("GITHUB_APP_ID", nil) do
      with_env("GITHUB_APP_PRIVATE_KEY", nil) do
        with_env("GITHUB_TOKEN", "ghp_env_static") do
          assert_equal "ghp_env_static", Github::AppToken.resolve(cache: @cache),
            "with no App creds, resolve returns the static GITHUB_TOKEN"
        end
      end
    end
  end

  test "[unit] a failed refresh reuses the still-unexpired cached token before falling back" do
    build.resolve
    assert_equal 1, @mint_calls

    # Inside the refresh skew, but still before the hard 1h expiry: a mint that
    # blows up must return the cached token, not crash the board.
    @now += 51.minutes
    failing = build(executor: ->(_uri, _request) { raise "GitHub is down" })

    assert_equal "ghs_minted_1", failing.resolve
  end

  test "[integration] the minted token authenticates a board check-runs request" do
    minted = build.resolve
    assert_equal "ghs_minted_1", minted

    captured = nil
    downstream = Github::Client.new(
      token: minted,
      logger: nil,
      executor: lambda do |_uri, request|
        captured = request
        FakeResponse.new("200", JSON.generate({ "check_runs" => [] }), { "x-ratelimit-remaining" => "50" })
      end
    )

    downstream.get("repos/McRitchie-Studio/mcritchie-industries/commits/abc123/check-runs")

    assert_equal "Bearer ghs_minted_1", captured["Authorization"],
      "the minted App token must authenticate the private-repo check-runs read"
  end
end
