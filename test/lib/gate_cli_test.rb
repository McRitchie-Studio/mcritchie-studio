# frozen_string_literal: true

# Standalone integration test for bin/gate's IDENTITY stamp. Shells out to
# bin/gate against a localhost stub HTTP server (no Rails, no real network) and
# asserts what actually goes on the wire.
#
# Why this file exists. A gate run recorded that a cert ran; it did not record WHO
# ran it. On 2026-08-13 a challenger's own `bin/full-suite-check` opened a g1_cert
# on a task held by someone else, and the build-claim gate quoted that cert back to
# the challenger as evidence the HOLDER was alive — progress with no owner gets
# credited to whoever holds the claim. Task#progress_actor reads the stamp this
# file asserts, so without it the whole attribution chain is blind.
#
#   ruby -Itest test/lib/gate_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require_relative "../support/session_env"

class GateCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/gate", __dir__)
  SESSION = "7c1f9a22-4d3e-4f0a-9b21-8a5c6d7e0f13"

  # Run bin/gate against a one-shot stub server; returns [recorded_requests, status].
  def run_gate(args, env: {})
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    # SessionEnv.neutralized: bin/gate resolves SessionIdentity, so the child must
    # name NO session unless a case opts one in — otherwise this file reads the
    # LIVE agent session and goes red inside an agent run.
    base = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    }.merge(env))

    _out, _err, status = Open3.capture3(base, RbConfig.ruby, BIN, *args)
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
    refute_nil request, "expected a POST ending in #{path_suffix}; saw #{requests.map { |r| r[:path] }.inspect}"
    JSON.parse(request[:body]).fetch("gate", {})
  end

  # [integration] The stamp itself: whoever opened the attempt is on the row.
  def test_open_records_the_session_that_opened_the_gate
    requests, status = run_gate(%w[open task demo-task g1_cert],
                                env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    assert status.success?
    assert_equal SESSION, gate_body(requests, "/g1_cert/open").dig("metadata", "session"),
                 "an unsigned gate run gets credited to whoever holds the claim"
  end

  def test_close_records_the_session_that_closed_the_gate
    requests, status = run_gate(%w[close task demo-task g1_cert --success],
                                env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    assert status.success?
    assert_equal SESSION, gate_body(requests, "/g1_cert/close").dig("metadata", "session")
  end

  # A Codex session is a session too — the stamp rides the shared identity chain,
  # not one provider's env var.
  def test_open_records_a_codex_session
    requests, = run_gate(%w[open task demo-task g1_cert], env: { "CODEX_THREAD_ID" => SESSION })

    assert_equal SESSION, gate_body(requests, "/g1_cert/open").dig("metadata", "session")
  end

  # A plain shell / CI run names no session. An unattributed row must stay
  # honestly unattributed — a guessed owner is the failure this exists to end.
  def test_open_without_a_session_stamps_nobody
    requests, status = run_gate(%w[open task demo-task g1_cert])

    assert status.success?
    assert_nil gate_body(requests, "/g1_cert/open")["metadata"], "no session means no owner, never a guessed one"
  end

  # --meta still reaches the server, and the session rides alongside rather than
  # replacing it — the close path merges the two.
  def test_close_keeps_explicit_meta_beside_the_session
    requests, = run_gate(%w[close task demo-task g1_cert --failed --meta cause=lane_failed],
                         env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    metadata = gate_body(requests, "/g1_cert/close")["metadata"]
    assert_equal "lane_failed", metadata["cause"]
    assert_equal SESSION, metadata["session"]
  end
end
