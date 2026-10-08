# frozen_string_literal: true

# [integration] What bin/task does with two answers the board gives on a write:
# the `warnings` array beside `data` (guard catalog row 10.1), and a pr_urls map
# keyed by the repo each url names (row 10.3). Drives the real binary against a
# one-shot stub board; no Rails, no network.
#
#   ruby -Itest test/lib/task_cli_board_answers_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskCliBoardAnswersTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  HUB = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836"
  TURF = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # Returns [requests, out, err, status]. Every task read and write answers
  # `{ data: record }`, with `warnings` beside it when given.
  def run_task(args, devops: { "kind" => "feature" }, warnings: nil)
    @sandbox ||= Dir.mktmpdir("task-answers-sandbox")
    body = { "data" => { "slug" => "demo-task", "stage" => "building", "title" => "Demo Task",
                         "metadata" => { "devops" => devops } } }
    body["warnings"] = warnings if warnings
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests, JSON.generate(body)) }
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox)))
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, task_payload)
    loop do
      client = server.accept
      request_line = client.gets or break
      method, path = request_line.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }
      payload = path == "/api/v1/auth" ? JSON.generate("token" => "stub-token") : task_payload
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed
  end

  def test_a_write_prints_each_warning_the_board_answers_and_succeeds
    advice = "title is 9 words; 3-5 reads best on the board (put detail in agent_context)"
    _requests, _out, err, status = run_task(%w[update demo-task --kind chore], warnings: [advice])

    assert status.success?, err
    assert_includes err, "warning: #{advice}"
  end

  # The control: the same write with no warnings prints none.
  def test_a_write_the_board_answers_plainly_prints_no_warning
    _requests, _out, err, status = run_task(%w[update demo-task --kind chore])

    assert status.success?, err
    refute_match(/^warning:/, err)
  end

  # The url decides the key, so a pair typed under the wrong repo joins the stored
  # map beside that repo's own entry instead of replacing it.
  def test_pr_url_for_keys_a_pair_by_the_repo_its_url_names
    requests, _out, err, status = run_task(
      ["update", "demo-task", "--pr-url-for", "mcritchie-studio=#{TURF}"],
      devops: { "kind" => "feature", "pr_urls" => { "mcritchie-studio" => HUB } }
    )

    assert status.success?, err
    patch = requests.reverse.find { |r| r[:method] == "PATCH" }
    refute_nil patch, "expected a PATCH for the update"
    assert_equal({ "mcritchie-studio" => HUB, "turf-monster" => TURF },
                 JSON.parse(patch[:body]).dig("devops", "pr_urls"))
    assert_includes err, "is filed under turf-monster, the repo the url names"
  end

  def test_pr_url_for_under_its_own_repo_says_nothing
    requests, _out, err, status = run_task(["update", "demo-task", "--pr-url-for", "turf-monster=#{TURF}"])

    assert status.success?, err
    patch = requests.reverse.find { |r| r[:method] == "PATCH" }
    assert_equal({ "turf-monster" => TURF }, JSON.parse(patch[:body]).dig("devops", "pr_urls"))
    refute_match(/is filed under/, err)
  end
end
