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
require "time"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"

class TaskBeginTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "add-widget-cache"
  APP = "mcritchie-studio"
  # The resuming instance's identity (opt-in per test — the harness env is
  # session-neutralized) and a rival's. The harness pins TASK_CLAIM_NONCE to
  # "inst-default", so a foreign INSTANCE is any other nonce/session pair.
  SESSION = "sess-begin-resume-1111"
  FOREIGN_SESSION = "sess-begin-foreign-2222"

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
      "TASK_ACTIVITY_BIN" => write_stub("activity-stub", "ACTIVITY"),
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

  def building_task(stage: "building", claim: nil)
    devops = { "worktree_slug" => SLUG, "branch" => "feat/#{SLUG}", "repositories" => [APP] }
    devops.merge!(claim) if claim
    { "slug" => SLUG, "stage" => stage, "title" => "Add Widget Cache",
      "metadata" => { "devops" => devops } }
  end

  # A build-claim devops slice with a lease `expires_in` seconds out — the shape
  # `move building` writes (see test/lib/task_cli_test.rb's twin).
  def claim_of(session:, nonce:, expires_in: 300)
    { "claimed_session" => session, "claim_nonce" => nonce,
      "claim_expires_at" => (Time.now + expires_in).utc.iso8601 }
  end

  def patches_of(requests)
    requests.select { |r| r[:method] == "PATCH" }
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
    refute(requests.any? { |r| r[:method] == "PATCH" },
           "an already-building task must not be re-moved (session-less run: no claim write either — " \
           "the mirror of move's plain-shell degrade; the claim vectors below opt a session IN)")
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

  # --- the resume claim gate ---------------------------------------------------
  # A resume of an already-`building` task skips the child `move building`, so it
  # must run the SAME build-claim gate inline (the review-blocked ownership hole:
  # a bare resume once continued a task another live instance owned).

  def test_begin_resume_with_own_live_claim_proceeds_and_renews
    requests, _out, err, status, lines = run_begin(
      [SLUG],
      existing: building_task(claim: claim_of(session: SESSION, nonce: "inst-default")),
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "resuming a task THIS instance holds must proceed, got:\n#{err}"
    renewal = patches_of(requests).last
    assert renewal, "the resume must renew the claim it already holds"
    body = JSON.parse(renewal[:body])
    refute body.key?("stage"), "an already-building task must not be re-moved"
    assert_equal SESSION, body.dig("devops", "claimed_session")
    assert_equal "inst-default", body.dig("devops", "claim_nonce")
    steps = lines.map(&:first)
    assert_includes steps, "WORKTREE"
    assert_includes steps, "PREFLIGHT"
  end

  def test_begin_resume_refuses_a_live_foreign_claim
    requests, _out, err, status, lines = run_begin(
      [SLUG],
      existing: building_task(claim: claim_of(session: FOREIGN_SESSION, nonce: "inst-A")),
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    refute status.success?, "a resume against a live FOREIGN claim must refuse (non-zero exit)"
    assert_match(/different live instance/i, err, "the refusal must say who holds it")
    assert_match(/…#{FOREIGN_SESSION[-4..]}/, err, "the refusal must name the holder")
    assert_includes err, "bin/task begin #{SLUG} --steal",
                    "the steal hint must name begin's OWN resume command, not the move's"
    assert_empty patches_of(requests), "a refused resume must write NOTHING to the board"
    assert_empty lines, "the gate must refuse BEFORE any worktree/preflight step touches the holder's desk"
  end

  def test_begin_resume_with_steal_takes_the_claim
    requests, _out, err, status, lines = run_begin(
      [SLUG, "--steal"],
      existing: building_task(claim: claim_of(session: FOREIGN_SESSION, nonce: "inst-A")),
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "--steal must let the resume through, got:\n#{err}"
    body = JSON.parse(patches_of(requests).last[:body])
    assert_equal SESSION, body.dig("devops", "claimed_session"),
                 "the steal must durably TRANSFER the claim to the stealer's instance"
    assert_equal "inst-default", body.dig("devops", "claim_nonce")
    refute_nil Time.parse(body.dig("devops", "claim_expires_at")), "a fresh lease is written"
    assert_includes lines.map(&:first), "PREFLIGHT"
  end

  def test_begin_resume_reclaims_an_expired_foreign_lease
    # Fail-open parity with the move's gate: an expired (dead-session) lease is
    # adopted silently — no --steal, no refusal.
    requests, _out, err, status, = run_begin(
      [SLUG],
      existing: building_task(claim: claim_of(session: FOREIGN_SESSION, nonce: "inst-A", expires_in: -30)),
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "an expired lease is silently reclaimable on resume, got:\n#{err}"
    body = JSON.parse(patches_of(requests).last[:body])
    assert_equal SESSION, body.dig("devops", "claimed_session")
  end

  def test_begin_forwards_steal_to_the_child_move
    # A DESIGNED task's claim gate rides the child `move building`; begin must
    # forward --steal so the one flag overrides the gate on BOTH paths.
    requests, _out, err, status, = run_begin(
      [SLUG, "--steal"],
      existing: building_task(stage: "designed", claim: claim_of(session: FOREIGN_SESSION, nonce: "inst-A")),
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "begin --steal must ride into the child move's gate, got:\n#{err}"
    move = patches_of(requests).find { |r| JSON.parse(r[:body])["stage"] == "building" }
    assert move, "the child move must have claimed the task"
    assert_equal SESSION, JSON.parse(move[:body]).dig("devops", "claimed_session")
  end

  # --- narration (fast-lane-narrates-activities) -------------------------------
  # begin owns the session's ORIENT activity so the default fast-lane path leaves
  # a task-attributed trail from the first move instead of an Unlabeled gap.

  def test_begin_opens_a_task_attributed_orient_activity
    _requests, _out, _err, status, lines = run_begin(
      [SLUG], existing: building_task, env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?
    activity = lines.find { |l| l[0] == "ACTIVITY" }
    assert activity, "begin must open an activity, got markers: #{lines.map(&:first).inspect}"
    assert_equal "start", activity[1], "the orient activity is opened, not closed"
    assert_includes activity, "Explore", "the orient activity is an Explore"
    assert_equal SLUG, activity[activity.index("--task") + 1], "the orient must be task-attributed"
  end

  def test_begin_narration_is_non_fatal_when_the_activity_cli_fails
    _requests, _out, _err, status, lines = run_begin(
      [SLUG], existing: building_task,
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "FAIL_ACTIVITY" => "1" }
    )

    assert status.success?, "a failing narration CLI must never fail begin"
    assert(lines.any? { |l| l[0] == "PREFLIGHT" }, "begin still runs its real steps")
  end

  def test_begin_without_a_session_does_not_narrate
    # Plain-shell / CI degrade: no session identity ⇒ no orient (nothing to
    # attribute to), mirroring the claim gate's session-less posture.
    _requests, _out, _err, status, lines = run_begin([SLUG], existing: building_task)

    assert status.success?
    refute(lines.any? { |l| l[0] == "ACTIVITY" }, "a session-less begin must not narrate")
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
