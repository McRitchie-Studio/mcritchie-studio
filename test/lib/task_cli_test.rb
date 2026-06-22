# frozen_string_literal: true

# Standalone integration test for bin/task's session-resume capture. Shells out
# to bin/task against a localhost stub HTTP server (no Rails, no real network),
# so it deterministically asserts that the CLI stamps devops.session_id +
# session_provider from CLAUDE_CODE_SESSION_ID on `create` and on the move to
# `building` (the claim moment) — and stamps nothing when no session env is set.
#
#   ruby -Itest test/lib/task_cli_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"

class TaskCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617"

  # Run bin/task against a one-shot stub server; returns [recorded_requests, out].
  # `env` overrides merge onto a clean base (auth secret + base url + skip marker);
  # a nil value deletes that var from the child (used to clear the session vars so
  # the test never depends on a real ambient session).
  def run_task(args, env: {})
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    base_env = {
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_SESSION_ID" => nil
    }.merge(env)

    out, = Open3.capture2(base_env, RbConfig.ruby, BIN, *args, err: File::NULL)
    [requests, out]
  ensure
    server&.close
    thread&.join(1)
  end

  # Minimal HTTP/1.1 stub: records each request and returns canned JSON. bin/task
  # opens one connection per request (auth, then the task call(s)).
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
      requests << { method: method, path: path, body: body }

      payload = response_for(path)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(path)
    return JSON.generate("token" => "stub-token") if path == "/api/v1/auth"

    # The GET in the move read-merge returns an existing task carrying prior
    # devops, so the test can prove the session stamp is MERGED, not a wipe.
    JSON.generate("data" => {
      "slug" => "demo-task", "stage" => "building",
      "metadata" => { "devops" => { "kind" => "feature" } }
    })
  end

  def devops_of(request)
    JSON.parse(request[:body]).fetch("devops", {})
  end

  def test_create_stamps_session_from_claude_env
    requests, = run_task(
      ["create", "--title", "Session demo task", "--kind", "feature"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create, "expected a POST /api/v1/tasks"
    devops = devops_of(create)
    assert_equal SESSION, devops["session_id"]
    assert_equal "claude", devops["session_provider"]
    assert_equal "feature", devops["kind"]
  end

  def test_move_to_building_stamps_session_and_preserves_devops
    requests, = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch, "expected a PATCH for the move"
    parsed = JSON.parse(patch[:body])
    assert_equal "building", parsed["stage"]
    assert_equal SESSION, parsed.dig("devops", "session_id")
    assert_equal "claude", parsed.dig("devops", "session_provider")
    # read-merge-write keeps the existing devops field rather than wiping it
    assert_equal "feature", parsed.dig("devops", "kind")
  end

  def test_create_without_a_session_env_stamps_nothing
    requests, = run_task(["create", "--title", "No session task", "--kind", "feature"])
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create
    devops = devops_of(create)
    refute devops.key?("session_id"), "no session env should stamp no session_id"
    refute devops.key?("session_provider")
  end

  def test_move_to_a_non_building_stage_does_not_stamp_session
    requests, = run_task(
      ["move", "demo-task", "submitted"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    # submitted is not the claim moment → no GET read-merge, no devops sent.
    patch = requests.find { |r| r[:method] == "PATCH" }
    parsed = JSON.parse(patch[:body])
    assert_equal "submitted", parsed["stage"]
    refute parsed.key?("devops"), "non-building moves should not send devops"
  end
end
