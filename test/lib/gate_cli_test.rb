# frozen_string_literal: true

# Standalone integration test for bin/gate's IDENTITY stamp: shells bin/gate against a localhost
# stub HTTP server (no Rails, no real network) and asserts what goes on the wire. A gate run
# must record WHO ran it: progress with no owner gets credited to whoever holds the claim, and
# Task#progress_actor reads this stamp.
# History: task detect-engine-migration-content-drift.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class GateCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/gate", __dir__)
  SESSION = "7c1f9a22-4d3e-4f0a-9b21-8a5c6d7e0f13"

  # A FRESH sandbox root per test, so the agent-token cache is COLD in every case
  # and each one walks the same mint-then-write path CI walks. Sharing one root
  # across the file would let whichever test ran first warm the cache and the rest
  # skip the mint — order-dependence under a random seed, which is the flake this
  # file already paid for once.
  def setup
    @sandbox_root = Dir.mktmpdir("gate-cli-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # Run bin/gate against a one-shot stub server; returns [recorded_requests, status].
  def run_gate(args, env: {})
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    # SessionEnv.neutralized: bin/gate resolves SessionIdentity, so the child names NO session
    # unless a case opts in. TaskUsageSandboxEnv.child_env: PIN THE WRITE ROOT. UNPINNED, bin/gate's
    # token cache under <CLAUDE_PROJECTS_DIR>/.agents hits TaskUsageSandbox.enforce! and `abort`s, a
    # SystemExit that AgentApi#write_cached_token's rescue does not catch, so the CLI dies after
    # POSTing /api/v1/auth. A desk's WARM token.json hides this; CI starts cold. A FRESH tmpdir per
    # test makes both worlds cold.
    # History: task detect-engine-migration-content-drift.
    base = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox_root)).merge(env))

    _out, err, status = Open3.capture3(base, RbConfig.ruby, BIN, *args)
    # The child's stderr rides the failure message. bin/gate reports every refusal
    # there and exits 1; discarding it turns a named cause ("CLAUDE_PROJECTS_DIR is
    # unset") into a bare "Expected false to be truthy", which is what made this
    # file's CI failure unreadable from the log alone.
    @gate_stderr = err
    [requests, status]
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
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }

      payload =
        if path == "/api/v1/auth"
          JSON.generate("token" => "stub-token")
        else
          JSON.generate("data" => { "attempt" => 1, "started_at" => "2026-08-13T17:00:00Z",
                                    "sops" => [], "finished_at" => nil })
        end
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil # server closed — stop serving
  end

  def gate_body(requests, path_suffix)
    request = requests.find { |r| r[:method] == "POST" && r[:path].end_with?(path_suffix) }
    refute_nil request, "expected a POST ending in #{path_suffix}; saw " \
                        "#{requests.map { |r| r[:path] }.inspect}. bin/gate stderr: #{@gate_stderr}"
    JSON.parse(request[:body]).fetch("gate", {})
  end

  # [integration] The stamp itself: whoever opened the attempt is on the row.
  def test_open_records_the_session_that_opened_the_gate
    requests, status = run_gate(%w[open task demo-task dor],
                                env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    assert status.success?, "bin/gate exited #{status.exitstatus}: #{@gate_stderr}"
    assert_equal SESSION, gate_body(requests, "/dor/open").dig("metadata", "session"),
                 "an unsigned gate run gets credited to whoever holds the claim"
  end

  def test_close_records_the_session_that_closed_the_gate
    requests, status = run_gate(%w[close task demo-task dor --success],
                                env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    assert status.success?, "bin/gate exited #{status.exitstatus}: #{@gate_stderr}"
    assert_equal SESSION, gate_body(requests, "/dor/close").dig("metadata", "session")
  end

  # A Codex session is a session too — the stamp rides the shared identity chain,
  # not one provider's env var.
  def test_open_records_a_codex_session
    requests, = run_gate(%w[open task demo-task dor], env: { "CODEX_THREAD_ID" => SESSION })

    assert_equal SESSION, gate_body(requests, "/dor/open").dig("metadata", "session")
  end

  # A plain shell / CI run names no session. An unattributed row must stay
  # honestly unattributed — a guessed owner is the failure this exists to end.
  def test_open_without_a_session_stamps_nobody
    requests, status = run_gate(%w[open task demo-task dor])

    assert status.success?, "bin/gate exited #{status.exitstatus}: #{@gate_stderr}"
    assert_nil gate_body(requests, "/dor/open")["metadata"], "no session means no owner, never a guessed one"
  end

  # --meta still reaches the server, and the session rides alongside rather than
  # replacing it — the close path merges the two.
  def test_close_keeps_explicit_meta_beside_the_session
    requests, = run_gate(%w[close task demo-task dor --failed --meta cause=lane_failed],
                         env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    metadata = gate_body(requests, "/dor/close")["metadata"]
    assert_equal "lane_failed", metadata["cause"]
    assert_equal SESSION, metadata["session"]
  end
end
