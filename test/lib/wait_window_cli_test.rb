# frozen_string_literal: true

# [integration] `bin/task wait-window` end-to-end against a localhost stub board —
# the wire, the parse of the API's `windows` list, and the three exit codes the
# SOPs branch on. The loop's rules are unit-tested in wait_window_test.rb; this
# file proves the CLI actually reads what the board sends.
#
#   ruby -Itest test/lib/wait_window_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../support/session_env"

class WaitWindowCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "demo-window-task"

  def setup
    @sandbox_root = Dir.mktmpdir("wait-window-cli-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  def task_payload(windows:, approval: "waiting", blocked_at: nil, block_kind: nil)
    JSON.generate("data" => { "slug" => SLUG, "stage" => "building", "title" => "Demo", "blocked_at" => blocked_at,
                              "block_kind" => block_kind, "metadata" => { "devops" => { "approval_status" => approval } },
                              "windows" => windows })
  end

  def window(kind, ends_at)
    { "kind" => kind, "ends_at" => ends_at.utc.iso8601, "minutes" => 10, "lapsed" => Time.now >= ends_at }
  end

  # Run bin/task against a stub board that answers each GET /api/v1/tasks/:slug
  # with the next [status, body] in `reads` (the last one repeats).
  def run_task(args, reads:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, reads.dup) }

    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox_root)))

    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [out, err, status, requests]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, reads)
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
      client.read(headers["content-length"].to_i) if headers["content-length"]
      requests << { method: method, path: path }

      code, payload =
        if path.start_with?("/api/v1/auth")
          [200, JSON.generate("token" => "stub-token")]
        elsif method == "GET" && path == "/api/v1/tasks/#{SLUG}"
          reads.size > 1 ? reads.shift : reads.first
        else
          [500, JSON.generate("error" => "unexpected #{method} #{path}")]
        end

      client.write("HTTP/1.1 #{code} #{code == 200 ? 'OK' : 'Error'}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  def test_answered_when_the_window_closes_exits_zero_and_says_what_it_saw
    open = [200, task_payload(windows: [window("approval", Time.now + 300)])]
    closed = [200, task_payload(windows: [], approval: "approved")]
    out, err, status, requests = run_task(["wait-window", SLUG, "--interval", "1", "--json"], reads: [open, closed])

    assert_equal 0, status.exitstatus, "answered exits 0: #{err}"
    assert_match(/approval 0[45]:\d\d left/, out)
    assert_match(/answered — approval window closed · approval_status approved · not blocked/, out)
    verdict = JSON.parse(out.lines.last)
    assert_equal "answered", verdict["verdict"]
    assert_equal ["approval"], verdict["windows_at_start"].map { |w| w["kind"] }
    assert_equal 2, requests.count { |r| r[:method] == "GET" && r[:path] == "/api/v1/tasks/#{SLUG}" }
  end

  def test_a_lapsed_window_exits_two
    lapsed = [200, task_payload(windows: [window("escalation", Time.now - 5)], blocked_at: (Time.now - 1200).utc.iso8601, block_kind: "dependency")]
    out, err, status = run_task(["wait-window", SLUG, "--grace", "0"], reads: [lapsed])

    assert_equal 2, status.exitstatus, "lapsed exits 2: #{err}"
    assert_match(/lapsed — escalation lapsed/, out)
    assert_match(/blocked \(dependency\)/, out)
  end

  def test_a_board_that_cannot_be_read_exits_one_after_three_tries
    out, err, status, requests = run_task(["wait-window", SLUG, "--interval", "1"],
                                          reads: [[500, JSON.generate("error" => "boom")]])

    assert_equal 1, status.exitstatus
    assert_equal 3, err.lines.grep(/board read failed/).size
    assert_equal 3, requests.count { |r| r[:method] == "GET" && r[:path] == "/api/v1/tasks/#{SLUG}" }
    refute_match(/answered/, out, "an unreadable board is never read as answered")
  end

  def test_a_missing_task_exits_one_at_once
    _out, err, status, requests = run_task(["wait-window", SLUG], reads: [[404, JSON.generate("error" => "task not found")]])

    assert_equal 1, status.exitstatus
    assert_match(/task not found/, err)
    assert_equal 1, requests.count { |r| r[:method] == "GET" && r[:path] == "/api/v1/tasks/#{SLUG}" }
  end

  def test_usage_errors_exit_three_and_read_nothing
    _out, err, status, requests = run_task(["wait-window"], reads: [])
    assert_equal 3, status.exitstatus
    assert_match(/usage: bin\/task wait-window/, err)
    assert_empty requests

    _out, err, status, = run_task(["wait-window", SLUG, "--forever"], reads: [])
    assert_equal 3, status.exitstatus
    assert_match(/unknown flag --forever/, err)
  end
end
