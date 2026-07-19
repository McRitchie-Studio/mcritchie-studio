# frozen_string_literal: true

# [integration] Harness tests for `bin/task begin` — the fast-lane session-start
# wrapper (create → agent-worktree new → bind-task → move building →
# session-preflight, one command, resumable). Follows the two house patterns
# together: the board is a localhost stub HTTP server (test/lib/task_cli_test.rb)
# so the create/claim writes are asserted as real requests — including the child
# `move building` the wrapper spawns — while the worktree/preflight tools are
# logging stubs via the TASK_BEGIN_* seams (test/lib/fast_check_test.rb). The
# slug derivation is unit-tested in test/lib/fast_lane_test.rb.
# Run directly:
#   ruby -Itest test/lib/task_begin_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"

class TaskBeginTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "add-widget-cache"
  APP = "mcritchie-studio"

  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("task-begin-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # The fake projects root TASK_BEGIN_PROJECTS_DIR points at, with the task's
  # worktree dir (and its .agent-context.json) already on disk — the state
  # agent-worktree `new` leaves behind; the stub worktree bin only logs.
  def fake_projects_with_worktree
    projects = File.join(sandbox_root, "fake-projects")
    dir = File.join(projects, APP, ".worktrees", SLUG)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, ".agent-context.json"),
               JSON.generate("app_port" => 3004, "local_url" => "http://localhost:3004"))
    [projects, dir]
  end

  # A logging stub for the worktree/preflight seams: "<MARKER>\t<argv...>\t<cwd>"
  # appended to STUB_LOG; exits 1 when FAIL_<MARKER>=1. cwd rides along so the
  # preflight-from-the-worktree contract is assertable.
  def write_stub(name, marker)
    stub = File.join(sandbox_root, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["#{marker}", *ARGV, Dir.pwd].join("\\t")) }
      exit(ENV["FAIL_#{marker}"] == "1" ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run `bin/task begin` against a one-shot stub board. `existing` seeds a task
  # the GET finds (nil → 404 "task not found" until a create POSTs one).
  # Returns [requests, out, err, status, stub_lines].
  def run_begin(args, existing: nil, env: {})
    @task = existing
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }
    projects, = fake_projects_with_worktree
    log = File.join(sandbox_root, "stub.log")

    base_env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default",
      "TASK_BEGIN_WORKTREE_BIN" => write_stub("worktree-stub", "WORKTREE"),
      "TASK_BEGIN_PREFLIGHT_BIN" => write_stub("preflight-stub", "PREFLIGHT"),
      "TASK_BEGIN_PROJECTS_DIR" => projects,
      "STUB_LOG" => log
    }.merge(TaskUsageSandboxEnv.child_env(sandbox_root)).merge(env))

    out, err, status = Open3.capture3(base_env, RbConfig.ruby, BIN, "begin", *args)
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [requests, out, err, status, lines]
  ensure
    server&.close
    thread&.join(1)
  end

  # Minimal HTTP/1.1 board stub: auth, GET task (404 "task not found" until one
  # exists), POST create (stage designed), PATCH stage move (persists).
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

      status, payload = response_for(method, path, body)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path, body)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"

    case method
    when "GET"
      return ["404 Not Found", JSON.generate("error" => "task not found")] if @task.nil?

      ["200 OK", JSON.generate("data" => @task)]
    when "POST"
      parsed = JSON.parse(body)
      @task = { "slug" => parsed["slug"] || "task-abcdef123456", "stage" => "designed",
                "title" => parsed["title"],
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

  def building_task(stage: "building")
    { "slug" => SLUG, "stage" => stage, "title" => "Add Widget Cache",
      "metadata" => { "devops" => { "worktree_slug" => SLUG, "branch" => "feat/#{SLUG}",
                                    "repositories" => [APP] } } }
  end

  # --- the green path ----------------------------------------------------------

  def test_begin_creates_claims_and_preflights_in_one_command
    requests, out, err, status, lines =
      run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP])

    assert status.success?, "expected green begin, got:\n#{err}\n#{out}"

    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    assert create, "begin must create the task"
    posted = JSON.parse(create[:body])
    assert_equal SLUG, posted["slug"],
                 "the title-derived slug must be passed EXPLICITLY — it is the resume key"
    assert_equal "Add Widget Cache", posted["title"]
    assert_equal "feature", posted.dig("devops", "kind"), "kind defaults to feature"
    assert_equal "backend", posted.dig("devops", "shape")

    move = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/#{SLUG}" }
    assert move, "begin must claim the task"
    assert_equal "building", JSON.parse(move[:body])["stage"]

    steps = lines.map { |l| l[0, 2] }
    assert_includes steps, %w[WORKTREE new]
    assert_includes steps, %w[WORKTREE bind-task]
    assert_equal ["new", APP, SLUG], lines.find { |l| l[0] == "WORKTREE" && l[1] == "new" }[1, 3]
    assert_equal ["bind-task", APP, SLUG, SLUG],
                 lines.find { |l| l[0] == "WORKTREE" && l[1] == "bind-task" }[1, 4]

    preflight = lines.find { |l| l[0] == "PREFLIGHT" }
    assert preflight, "begin must run session-preflight"
    assert_equal SLUG, preflight[1]
    assert_equal File.realpath(File.join(sandbox_root, "fake-projects", APP, ".worktrees", SLUG)),
                 File.realpath(preflight.last), "preflight must run FROM the worktree"

    assert_includes out, "worktree: "
    assert_includes out, "port: 3004"
    assert_includes out, "task: http://127.0.0.1:", "the summary must print the task URL"
    assert_includes out, "bin/ship #{SLUG}", "the summary must name the handoff twin"
  end

  # --- resume ------------------------------------------------------------------

  def test_begin_resumes_an_existing_building_task_without_duplicating
    requests, out, err, status, lines = run_begin([SLUG], existing: building_task)

    assert status.success?, "resume must complete, got:\n#{err}\n#{out}"
    refute(requests.any? { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" },
           "resume must never create a duplicate task")
    refute(requests.any? { |r| r[:method] == "PATCH" }, "an already-building task must not be re-moved")
    assert_includes err, "already exists [building]; resuming"
    steps = lines.map(&:first)
    assert_includes steps, "WORKTREE", "the worktree steps still run (they are idempotent)"
    assert_includes steps, "PREFLIGHT"
  end

  def test_begin_by_title_resumes_the_task_it_created_before
    # Same title → same derived slug → the GET finds the prior task: no POST.
    requests, _out, err, status, = run_begin(["--title", "Add Widget Cache"], existing: building_task)

    assert status.success?, err
    refute(requests.any? { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" },
           "rerunning the same begin must RESUME, not mint an auto-suffixed twin")
  end

  # --- guards ------------------------------------------------------------------

  def test_begin_refuses_a_task_past_the_build_seam
    _requests, _out, err, status, lines = run_begin([SLUG], existing: building_task(stage: "submitted"))

    refute status.success?, "a submitted task is past the build seam"
    assert_includes err, "past the build seam"
    assert_empty lines, "no worktree/preflight step may run for a past-seam task"
  end

  def test_begin_without_title_or_slug_dies
    _requests, _out, err, status, = run_begin([])

    refute status.success?
    assert_includes err, "usage: bin/task begin"
  end

  def test_begin_preflight_failure_names_the_resume
    _requests, _out, err, status, lines =
      run_begin([SLUG], existing: building_task, env: { "FAIL_PREFLIGHT" => "1" })

    refute status.success?, "a red preflight must fail the begin"
    assert_includes err, "re-run: bin/task begin #{SLUG}", "the failure must name the resume"
    assert(lines.any? { |l| l[0] == "PREFLIGHT" }, "the preflight must have been attempted")
  end
end
