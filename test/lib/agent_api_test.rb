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

# Arms TASK_USAGE_SANDBOX for THIS process (and every child it spawns), so the
# token-cache guard below is actually live. Without it these tests passed only when a
# sibling file that DOES require it happened to run first in the same process — green
# in the suite, red alone, and proving nothing either way.
require_relative "../support/session_env"
require_relative "../support/op_binary_stub"
require File.expand_path("../../bin/lib/agent_api", __dir__)

class AgentApiTest < Minitest::Test
  # NOTE: no keyword params here — a trailing `"KEY" => "v"` hash must stay the
  # positional env, not get captured as keywords. Timeouts stay short (1s/1s).
  def client(env = {})
    AgentApi.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env),
                 open_timeout: 1, read_timeout: 1)
  end

  # ── [unit] base_url ─────────────────────────────────────────────────────────

  def test_unit_base_url_defaults_to_production_board
    assert_equal "https://mcritchie.studio", client.base_url
    assert_equal "https://mcritchie.studio", client("ATOMIC_CAPTURE_URL" => "  ").base_url
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

  # ── [unit] the token cache is state in the operator's real .agents ────────────
  #
  # Same family as the cost store (PR #525) and the narration markers (PR #549):
  # <projects>/.agents/atomic-capture/token.json is resolved by the SAME
  # CLAUDE_PROJECTS_DIR-else-real-root fallback, and it was unguarded. It is not an
  # exotic path either — the narration leak fired an authenticated GET at the
  # PRODUCTION board on every unpinned suite run, and a 401 on that GET drives
  # invalidate_token! straight into this delete.
  #
  # SEVERITY, stated honestly: token.json is a RE-MINTABLE CACHE, not a credential.
  # `token` re-mints from the 1Password/env secret on the next call, so a stray delete
  # is a self-healing eviction — a wasted `op read`, not credential destruction. It is
  # guarded because an unguarded write into the real store is the bug, not because it
  # is an emergency.
  #
  # The guard aborts BEFORE any IO, so this proves the refusal without attempting it.
  def test_unit_an_unpinned_token_cache_mutation_aborts_instead_of_touching_the_real_store
    real = File.join(TaskUsageSandbox.real_state_dir, "atomic-capture", "token.json")
    existed = File.exist?(real)

    # NOT `client` — that helper pins CLAUDE_PROJECTS_DIR for us, which is the whole
    # point of it. Unpinned, projects_dir falls back to the operator's REAL root.
    c = unpinned_client("AGENT_API_SECRET" => "s3cret")

    err = assert_token_abort { c.invalidate_token! }
    assert_match(/sandbox/i, err, "the abort must say WHY")
    assert_includes err, "CLAUDE_PROJECTS_DIR", "and must name the var to pin"

    err = assert_token_abort { c.send(:write_cached_token, "tok", nil) }
    assert_match(/sandbox/i, err, "the WRITE seam is guarded too, not only the delete")

    assert_equal existed, File.exist?(real), "the operator's real token cache must be untouched"
  end

  # An injected env cannot DISARM the guard by omitting the arming var — arming is a
  # property of the PROCESS. Otherwise `AgentApi.new(env: {})` reads as unsandboxed
  # and writes the real store: the exact hole the guard exists to close.
  def test_unit_an_injected_env_cannot_disarm_the_token_guard
    assert_token_abort { unpinned_client.invalidate_token! }
  end

  # A client whose env pins NOTHING — the fallback that reaches the real store.
  def unpinned_client(env = {})
    AgentApi.new(env: env, open_timeout: 1, read_timeout: 1)
  end

  # And the happy path the guard must not break: pinned, the cache still round-trips.
  def test_unit_a_pinned_token_cache_still_writes_and_invalidates
    Dir.mktmpdir do |proj|
      c = client("CLAUDE_PROJECTS_DIR" => proj, "AGENT_API_SECRET" => "s3cret")
      c.send(:write_cached_token, "tok", (Time.now + 3600).utc.iso8601)
      assert_path_exists c.send(:token_cache_path), "a pinned write must land"

      c.invalidate_token!
      refute_path_exists c.send(:token_cache_path), "a pinned invalidation must still evict"
    end
  end

  def assert_token_abort(&block)
    original = $stderr
    $stderr = StringIO.new
    ex = assert_raises(SystemExit, "an unguarded token-cache mutation must ABORT, not degrade to a skip", &block)
    refute_predicate ex.status, :zero?
    "#{ex.message}\n#{$stderr.string}"
  ensure
    $stderr = original
  end

  # ── [unit] secret order: ENV, then the repo .env, then the VAULT LAST ────────
  #
  # Counted in vault reads, for the same reason as bin/lib/task_board.rb's twin:
  # ENV, .env and 1Password hold the SAME string in production, so asserting the
  # returned value alone passes on every ordering. What distinguishes a correct
  # chain from the one that drained a 1,000/day account-wide cap is whether the
  # metered step was CONSULTED, so that is what these assert. The stub is a real
  # executable at the repointed OP constant, so a green run can never be a run
  # that quietly reached the operator's live vault.

  def test_unit_agent_secret_prefers_the_env_verbatim
    assert_equal "from-env", client("AGENT_API_SECRET" => "from-env").send(:agent_secret)
  end

  def test_unit_agent_secret_takes_the_repo_dotenv_and_spends_no_vault_read
    Dir.mktmpdir do |repo|
      File.write(File.join(repo, ".env"), "OTHER=1\nAGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        assert_equal "from-dotenv", client.send(:agent_secret),
                     "the repo .env answers before the vault (old order answered 'from-vault')"
        assert_equal 0, op.count, "a provisioned machine spends ZERO credentials here"
      end
    end
  end

  def test_unit_agent_secret_still_reaches_the_vault_once_when_there_is_no_dotenv
    # Demoted, not deleted — an unprovisioned machine has nothing else to try.
    Dir.mktmpdir do |repo|
      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        c = client
        assert_equal "from-vault", c.send(:agent_secret)
        assert_equal "from-vault", c.send(:agent_secret), "second resolution on the same client"

        assert_equal 1, op.count, "memoized per client — a retry would bill a second credential"
        assert_equal ["read #{AgentApi::SECRET_REF}"], op.lines
      end
    end
  end

  # ── [unit] the .env branch's UNGUARDED EDGES, mirrored from TaskBoard ────────
  #
  # These are the twin of the block in test/lib/task_board_test.rb, and they
  # exist SEPARATELY rather than by a shared helper on purpose: the two chains
  # are independent implementations of one rule, and the bug being fixed here is
  # precisely that they had DRIFTED (task_board guarded with File.exist?, this
  # one with File.file?, and neither stripped quotes). A shared helper would
  # re-couple them and hide the next divergence; two copies of the same
  # assertions catch it.
  #
  # This client wraps #agent_secret in `rescue StandardError`, so an EISDIR or
  # EACCES here never crashed — it degraded to nil, which reads as "no secret
  # anywhere" and sends the caller to the vault. That is the right destination
  # for the wrong reason, and it hid the defect rather than handling it.
  def test_unit_agent_secret_strips_quotes_off_the_repo_dotenv
    Dir.mktmpdir do |repo|
      File.write(File.join(repo, ".env"), %(AGENT_API_SECRET="from-dotenv"\n))

      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        assert_equal "from-dotenv", client.send(:agent_secret),
                     "quotes are stripped, not shipped as part of the secret"
        assert_equal 0, op.count
      end
    end
  end

  def test_unit_agent_secret_treats_a_blank_dotenv_value_as_no_value
    # `AGENT_API_SECRET=` yielded "" — truthy — so the vault fallback never ran
    # and the caller's own emptiness guard could not fire either.
    Dir.mktmpdir do |repo|
      File.write(File.join(repo, ".env"), "AGENT_API_SECRET=\n")

      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        assert_equal "from-vault", client.send(:agent_secret),
                     "a set-but-empty .env value must not satisfy the chain"
        assert_equal 1, op.count, "and the vault fallback must actually run"
      end
    end
  end

  def test_unit_agent_secret_falls_through_a_dotenv_that_is_a_directory
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, ".env"))

      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        assert_equal "from-vault", client.send(:agent_secret),
                     "a directory .env is skipped, not read"
        assert_equal 1, op.count
      end
    end
  end

  def test_unit_agent_secret_falls_through_an_unreadable_dotenv
    # The case `File.file?` alone does NOT close: mode-000 is still a file.
    Dir.mktmpdir do |repo|
      locked = File.join(repo, ".env")
      File.write(locked, "AGENT_API_SECRET=from-dotenv\n")
      File.chmod(0o000, locked)

      assert File.file?(locked), "premise: still a regular file"
      refute File.readable?(locked), "premise: unreadable by this uid (fails as root)"

      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        assert_equal "from-vault", client.send(:agent_secret),
                     "an unreadable .env falls through to the vault"
        assert_equal 1, op.count
      end
    ensure
      File.chmod(0o600, locked) if locked && File.exist?(locked)
    end
  end

  def test_unit_agent_secret_does_not_let_a_blank_env_short_circuit_the_chain
    Dir.mktmpdir do |repo|
      File.write(File.join(repo, ".env"), "AGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
        assert_equal "from-dotenv", client("AGENT_API_SECRET" => "   ").send(:agent_secret),
                     "a whitespace-only ENV is not a secret"
        assert_equal 0, op.count
      end
    end
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

  def test_integration_a_token_mint_sources_the_dotenv_and_spends_no_vault_read
    # The mint is the ONLY thing in this stack that needs the secret, and the
    # disk cache means it happens about once a day rather than once a call —
    # which capped the damage here but did not make the ordering right. A cold
    # cache on a provisioned machine must still cost zero credentials.
    Dir.mktmpdir do |proj|
      Dir.mktmpdir do |repo|
        File.write(File.join(repo, ".env"), "AGENT_API_SECRET=from-dotenv\n")

        OpBinaryStub.with_stub(AgentApi, dir: repo, consts: { REPO_ROOT: repo }) do |op|
          with_stub_server do |port, requests|
            env = { "CLAUDE_PROJECTS_DIR" => proj, "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}" }

            assert_equal "stub-token", client(env).token, "the mint succeeded from a cold cache"

            auth = requests.find { |r| r[:path] == "/api/v1/auth" }
            assert_equal({ "secret" => "from-dotenv" }, JSON.parse(auth[:body]),
                         "and it minted with the LOCAL secret, not a vault copy")
          end

          assert_equal 0, op.count, "a cold-cache token mint spends zero 1Password reads"
        end
      end
    end
  end

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
