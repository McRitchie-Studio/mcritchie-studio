# frozen_string_literal: true

# Tests for bin/atomic-event — the agent's self-narration CLI (start/end a span).
#
#   ruby -Itest test/lib/atomic_event_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the pure helpers — argv parsing, session resolution, the local
#                 category guard — loaded in process (main is guarded so `load`
#                 is side-effect free).
#   [integration] the real script, shelled out against a localhost stub HTTP
#                 server, mints a token then POSTs the right open/close shape.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"

load File.expand_path("../../bin/atomic-event", __dir__)

class AtomicEventCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/atomic-event", __dir__)
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

  def cli(env = {})
    AtomicEventCli.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env))
  end

  # ── [unit] argv + session resolution ─────────────────────────────────────

  def test_unit_parse_flags_reads_double_dash_values
    flags = cli.parse_flags(%w[--category Explore --reason find issue])
    assert_equal "Explore", flags["category"]
    # A bare token after the value is not a flag — last --flag wins its next token.
    assert_equal "find", flags["reason"]
  end

  def test_unit_session_prefers_explicit_then_env
    assert_equal "flag-sid", cli.resolve_session_id("session" => "flag-sid")
    assert_equal "claude-sid",
                 cli("CLAUDE_CODE_SESSION_ID" => "claude-sid").resolve_session_id({})
    assert_equal "codex-sid",
                 cli("CODEX_THREAD_ID" => "codex-sid").resolve_session_id({})
    assert_equal "", cli.resolve_session_id({})
  end

  def test_unit_category_vocabulary_matches_the_model
    assert_equal %w[Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan],
                 AtomicEventCli::CATEGORIES
  end

  # ── [integration] start POSTs an open span ───────────────────────────────

  def test_integration_start_mints_token_and_opens_span
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                           "task_slug" => "narrated-trajectory-events", "mascot" => "caterpie", "stage" => "building")
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason find-issue-with-api],
                         proj: proj)

      auth = requests.find { |r| r[:path] == "/api/v1/auth" }
      refute_nil auth, "expected a token mint"

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      refute_nil open, "expected a POST /api/v1/atomic_events"
      assert_equal "Bearer stub-token", open[:headers]["authorization"]

      body = JSON.parse(open[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "Explore", body["category"]
      assert_equal "find-issue-with-api", body["reason"]
      assert_equal "narrated-trajectory-events", body["task_slug"]
      assert_equal "caterpie", body["mascot"]
      assert_equal "building", body["stage"]
    end
  end

  def test_integration_end_posts_close_with_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[end --session #{SESSION} --outcome located-the-bug], proj: proj)

      close = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events/close" }
      refute_nil close, "expected a POST /api/v1/atomic_events/close"
      body = JSON.parse(close[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "located-the-bug", body["outcome"]
    end
  end

  def test_integration_unknown_category_never_hits_the_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --category Vibe --reason nope], proj: proj)
      assert_empty requests, "a locally-invalid category must POST nothing"
    end
  end

  def test_integration_no_session_id_never_hits_the_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%w[start --category Explore --reason x], proj: proj, with_session_env: false)
      assert_empty requests, "no session id → nothing to narrate → no network"
    end
  end

  def test_integration_always_exits_zero_even_when_endpoint_is_down
    Dir.mktmpdir do |proj|
      _out, _err, status = Open3.capture3(
        base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1"),
        RbConfig.ruby, BIN, "start", "--session", SESSION, "--category", "Explore", "--reason", "x",
        chdir: proj
      )
      assert_equal 0, status.exitstatus, "the CLI must always exit 0"
    end
  end

  private

  def write_session_marker(projects_dir, session_id, attrs)
    sessions = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    File.write(File.join(sessions, "#{session_id}.json"), JSON.generate(attrs))
  end

  def base_env(projects_dir)
    {
      "AGENT_API_SECRET" => "test-secret",
      "CLAUDE_PROJECTS_DIR" => projects_dir,
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil
    }
  end

  # Shell out to the real CLI against a one-shot stub server; returns the recorded
  # requests. chdir into the isolated proj dir so no stray .agent-context.json up
  # the real tree leaks into the marker resolution.
  def run_cli(argv, proj:, with_session_env: true)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    env = base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}")
    env["CLAUDE_CODE_SESSION_ID"] = SESSION if with_session_env && !argv.include?("--session")
    Open3.capture3(env, RbConfig.ruby, BIN, *argv, chdir: proj)
    requests
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

      status, payload = response_for(method, path)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path)
    return ["200 OK", JSON.generate("token" => "stub-token", "expires_at" => (Time.now + 86_400).utc.iso8601)] if path == "/api/v1/auth"
    return ["201 Created", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/atomic_events"
    return ["200 OK", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/atomic_events/close"

    ["404 Not Found", JSON.generate("error" => "unexpected #{method} #{path}")]
  end
end
