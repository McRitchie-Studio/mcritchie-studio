# frozen_string_literal: true

# [integration] `bin/task begin` end to end on a machine that holds a harness key
# (docs/agents/system/agent-sessions-design.md, section 9, questions 4 to 6). The
# board is a localhost stub that records the bearer on every request, and the key
# sits in a tmpdir projects root; the worktree and preflight tools are logging
# stubs (the house pattern of test/lib/task_begin_test.rb).
#
# On a keyed machine begin reads, creates, claims and logs in with the key and
# never exchanges the shared secret; its owed note rides the login it minted. A
# machine with no key, or whose key the board refuses, still presents the
# shared token (question 6).

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "time"
require_relative "../support/session_env"
require_relative "../support/task_usage_sandbox"

class TaskBeginHarnessKeyTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "add-widget-cache"
  APP = "mcritchie-studio"
  KEY = "THE-HARNESS-KEY"
  SHARED = "SHARED-BEARER"
  LOGIN = "DESK-LOGIN"
  SESSION = "sess-begin-keyed-1111"
  CREATE = ["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP,
            "--risk", "auth", "--accept", "Widget cache answers", "--test", "[unit] cache hit"].freeze

  def setup
    @root = Dir.mktmpdir("task-begin-key")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def stub(name, marker)
    path = File.join(@root, name)
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      exit 0
    RUBY
    FileUtils.chmod("+x", path)
    path
  end

  # Run begin against the stub board. `key:` writes the machine's harness key into
  # the projects root the child reads; `refuse_key:` makes the board answer it 401
  # (revoked). Returns [requests, out, err, status].
  def run_begin(key: true, refuse_key: false)
    @task = nil
    @refuse_key = refuse_key
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests) }
    projects = File.join(@root, "fake-projects")
    desk = File.join(projects, APP, ".worktrees", SLUG)
    FileUtils.mkdir_p(desk)
    File.write(File.join(desk, ".agent-context.json"), JSON.generate("app_port" => 3004))

    sandbox = TaskUsageSandboxEnv.child_env(@root)
    if key
      File.write(File.join(sandbox["CLAUDE_PROJECTS_DIR"], ".agents", "harness-key.json"),
                 JSON.generate("slug" => "sess-key", "label" => "studio-mac", "token" => KEY))
    end
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default",
      "CLAUDE_CODE_SESSION_ID" => SESSION,
      "TASK_BEGIN_WORKTREE_BIN" => stub("worktree-stub", "WORKTREE"),
      "TASK_BEGIN_PREFLIGHT_BIN" => stub("preflight-stub", "PREFLIGHT"),
      "TASK_ACTIVITY_BIN" => stub("activity-stub", "ACTIVITY"),
      "TASK_BEGIN_PROJECTS_DIR" => projects,
      "STUB_LOG" => File.join(@root, "stub.log")
    }.merge(sandbox))
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, "begin", *CREATE)
    [requests, out, err, status]
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
      bearer = headers["authorization"].to_s.sub(/\ABearer\s+/, "")
      requests << { method: method, path: path, body: body, bearer: bearer }
      status, payload = answer(method, path, body, bearer)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  def answer(method, path, body, bearer)
    return ["200 OK", JSON.generate("token" => SHARED)] if path == "/api/v1/auth"
    if bearer == KEY && @refuse_key
      return ["401 Unauthorized", JSON.generate("error" => "agent session sess-key was revoked", "error_code" => "SESSION_ENDED")]
    end
    if path == "/api/v1/agent_sessions"
      data = { "slug" => "sess-desk", "soul" => "pokemon", "tier" => "studio", "task_slug" => SLUG,
               "expires_at" => (Time.now + 3600).utc.iso8601, "token" => LOGIN }
      return ["201 Created", JSON.generate("data" => data)]
    end
    return ["201 Created", JSON.generate("data" => { "slug" => "act-1" })] if path == "/api/v1/activities"

    case method
    when "GET"
      @task ? ["200 OK", JSON.generate("data" => @task)] : ["404 Not Found", JSON.generate("error" => "task not found")]
    when "POST"
      parsed = JSON.parse(body)
      @task = { "slug" => parsed["slug"], "stage" => "designed", "title" => parsed["title"],
                "metadata" => { "devops" => parsed["devops"] || {} } }
      ["200 OK", JSON.generate("data" => @task)]
    when "PATCH"
      parsed = JSON.parse(body)
      @task["stage"] = parsed["stage"] if parsed["stage"]
      actor = parsed.dig("event", "actor").to_s
      @task["metadata"]["devops"] = @task["metadata"]["devops"].merge("built_by" => actor) unless actor.empty?
      ["200 OK", JSON.generate("data" => @task)]
    else
      ["404 Not Found", JSON.generate("error" => "Not found")]
    end
  end

  def find(requests, method, path)
    requests.find { |r| r[:method] == method && r[:path] == path }
  end

  def test_begin_on_a_keyed_machine_creates_claims_and_logs_in_with_the_key_and_never_the_secret
    requests, out, err, status = run_begin

    assert status.success?, "expected green begin, got:\n#{err}\n#{out}"
    assert_nil find(requests, "POST", "/api/v1/auth"), "a keyed machine never exchanges the shared secret"
    assert_equal KEY, find(requests, "POST", "/api/v1/tasks")&.dig(:bearer), "the create presents the key"
    claim = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/#{SLUG}" }
    assert_equal "building", JSON.parse(claim[:body])["stage"]
    assert_equal KEY, claim[:bearer], "the claim presents the key"
    assert_equal KEY, find(requests, "POST", "/api/v1/agent_sessions")&.dig(:bearer), "the login mint presents the key"
    assert_equal LOGIN, find(requests, "POST", "/api/v1/activities")&.dig(:bearer), "the owed note rides the login begin minted"

    reads = requests.select { |r| r[:method] == "GET" }
    refute_empty reads
    assert(reads.all? { |r| r[:bearer] == KEY }, "every read presents the key: #{reads.map { |r| [r[:path], r[:bearer]] }}")
    assert_empty requests.map { |r| r[:bearer] } - [KEY, LOGIN], "nothing presented the shared bearer"
    assert_includes err, "begin login — pokemon logged in to #{SLUG}"
  end

  def test_begin_on_a_machine_with_no_key_presents_the_shared_token
    requests, out, err, status = run_begin(key: false)

    assert status.success?, "expected green begin, got:\n#{err}\n#{out}"
    assert find(requests, "POST", "/api/v1/auth"), "a machine with no key exchanges the secret"
    assert_equal SHARED, find(requests, "POST", "/api/v1/tasks")&.dig(:bearer)
    assert_equal SHARED, find(requests, "POST", "/api/v1/agent_sessions")&.dig(:bearer)
    refute_includes requests.map { |r| r[:bearer] }, KEY
  end

  def test_a_refused_key_falls_back_to_the_shared_token_and_says_so_once_per_process
    requests, out, err, status = run_begin(refuse_key: true)

    assert status.success?, "expected green begin, got:\n#{err}\n#{out}"
    create = requests.select { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }.map { |r| r[:bearer] }
    assert_equal [KEY, SHARED], create, "the key first, then the shared token"
    assert_equal SHARED, requests.reverse.find { |r| r[:path] == "/api/v1/agent_sessions" }[:bearer]
    # Said once per process: begin, and the child `move building` it runs.
    assert_equal 2, err.scan("this machine's harness key was refused (agent session sess-key was revoked); using the shared token").size,
                 err
  end
end
