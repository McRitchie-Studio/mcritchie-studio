# frozen_string_literal: true

# bin/review-autopilot `list` — the armed auto-merge registry read.
#
# WHY THIS FILE EXISTS. "nothing armed" is the most reassuring sentence this CLI
# can print: it is the operator's answer to "is anything queued to merge itself
# on green CI?". It used to be produced by `body["data"] || []`, so a body the
# CLI could not read — a proxy's HTML error page, a truncated response, an
# expired-token error payload — scored an EMPTY registry and printed the
# all-clear. An armed auto-merge could be sitting there unseen.
#
# The tests assert the EFFECT, not the exit code: a check that only asserted
# "exits nonzero" would pass on an unrelated crash, and the thing that must never
# happen is the reassuring SENTENCE printing off an unreadable answer.
#
#   ruby -Itest test/lib/review_autopilot_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "open3"
require "json"
require "socket"
require "rbconfig"
require_relative "../support/session_env"

class ReviewAutopilotTest < Minitest::Test
  BIN = File.expand_path("../../bin/review-autopilot", __dir__)

  # Serves `payload` verbatim for the registry GET (auth is always canned JSON),
  # so a test can serve exactly what a broken hop puts on the wire.
  def run_list(payload:, status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { serve(server, payload, status) }

    env = SessionEnv.neutralized(
      "TASK_BOARD_URL" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    )
    Open3.capture3(env, RbConfig.ruby, BIN, "list")
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, payload, status)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      _method, path, = line.split(" ")
      while (h = client.gets) && h != "\r\n"
        # headers drained; this stub asserts nothing about them
      end

      body = path == "/api/v1/auth" ? JSON.generate("token" => "stub-token") : payload
      code = path == "/api/v1/auth" ? "200 OK" : status
      client.write("HTTP/1.1 #{code}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def test_an_unreadable_registry_refuses_instead_of_printing_nothing_armed
    out, err, status = run_list(payload: "<html><body>502 Bad Gateway</body></html>")

    refute status.success?, "an unreadable registry must not exit 0"
    refute_includes out, "nothing armed",
                     "the all-clear must never print off a body the CLI could not read"
    assert_includes err, "UNREADABLE"
    assert_includes err, "This is NOT \"nothing armed\""
  end

  def test_an_error_payload_is_refused_too
    # An expired 24h agent token, served 200-shaped by a proxy: valid JSON,
    # carrying no rows. A lenient read scores it as an empty registry.
    out, err, status = run_list(payload: JSON.generate("error" => "Unauthorized"))

    refute status.success?
    refute_includes out, "nothing armed"
    assert_includes err, "UNREADABLE"
  end

  def test_a_genuinely_empty_registry_still_says_nothing_armed
    # The control. Refusing THIS would be a worse bug than the one being fixed:
    # empty-because-true is the normal, healthy answer.
    out, _err, status = run_list(payload: JSON.generate("data" => []))

    assert status.success?, "an empty registry is a healthy answer"
    assert_includes out, "nothing armed"
  end

  def test_an_armed_action_is_listed
    action = { "task_slug" => "some-task", "state" => "armed", "head_sha" => "abc1234567",
               "pr_number" => 42, "base_branch" => "accepted", "verdict" => "merge-ready",
               "note" => "waiting on CI" }
    out, _err, status = run_list(payload: JSON.generate("data" => [action]))

    assert status.success?
    refute_includes out, "nothing armed"
    assert_includes out, "some-task"
  end
end
