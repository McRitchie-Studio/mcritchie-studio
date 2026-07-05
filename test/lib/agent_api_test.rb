# frozen_string_literal: true

# Tests for bin/lib/agent_api.rb — the shared agent-API client (token mint +
# on-disk cache + bearer HTTP + base_url) that bin/atomic-event,
# bin/atomic-capture-hook and bin/session-insights collapse onto.
#   ruby -Itest test/lib/agent_api_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (library shape):
#   [unit]        base_url / projects_dir / present? resolution, the token-cache
#                 read/expiry/invalidations, the secret ENV precedence, and the
#                 PINNED per-script timeout divergence (2/5 · 2/4 · 1/2).
#   [integration] the client against a localhost stub — mint writes the SHARED
#                 cache once, a second client reuses it without re-minting; the
#                 bearer/JSON request shape; unreachable endpoints degrade to nil.
#
# NOTE: `require` (not `load`) — the bin scripts require_relative this same file,
# so a `load` here would re-execute it and spray constant-redefinition warnings
# when the whole sweep runs in one process.

require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require "fileutils"
require "time"

require File.expand_path("../../bin/lib/agent_api", __dir__)

class AgentApiTest < Minitest::Test
  # NOTE: no keyword params here — a trailing `"KEY" => "v"` hash must stay the
  # positional env, not get captured as keywords. Timeouts stay short (1s/1s).
  def client(env = {})
    AgentApi.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env),
                 open_timeout: 1, read_timeout: 1)
  end

  # ── [unit] base_url ─────────────────────────────────────────────────────────

  def test_unit_base_url_defaults_to_localhost_3000
    assert_equal "http://localhost:3000", client.base_url
    assert_equal "http://localhost:3000", client("ATOMIC_CAPTURE_URL" => "  ").base_url
  end

  def test_unit_base_url_honors_atomic_capture_url
    assert_equal "https://mcritchie.studio",
                 client("ATOMIC_CAPTURE_URL" => " https://mcritchie.studio ").base_url
  end

  # ── [unit] present? (the shared blank-check the scripts delegate to) ────────

  def test_unit_present_semantics
    c = client
    refute c.present?(nil)
    refute c.present?(false)
    refute c.present?("   ")
    refute c.present?("")
    assert c.present?("x")
    assert c.present?(0), "0 is a value, not blank"
    assert c.present?(true)
  end

  # ── [unit] projects_dir ──────────────────────────────────────────────────────

  def test_unit_projects_dir_honors_claude_projects_dir_expanded
    Dir.mktmpdir do |proj|
      assert_equal File.expand_path(proj), client("CLAUDE_PROJECTS_DIR" => proj).projects_dir
    end
  end

  def test_unit_token_cache_lives_in_the_shared_atomic_capture_path
    Dir.mktmpdir do |proj|
      c = client("CLAUDE_PROJECTS_DIR" => proj)
      assert_equal File.join(File.expand_path(proj), ".agents", "atomic-capture", "token.json"),
                   c.send(:token_cache_path),
                   "the WHOLE stack shares this one cache file — moving it breaks the mint-once contract"
    end
  end

  # ── [unit] token cache read / expiry / invalidation ─────────────────────────

  def test_unit_token_returns_the_unexpired_cached_token_without_network
    Dir.mktmpdir do |proj|
      write_token_cache(proj, "token" => "cached-tok",
                              "expires_at" => (Time.now + 3600).utc.iso8601)
      # A dead endpoint proves the cache path never touches the network.
      c = client("CLAUDE_PROJECTS_DIR" => proj, "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1")
      assert_equal "cached-tok", c.token
    end
  end

  def test_unit_token_within_the_refresh_margin_is_not_reused
    Dir.mktmpdir do |proj|
      # Expires inside the 300s refresh margin → treated as stale → re-mint
      # (which fails here: dead endpoint) → nil, never the stale token.
      write_token_cache(proj, "token" => "stale-tok",
                              "expires_at" => (Time.now + 60).utc.iso8601)
      c = client("CLAUDE_PROJECTS_DIR" => proj,
                 "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1",
                 "AGENT_API_SECRET" => "s3cret")
      assert_nil c.token, "a token inside the refresh margin must not be reused"
    end
  end

  def test_unit_invalidate_token_drops_the_cache
    Dir.mktmpdir do |proj|
      write_token_cache(proj, "token" => "cached-tok",
                              "expires_at" => (Time.now + 3600).utc.iso8601)
      c = client("CLAUDE_PROJECTS_DIR" => proj,
                 "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1",
                 "AGENT_API_SECRET" => "s3cret")
      assert_equal "cached-tok", c.token
      c.invalidate_token!
      refute File.file?(c.send(:token_cache_path)), "invalidate_token! deletes the cache file"
      assert_nil c.token, "after invalidation the client re-mints (and here the endpoint is dead)"
    end
  end

  # ── [unit] secret order: ENV first ───────────────────────────────────────────

  def test_unit_agent_secret_prefers_the_env_verbatim
    assert_equal "from-env", client("AGENT_API_SECRET" => "from-env").send(:agent_secret)
  end

  # ── [unit] the scripts keep their DIVERGENT timeouts ─────────────────────────
  # The one real behavioral difference between the three scripts is how long they
  # will wait (the PostToolUse hook fires on every tool call → tightest). The
  # extraction parameterized it; this pins each script's original numbers.

  def test_unit_each_script_keeps_its_original_timeouts
    load_bin("atomic-event") unless defined?(AgentActivityCli)
    load_bin("session-insights") unless defined?(SessionInsights)
    load_bin("atomic-capture-hook") unless defined?(AtomicCaptureHook)

    assert_equal [2, 5], timeouts_of(AgentActivityCli.new(env: {})), "bin/atomic-event: open 2s / read 5s"
    assert_equal [2, 4], timeouts_of(SessionInsights.new(env: {})), "bin/session-insights: open 2s / read 4s"
    assert_equal [1, 2], timeouts_of(AtomicCaptureHook.new(env: {})), "bin/atomic-capture-hook: open 1s / read 2s"
  end

  # ── [integration] mint once, shared cache, request shape ─────────────────────

  def test_integration_token_mints_once_and_a_second_client_reuses_the_cache
    Dir.mktmpdir do |proj|
      with_stub_server do |port, requests|
        env = { "CLAUDE_PROJECTS_DIR" => proj,
                "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}",
                "AGENT_API_SECRET" => "s3cret" }

        assert_equal "stub-token", client(env).token, "first client mints"
        assert_equal "stub-token", client(env).token, "a FRESH client reuses the shared disk cache"

        auths = requests.select { |r| r[:path] == "/api/v1/auth" }
        assert_equal 1, auths.size, "exactly one mint — the cache serves the second client"
        assert_equal({ "secret" => "s3cret" }, JSON.parse(auths.first[:body]))
        assert File.file?(File.join(proj, ".agents", "atomic-capture", "token.json")),
               "the mint wrote the shared cache file"
      end
    end
  end

  def test_integration_http_json_sends_bearer_and_json_body
    Dir.mktmpdir do |proj|
      with_stub_server do |port, requests|
        c = client("CLAUDE_PROJECTS_DIR" => proj, "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}")
        res = c.http_json(:post, "/api/v1/agent_activities", { "category" => "Edit" }, bearer: "tok-1")

        assert_equal "201", res.code
        post = requests.find { |r| r[:path] == "/api/v1/agent_activities" }
        assert_equal "Bearer tok-1", post[:headers]["authorization"]
        assert_equal "application/json", post[:headers]["content-type"]
        assert_equal({ "category" => "Edit" }, JSON.parse(post[:body]))
      end
    end
  end

  def test_integration_http_get_sends_bearer_without_a_body
    Dir.mktmpdir do |proj|
      with_stub_server do |port, requests|
        c = client("CLAUDE_PROJECTS_DIR" => proj, "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}")
        res = c.http_get("/api/v1/insights?limit=3", bearer: "tok-2")

        assert_equal "200", res.code
        get = requests.find { |r| r[:path].start_with?("/api/v1/insights") }
        assert_equal "GET", get[:method]
        assert_equal "Bearer tok-2", get[:headers]["authorization"]
        assert_equal "", get[:body].to_s
      end
    end
  end

  def test_integration_unreachable_endpoint_degrades_to_nil_never_raises
    Dir.mktmpdir do |proj|
      c = client("CLAUDE_PROJECTS_DIR" => proj,
                 "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1",
                 "AGENT_API_SECRET" => "s3cret")
      assert_nil c.http_json(:post, "/x", { "a" => 1 }, bearer: "t")
      assert_nil c.http_get("/x", bearer: "t")
      assert_nil c.token
    end
  end

  private

  def timeouts_of(script)
    api = script.instance_variable_get(:@api)
    [api.open_timeout, api.read_timeout]
  end

  def load_bin(name)
    load File.expand_path("../../bin/#{name}", __dir__)
  end

  def write_token_cache(projects_dir, attrs)
    dir = File.join(projects_dir, ".agents", "atomic-capture")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "token.json"), JSON.generate(attrs))
  end

  # A one-shot localhost stub recording every request; serves /api/v1/auth mints,
  # 201s agent_activities POSTs, and 200s everything else.
  def with_stub_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }
    yield port, requests
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, headers: headers, body: body }

      status, payload =
        if path == "/api/v1/auth"
          ["200 OK", JSON.generate("token" => "stub-token",
                                   "expires_at" => (Time.now + 86_400).utc.iso8601)]
        elsif method == "POST"
          ["201 Created", JSON.generate("data" => { "id" => 1 })]
        else
          ["200 OK", JSON.generate("data" => [])]
        end

      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end
end
