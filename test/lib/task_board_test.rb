# frozen_string_literal: true

# Tests for bin/lib/task_board.rb — the shared task-board TRANSPORT under
# bin/task, bin/dor-check, bin/reviewer-select, bin/session-preflight and
# bin/devops-cycle. The module is deliberately posture-free (raw response back,
# no status check, no rescue) so each CLI keeps its exact error behavior; these
# tests pin the transport shape, the lenient parse, and the ENV-first secret.
#   ruby -Itest test/lib/task_board_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"

require File.expand_path("../../bin/lib/task_board", __dir__)

class TaskBoardTest < Minitest::Test
  # ── [unit] parse_body (the die!-family's lenient parse) ─────────────────────

  def test_unit_parse_body_returns_empty_hash_for_blank_or_invalid_bodies
    assert_equal({}, TaskBoard.parse_body(FakeResponse.new("")))
    assert_equal({}, TaskBoard.parse_body(FakeResponse.new(nil)))
    assert_equal({}, TaskBoard.parse_body(FakeResponse.new("<html>boom</html>")),
                 "a non-JSON error page still renders a verdict, never raises")
  end

  def test_unit_parse_body_parses_json
    assert_equal({ "data" => [1] }, TaskBoard.parse_body(FakeResponse.new('{"data":[1]}')))
  end

  # ── [unit] agent_secret: ENV precedence ──────────────────────────────────────

  def test_unit_agent_secret_prefers_the_env_verbatim
    with_env("AGENT_API_SECRET" => "from-env") do
      assert_equal "from-env", TaskBoard.agent_secret("/nonexistent/.env")
    end
  end

  # ── [integration] request shape against a localhost stub ────────────────────

  def test_integration_request_sends_bearer_and_json_body
    with_stub_server do |port, requests|
      res = TaskBoard.request(:post, "/api/v1/tasks",
                              base_url: "http://127.0.0.1:#{port}",
                              token: "tok-1", body: { "title" => "X" })

      assert_equal "200", res.code
      req = requests.first
      assert_equal "POST", req[:method]
      assert_equal "Bearer tok-1", req[:headers]["authorization"]
      assert_equal "application/json", req[:headers]["content-type"]
      assert_equal({ "title" => "X" }, JSON.parse(req[:body]))
    end
  end

  def test_integration_request_get_without_token_or_body
    with_stub_server do |port, requests|
      res = TaskBoard.request(:get, "/api/v1/tasks/slug", base_url: "http://127.0.0.1:#{port}")

      assert_equal "200", res.code
      req = requests.first
      assert_equal "GET", req[:method]
      assert_nil req[:headers]["authorization"], "no token → no Authorization header"
      assert_equal "", req[:body].to_s
    end
  end

  def test_integration_request_supports_patch_for_bin_task_moves
    with_stub_server do |port, requests|
      TaskBoard.request(:patch, "/api/v1/tasks/slug",
                        base_url: "http://127.0.0.1:#{port}", token: "t", body: { "stage" => "building" })
      assert_equal "PATCH", requests.first[:method]
    end
  end

  def test_integration_request_accepts_a_prebuilt_uri_with_query
    with_stub_server do |port, requests|
      uri = URI.join("http://127.0.0.1:#{port}", "/api/v1/tasks")
      uri.query = URI.encode_www_form(stage: "submitted", page: 1)
      TaskBoard.request(:get, uri, token: "t")

      assert_equal "/api/v1/tasks?stage=submitted&page=1", requests.first[:path],
                   "devops-cycle passes prebuilt URIs to carry pagination query strings"
    end
  end

  def test_integration_request_never_checks_status_and_never_rescues
    with_stub_server(status: "422 Unprocessable Entity", payload: '{"error":"nope"}') do |port, _requests|
      res = TaskBoard.request(:post, "/x", base_url: "http://127.0.0.1:#{port}", body: {})
      assert_equal "422", res.code, "the raw response comes back — the CALLER owns the error posture"
    end

    assert_raises(SystemCallError, "transport errors PROPAGATE — bin/task's crash posture is the caller's") do
      TaskBoard.request(:get, "/x", base_url: "http://127.0.0.1:1", read_timeout: 1)
    end
  end

  private

  FakeResponse = Struct.new(:body)

  def with_env(pairs)
    saved = pairs.keys.map { |k| [k, ENV[k]] }.to_h
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # One-connection-at-a-time localhost stub recording every request.
  def with_stub_server(status: "200 OK", payload: '{"data":{}}')
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, status, payload) }
    yield port, requests
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, status, payload)
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

      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end
end
