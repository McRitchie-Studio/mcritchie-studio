# frozen_string_literal: true

# bin/task and a handed-down bearer (AGENT_API_TOKEN) the board refuses: one mint
# from the secret, one retry. The second-refusal case sits in task_cli_test.rb
# (test_a_refused_handed_token_names_the_environment_variable).
#
# Run directly:
#   ruby -Itest test/lib/task_cli_handed_token_remint_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskCliHandedTokenRemintTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # Runs bin/task against a stub board that answers 401 to `refuse` (a bearer, or
  # :all for every task read) and 200 to everything else.
  def run_task(args, handed:, refuse:)
    @sandbox ||= Dir.mktmpdir("task-remint-sandbox")
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests, refuse) }
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "AGENT_API_TOKEN" => handed,
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox)))
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, refuse)
    loop do
      client = server.accept
      request_line = client.gets or break
      method, path = request_line.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      client.read(headers["content-length"].to_i) if headers["content-length"]
      requests << { method: method, path: path, bearer: headers["authorization"] }
      status, payload = answer(path, headers["authorization"], refuse)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed
  end

  def answer(path, bearer, refuse)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"
    return ["401 Unauthorized", JSON.generate("error" => "token expired")] if refuse == :all || bearer == "Bearer #{refuse}"

    ["200 OK", JSON.generate("data" => { "slug" => "demo-task", "stage" => "building", "title" => "Demo Task",
                                         "metadata" => { "devops" => { "kind" => "feature" } } })]
  end

  # [integration] The refused call, one mint, then the same call with the minted
  # bearer. The note carries the new token's length, never a token.
  def test_handed_token_401_remints_once
    requests, out, err, status = run_task(["show", "demo-task", "--json"], handed: "tok-stale", refuse: "tok-stale")

    assert status.success?, err
    assert_equal "demo-task", JSON.parse(out)["slug"]
    assert_equal 1, requests.count { |r| r[:path] == "/api/v1/auth" }, "exactly one re-mint"
    assert_equal ["Bearer tok-stale", nil, "Bearer stub-token"], requests.first(3).map { |r| r[:bearer] }
    assert_equal requests[0][:path], requests[2][:path], "the retry repeats the refused call"
    assert_includes err, "AGENT_API_TOKEN was refused"
    assert_includes err, "length #{"stub-token".length}"
    refute_includes err, "stub-token"
    refute_includes err, "tok-stale"
  end

  # [integration] The control: a 401 on a bearer the CLI minted itself is not retried.
  def test_a_401_on_a_self_minted_token_is_not_retried
    requests, _out, err, status = run_task(["show", "demo-task", "--json"], handed: nil, refuse: :all)

    refute status.success?
    assert_match(/401/, err)
    assert_equal 1, requests.count { |r| r[:path] == "/api/v1/auth" }, "only the CLI's own first mint"
    assert_equal 1, requests.count { |r| r[:path].start_with?("/api/v1/tasks/") }
  end
end
