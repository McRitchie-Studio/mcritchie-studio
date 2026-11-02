# frozen_string_literal: true

# [integration] The intent scout end to end: `bin/task begin` records the owed scout and
# prints the launch, `bin/task scout-brief` reads the notes, and `bin/submit`'s 0/8
# pre-check WARNS with no brief and is quiet once Avi posts one with `bin/task note
# --comment`. Board CLIs are REAL; desk tools, DoR gate and pre-flight are stubs. The
# pre-flight stub fails on purpose, so each submit stops at 2/8, before any push. SOP:
# docs/agents/agents/avi/sops/intent-scout.md.
# History: task avi-intent-scout.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "uri"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/task_usage_sandbox"

class IntentScoutFlowTest < Minitest::Test
  TASK_BIN = File.expand_path("../../bin/task", __dir__)
  SUBMIT_BIN = File.expand_path("../../bin/submit", __dir__)
  SLUG = "price-the-team-tier"
  APP = "mcritchie-studio"

  def setup
    @root = Dir.mktmpdir("intent-scout-flow")
    @task = nil
    @activities = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def teardown
    @server&.close
    @thread&.join(1)
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # --- the stub board ------------------------------------------------------------

  def serve
    loop do
      client = @server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, target, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      board_read = method == "GET" && target.start_with?("/api/v1/activities")
      (client.close; next) if board_read && @activities_fault == :drop
      sleep 4 if board_read && @activities_fault == :hang
      status, payload = respond(method, target, body)
      status, payload = ["500 Internal Server Error", JSON.generate("error" => "boom")] if board_read && @activities_fault == :error
      begin
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      rescue Errno::EPIPE, Errno::ECONNRESET
        nil # the caller gave up waiting (a timeout test); keep serving
      end
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  def respond(method, target, body)
    path, query = target.split("?", 2)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"
    return activities(method, query, body) if path == "/api/v1/activities"
    return ["404 Not Found", JSON.generate("error" => "Not found")] unless path.start_with?("/api/v1/tasks")

    case method
    when "GET"
      return ["404 Not Found", JSON.generate("error" => "task not found")] if @task.nil?

      ["200 OK", JSON.generate("data" => @task)]
    when "POST"
      parsed = JSON.parse(body)
      @task = { "slug" => parsed["slug"], "stage" => "designed", "title" => parsed["title"],
                "metadata" => { "devops" => (parsed["devops"] || {}).merge("worktree_slug" => parsed["slug"]) } }
      ["200 OK", JSON.generate("data" => @task)]
    when "PATCH"
      parsed = JSON.parse(body)
      @task["stage"] = parsed["stage"] if parsed["stage"]
      ["200 OK", JSON.generate("data" => @task)]
    else
      ["404 Not Found", JSON.generate("error" => "Not found")]
    end
  end

  # The activities API: a POST appends, a GET lists newest first, filtered as the
  # board filters (task_slug, activity_type).
  def activities(method, query, body)
    if method == "POST"
      row = JSON.parse(body).merge("slug" => "act-#{@activities.size + 1}")
      @activities << row
      return ["201 Created", JSON.generate("data" => row)]
    end

    params = URI.decode_www_form(query.to_s).to_h
    rows = @activities.reverse.select do |row|
      (params["task_slug"].nil? || row["task_slug"] == params["task_slug"]) &&
        (params["activity_type"].nil? || row["activity_type"] == params["activity_type"])
    end
    ["200 OK", JSON.generate("data" => rows)]
  end

  # --- the children ----------------------------------------------------------------

  def stub(name, body)
    path = File.join(@root, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    FileUtils.chmod("+x", path)
    path
  end

  def projects
    @projects ||= begin
      dir = File.join(@root, "fake-projects")
      desk = File.join(dir, APP, ".worktrees", SLUG)
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".agent-context.json"), JSON.generate("app_port" => 3019))
      dir
    end
  end

  def board_env(extra = {})
    OutboundSeams.env({
      "TASK_API_BASE" => "http://127.0.0.1:#{@server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default",
      "TASK_ACTIVITY_BIN" => stub("activity-stub", "exit 0"),
      "TASK_BEGIN_WORKTREE_BIN" => stub("worktree-stub", "exit 0"),
      "TASK_BEGIN_PREFLIGHT_BIN" => stub("preflight-stub", "exit 0"),
      "TASK_BEGIN_PROJECTS_DIR" => projects
    }.merge(TaskUsageSandboxEnv.child_env(@root)).merge(extra))
  end

  def task(*args, env: {})
    Open3.capture3(board_env(env), RbConfig.ruby, TASK_BIN, *args)
  end

  # A clean git repo, so submit's 1/8 commit has nothing to do and 2/8 is reached.
  def ship_root
    @ship_root ||= begin
      dir = File.join(@root, "work")
      FileUtils.mkdir_p(dir)
      system("git", "-C", dir, "init", "-q", "-b", "feat/#{SLUG}", out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "app.rb"), "puts :v1\n")
      system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q",
             "-m", "init", out: File::NULL, err: File::NULL)
      dir
    end
  end

  def submit(task_bin: TASK_BIN, env: {})
    Open3.capture3(board_env({
      "SHIP_ROOT" => ship_root,
      "SHIP_TASK_BIN" => task_bin,
      "SHIP_DOR_CHECK_BIN" => stub("dor-stub", "exit 0"),
      "SHIP_FAST_CHECK_BIN" => stub("fast-stub", "exit 1"),
      "SHIP_GH_BIN" => stub("gh-stub", "exit 1"),
      "SHIP_ACTIVITY_BIN" => stub("ship-activity-stub", "exit 0")
    }.merge(env)), RbConfig.ruby, SUBMIT_BIN, SLUG)
  end

  # A bin/task that answers `scout-brief` with `body` and passes every other
  # subcommand to the real bin/task.
  def task_wrapper(name, body)
    stub(name, "if ARGV.first == \"scout-brief\"\n#{body}\nend\nexec(#{RbConfig.ruby.inspect}, #{TASK_BIN.inspect}, *ARGV)")
  end

  def begun_task
    @task = { "slug" => SLUG, "stage" => "building", "title" => "Price The Team Tier",
              "metadata" => { "devops" => { "worktree_slug" => SLUG } } }
  end

  # --- the flow --------------------------------------------------------------------

  def test_begin_then_submit_warns_without_a_brief_and_is_quiet_with_one
    out, err, status = task("begin", "--title", "Price The Team Tier", "--repo", APP, "--shape", "backend",
                            "--risk", "copy", "--accept", "The Team tier reads nine hundred",
                            "--test", "[unit] the stack view")
    assert status.success?, "begin must succeed:\n#{err}\n#{out}"
    assert_includes out, "scout: Avi owes this task an intent scout"
    assert_equal [IntentScoutFlowTest::SLUG], @activities.map { |a| a["task_slug"] }.uniq
    assert @activities.last["description"].start_with?("INTENT SCOUT OWED:"), "begin records the owed scout"

    _out, err, status = task("scout-brief", SLUG)
    assert_equal 2, status.exitstatus, "the owed note is not a brief:\n#{err}"
    assert_includes err, "no intent-scout brief on #{SLUG}"

    _out, without_err, without = submit
    assert_includes without_err, "WARNING: no intent-scout brief on #{SLUG}"
    assert_includes without_err, "docs/agents/agents/avi/sops/intent-scout.md"
    assert_includes without_err, "2/8 pre-flight", "the warning never stopped the ship"

    out, err, status = task("note", SLUG, "--comment",
                            "INTENT SCOUT BRIEF: SAME INTENT, DO NOW - test/views/stack_view_test.rb pins the old price. " \
                            "WIDER SCOPE, FOLLOW-UP - none.", "--agent", "avi")
    assert status.success?, "#{err}\n#{out}"

    out, err, status = task("scout-brief", SLUG)
    assert status.success?, "the posted brief must read back:\n#{err}"
    assert_includes out, "test/views/stack_view_test.rb"

    _out, with_err, with = submit
    refute_includes with_err, "WARNING: no intent-scout brief"
    assert_includes with_err, "0/8 scout — an intent-scout brief is on the task"

    assert_equal 1, without.exitstatus, "the failing pre-flight stub stops both runs at 2/8:\n#{without_err}"
    assert_equal without.exitstatus, with.exitstatus, "the brief must not change submit's exit status"
  end

  # --- scout-brief on a board error exits 1, never 2 ("no brief yet") ------------

  def test_scout_brief_exits_one_when_the_board_answers_an_error
    @activities_fault = :error
    _out, err, status = task("scout-brief", SLUG)

    assert_equal 1, status.exitstatus, "a board error is not 'no brief yet':\n#{err}"
    refute_includes err, "no intent-scout brief on"
  end

  def test_scout_brief_exits_one_on_a_network_error
    @activities_fault = :drop
    _out, err, status = task("scout-brief", SLUG)

    assert_equal 1, status.exitstatus, err
    assert_includes err, "could not read #{SLUG}'s notes for an intent-scout brief"
  end

  def test_scout_brief_exits_one_when_the_board_read_times_out
    @activities_fault = :hang
    _out, err, status = task("scout-brief", SLUG, env: { "INTENT_SCOUT_TIMEOUT" => "1" })

    assert_equal 1, status.exitstatus, err
    assert_includes err, "Net::ReadTimeout"
  end

  # --- submit's scout read: every failure warns and the ship carries on -----------

  def test_submit_names_an_older_bin_task_with_no_scout_brief_subcommand
    begun_task
    old = task_wrapper("old-task", "warn \"Usage:\\n  bin/task list [--stage S]\"\nexit 1")
    _out, err, = submit(task_bin: old)

    assert_includes err, "has no scout-brief subcommand (it is older than this bin/submit)"
    refute_includes err, "could not read #{SLUG}'s notes", "the version skew is not a board problem"
    assert_includes err, "2/8 pre-flight", "the warning never stopped the ship"
  end

  def test_submit_survives_a_scout_brief_child_that_dies
    begun_task
    dying = task_wrapper("dying-task", "Process.kill(\"KILL\", Process.pid)")
    _out, err, = submit(task_bin: dying)

    assert_includes err, "WARNING: could not read #{SLUG}'s notes for an intent-scout brief"
    assert_includes err, "2/8 pre-flight"
  end

  def test_submit_bounds_a_hung_scout_brief_child
    begun_task
    hung = task_wrapper("hung-task", "sleep 30")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, = submit(task_bin: hung, env: { "INTENT_SCOUT_SUBMIT_TIMEOUT" => "1" })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_includes err, "intent-scout brief read for #{SLUG} passed its 1s deadline"
    assert_includes err, "2/8 pre-flight"
    assert elapsed < 25, "the deadline bounds submit (took #{elapsed.round(1)}s)"
  end
end
