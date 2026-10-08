# frozen_string_literal: true

# bin/task and the admin login: TASK_AS_ADMIN=1 presents the admin login this
# harness session holds on every call, with no fallback; without it no command
# presents the admin login; and a move to `archived` never offers the desk's
# studio login.
#
# Run directly:
#   ruby -Itest test/lib/task_cli_admin_session_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../support/session_env"
require_relative "../../bin/lib/admin_login"
require_relative "../../bin/lib/desk_session"

class TaskCliAdminSessionTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  HARNESS = "harness-admin-test"

  def setup
    @sandbox = Dir.mktmpdir("task-admin-sandbox")
    @child = TaskUsageSandboxEnv.child_env(@sandbox)
    @desk = File.join(@sandbox, "desk")
    FileUtils.mkdir_p(File.join(@desk, ".git"))
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if File.directory?(@sandbox)
  end

  def keep_admin_login(soul: "xan")
    AdminLogin.write(HARNESS, @child["CLAUDE_PROJECTS_DIR"],
                     { "soul" => soul, "session" => "sess-admin", "token" => "ADMIN-TOKEN",
                       "expires_at" => (Time.now + 3600).utc.iso8601 }, env: @child)
  end

  def keep_desk_login
    DeskSession.write(@desk, { "slug" => "sess-desk", "soul" => "pokemon", "tier" => "studio", "task_slug" => "demo-task",
                               "expires_at" => (Time.now + 3600).utc.iso8601, "token" => "DESK-TOKEN",
                               "harness_session_id" => HARNESS })
  end

  # Runs bin/task from the desk against a stub board that answers `refuse` (a
  # bearer) 401 and everything else 200.
  def run_task(args, env: {}, refuse: nil)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    @stage = nil
    thread = Thread.new { serve(server, requests, refuse) }
    full = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "CLAUDE_CODE_SESSION_ID" => HARNESS,
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(@child).merge(env))
    out, err, status = Open3.capture3(full, RbConfig.ruby, BIN, *args, chdir: @desk)
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
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path.split("?").first, bearer: headers["authorization"], body: body,
                    caller: headers["x-agent-caller"] }
      moved = (JSON.parse(body)["stage"] rescue nil) if method == "PATCH"
      @stage = moved if moved
      status, payload = answer(path, headers["authorization"], refuse)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  def answer(path, bearer, refuse)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"
    if refuse && bearer == "Bearer #{refuse}"
      return ["401 Unauthorized", JSON.generate("error" => "agent session sess-admin expired", "error_code" => "SESSION_ENDED")]
    end

    ["200 OK", JSON.generate("data" => { "slug" => "demo-task", "stage" => @stage || "building", "title" => "Demo Task",
                                         "metadata" => { "devops" => { "kind" => "feature" } } })]
  end

  def task_bearers(requests) = requests.reject { |r| r[:path] == "/api/v1/auth" }.map { |r| r[:bearer] }.uniq

  # [integration] Every call of a TASK_AS_ADMIN run presents the admin login, and no
  # shared token is minted.
  def test_as_admin_presents_the_admin_login_on_every_call
    keep_admin_login
    requests, _out, err, status = run_task(["update", "demo-task", "--local-url", "http://localhost:3014/tasks"],
                                           env: { "TASK_AS_ADMIN" => "1" })

    assert status.success?, err
    assert_equal ["Bearer ADMIN-TOKEN"], task_bearers(requests)
    assert_includes requests.map { |r| r[:method] }, "PATCH"
    assert_empty requests.select { |r| r[:path] == "/api/v1/auth" }
    refute_includes err, "ADMIN-TOKEN"
  end

  # [integration] The admin login is asked for, never assumed: the same harness
  # session without TASK_AS_ADMIN keeps the shared token.
  def test_without_the_ask_no_command_presents_the_admin_login
    keep_admin_login
    requests, _out, err, status = run_task(["update", "demo-task", "--local-url", "http://localhost:3014/tasks"])

    assert status.success?, err
    assert_equal ["Bearer stub-token"], task_bearers(requests)
  end

  # [integration] No admin login held: the run stops before any request, naming the login.
  def test_as_admin_with_no_admin_login_stops_and_names_the_login
    requests, _out, err, status = run_task(["show", "demo-task", "--json"], env: { "TASK_AS_ADMIN" => "1" })

    refute status.success?
    assert_empty requests
    assert_includes err, "TASK_AS_ADMIN is set and this harness session holds no admin login"
    assert_includes err, "bin/agent-activity heartbeat steffon"
  end

  # [integration] The hub-shell grant's token is an admin login too.
  def test_as_admin_presents_the_hub_shell_grant
    requests, _out, err, status = run_task(["show", "demo-task", "--json"],
                                           env: { "TASK_AS_ADMIN" => "1", "AGENT_ADMIN_SESSION_TOKEN" => "ENV-ADMIN" })

    assert status.success?, err
    assert_equal ["Bearer ENV-ADMIN"], task_bearers(requests)
  end

  # [integration] An ended admin login answers 401: the run says so and does not
  # fall back to the shared token.
  def test_an_ended_admin_login_stops_with_no_fallback
    keep_admin_login(soul: "steffon")
    requests, _out, err, status = run_task(["show", "demo-task", "--json"], env: { "TASK_AS_ADMIN" => "1" },
                                                                             refuse: "ADMIN-TOKEN")

    refute status.success?
    assert_equal 1, requests.size, "one refused call, no retry and no mint"
    assert_includes err, "agent session sess-admin expired"
    assert_includes err, "the admin login ended; run `bin/agent-activity heartbeat steffon`"
  end

  # [integration] The desk's studio login writes its own task (the control), and is
  # not offered on a move to `archived`, which only an admin makes.
  def test_an_archive_move_never_offers_the_desks_studio_login
    keep_desk_login
    requests, _out, err, status = run_task(["update", "demo-task", "--local-url", "http://localhost:3014/tasks"])
    assert status.success?, err
    assert_includes requests.select { |r| r[:method] == "PATCH" }.map { |r| r[:bearer] }, "Bearer DESK-TOKEN"

    requests, _out, err, status = run_task(["move", "demo-task", "archived", "--force"])
    assert status.success?, err
    archive = requests.find { |r| r[:method] == "PATCH" && r[:body].include?("archived") }
    refute_nil archive, "the archive PATCH was sent"
    assert_equal "Bearer stub-token", archive[:bearer]

    keep_admin_login
    requests, _out, err, status = run_task(["move", "demo-task", "archived", "--force"], env: { "TASK_AS_ADMIN" => "1" })
    assert status.success?, err
    assert_equal "Bearer ADMIN-TOKEN", requests.find { |r| r[:method] == "PATCH" && r[:body].include?("archived") }[:bearer]
  end
end
