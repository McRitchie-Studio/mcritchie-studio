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
require_relative "../support/fake_desk"

class TaskBeginTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "add-widget-cache"
  APP = "mcritchie-studio"
  # The resuming instance's identity (opt-in per test — the harness env is
  # session-neutralized) and a rival's. The harness pins TASK_CLAIM_NONCE to
  # "inst-default", so a foreign INSTANCE is any other nonce/session pair.
  # The metadata every shape requires at create (guard catalog row 4.4).
  CREATE_METADATA = ["--risk", "devops", "--accept", "Widget cache answers", "--test", "[unit] cache hit"].freeze
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
      exit(Integer(ENV.fetch("FAIL_#{marker}", "0")))
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run `bin/task begin` against a one-shot stub board. `existing` seeds a task
  # the GET finds (nil → 404 "task not found" until a create POSTs one).
  # Returns [requests, out, err, status, stub_lines].
  # merged: true reads stdout and stderr as ONE stream (Open3.capture2e), the only
  # way to prove what prints LAST; `out` is then that stream and `err` is "".
  def run_begin(args, existing: nil, env: {}, fail_activities: false, merged: false)
    @task = existing
    @fail_activities = fail_activities
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

    if merged
      out, status = Open3.capture2e(base_env, RbConfig.ruby, BIN, "begin", *args)
      err = ""
    else
      out, err, status = Open3.capture3(base_env, RbConfig.ruby, BIN, "begin", *args)
    end
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

      # A network error on the owed note: the board drops the connection unanswered.
      (client.close; next) if @fail_activities == :drop && path == "/api/v1/activities"

      status, payload = response_for(method, path, body)
      begin
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      rescue Errno::EPIPE, Errno::ECONNRESET
        nil # the caller gave up waiting (a timeout test); keep serving
      end
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path, body)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"
    # Task notes: begin posts the intent-scout OWED note here. Kept apart from the task
    # create below, which would otherwise read any POST as a new task.
    if path == "/api/v1/activities"
      sleep 4 if @fail_activities == :hang # past the scout's deadline, so the caller times out
      return ["500 Internal Server Error", JSON.generate("error" => "boom")] if @fail_activities == true

      return ["201 Created", JSON.generate("data" => JSON.parse(body).merge("slug" => "act-1"))]
    end

    # begin logs the builder's desk in (desk_login) once it names a soul, which every
    # begin now does (the pokemon default). That login is task_begin_login_test.rb's
    # subject; here it is refused, so its POST is never read as a task create.
    if path.start_with?("/api/v1/agent_sessions")
      return ["404 Not Found", JSON.generate("error" => "no agent sessions in this stub")]
    end

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
      if path.end_with?("/unblock")
        # The board refuses an escalation 409 (Task#builder_unblock_refusal).
        return ["409 Conflict", JSON.generate("error" => "carries an escalation, which only Alex McRitchie answers")] if @task["escalated"]

        @unblocked_by = JSON.parse(body)["by"]
        @task.delete("blocked_at")
        return ["200 OK", JSON.generate("data" => @task)]
      end

      parsed = JSON.parse(body)
      @task["stage"] = parsed["stage"] if parsed["stage"]
      # Rule 1 of Task#builder_to_stamp, and ONLY rule 1: an explicit soul actor on
      # the claim becomes devops.built_by. The desk-identity tests read it back, so
      # a stub that never stamped would make every "which soul did begin stamp"
      # assertion vacuous.
      actor = parsed.dig("event", "actor").to_s
      if actor.match?(/\A[a-z]+(?:-[a-z]+)*\z/)
        (@task["metadata"] ||= {})["devops"] = (@task.dig("metadata", "devops") || {}).merge("built_by" => actor)
      end
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

  # A desk bound to SLUG under the projects root the child process reads
  # (CLAUDE_PROJECTS_DIR, via TaskUsageSandboxEnv.child_env).
  def foreign_desk!(dirty: true, session: FOREIGN_SESSION)
    FakeDesk.build(File.join(sandbox_root, "projects"), task_slug: SLUG, session: session, dirty: dirty)
  end

  def patches_of(requests)
    requests.select { |r| r[:method] == "PATCH" }
  end

  # --- the green path ----------------------------------------------------------

  def test_begin_creates_claims_and_preflights_in_one_command
    requests, out, err, status, lines =
      run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP, *CREATE_METADATA])

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
    assert_includes out, "bin/submit #{SLUG}", "the summary must name the handoff twin"
  end

  # [unit] begin invokes preflight against the WORKTREE root — the
  # begin-preflight-wrong-root bug. begin ran the PRIMARY's copy of
  # session-preflight (BinHelpers.bin_for resolves it relative to bin/task's own
  # dir), and session-preflight resolves its root from __dir__, so `chdir: worktree`
  # was cosmetic — it silently inspected the PRIMARY. That is a false GREEN (a desk
  # it never examined reads "OK") and, whenever the primary drifts behind accepted
  # (routine), a false RED that EXITS begin non-zero. The fix pins the inspected
  # root by passing --root <worktree>; assert that handle is present and points at
  # the task's worktree, not the primary.
  def test_begin_pins_preflight_root_to_the_worktree
    _requests, _out, err, status, lines = run_begin([SLUG], existing: building_task)

    assert status.success?, "expected green begin, got:\n#{err}"
    preflight = lines.find { |l| l[0] == "PREFLIGHT" }
    assert preflight, "begin must run session-preflight"

    argv = preflight[1...-1] # drop the MARKER (first) and the trailing cwd (last)
    root_idx = argv.index("--root")
    assert root_idx, "begin must pass --root to pin preflight to the worktree, got argv: #{argv.inspect}"

    worktree = File.realpath(File.join(sandbox_root, "fake-projects", APP, ".worktrees", SLUG))
    assert_equal worktree, File.realpath(argv[root_idx + 1]),
                 "preflight's --root must be the task worktree, not the primary checkout"
  end

  # [integration] THE LAST LINE BEGIN PRINTS IS AN INSTRUCTION, AND IT MUST RESOLVE.
  # begin used to close with `hand off with: bin/submit <slug>` — the BARE form, which
  # resolves only from a hub desk. Every fast-lane script lives in mcritchie-studio/bin
  # alone, so a builder on a turf-monster or rolio desk who followed the tool's own
  # hint got `nohup: bin/submit: No such file or directory`. PR #1334 fixed the same
  # sentence in the docs; this pins the half the TOOL speaks, which is the half that
  # wins, because it speaks last and at the moment of action.
  #
  # THE ASSERTION IS KEYED ON THE FILESYSTEM, NOT THE WORDING: whatever begin prints,
  # the script named must be an absolute path to an existing executable, and the desk
  # named must be the task's worktree — the cwd is the other half of the instruction
  # (bin/submit roots at the cwd's git toplevel and RE-ROOTS at the desk loudly rather than
  # refusing, and dying with the root guard's refusal only when no desk resolves; the cert
  # WRITERS run by hand afterwards refuse ANY foreign root). Remedy.handoff's
  # own arms are unit-tested in test/lib/fast_lane_test.rb; THIS test is the wiring, and
  # it is what reddens if the bare form is ever restored here.
  def test_begin_prints_a_handoff_that_resolves_from_the_desk
    _requests, out, err, status, = run_begin([SLUG], existing: building_task)

    assert status.success?, "expected green begin, got:\n#{err}"

    line = out.lines.map(&:strip).find { |l| l.start_with?("cd ") }
    assert line, "begin must print a copy-pasteable `cd <desk> && <ship> <slug>` handoff; got:\n#{out}"

    cd, run = line.split(" && ", 2)
    refute_nil run, "the handoff must name the ship invocation as well as the desk: #{line.inspect}"
    ship, slug_arg = run.split(" ", 2)

    worktree = File.realpath(File.join(sandbox_root, "fake-projects", APP, ".worktrees", SLUG))
    assert_equal worktree, File.realpath(cd.sub(/\Acd /, "")),
                 "the handoff must stand the builder in the task's desk"
    assert_equal SLUG, slug_arg.to_s.strip

    assert_equal ship, File.expand_path(ship),
                 "the handoff must name an ABSOLUTE ship path; #{ship.inspect} resolves " \
                 "only from a desk that happens to carry it"
    assert File.executable?(ship),
           "begin printed #{ship}, which is not an executable file — the tool is naming " \
           "a script that does not exist"

    bare = %r{(?<![\w/.-])bin/submit(?![\w-])}
    refute_match bare, line, "begin printed a bare bin/submit — that is the defect"
    assert_match bare, "hand off with: bin/submit #{SLUG}",
                 "the bare pattern does not match the form it forbids, so this proves nothing"
  end

  # --- the intent-scout hand-off (docs/agents/agents/avi/sops/intent-scout.md) ----
  # begin never launches or waits on the scout. It records that one is owed (one
  # best-effort note, on the claim) and prints a paste-ready background launch.

  def owed_notes(requests)
    requests.select { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }.map { |r| JSON.parse(r[:body]) }
  end

  # [integration]
  def test_begin_records_an_owed_scout_and_prints_the_launch_on_the_claim
    requests, out, err, status, = run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP,
                                              *CREATE_METADATA])

    assert status.success?, "expected green begin, got:\n#{err}\n#{out}"
    notes = owed_notes(requests)
    assert_equal 1, notes.size, "one owed note per claim"
    assert_equal SLUG, notes.first["task_slug"]
    assert_equal "comment", notes.first["activity_type"]
    assert notes.first["description"].start_with?("INTENT SCOUT OWED:"), notes.first["description"]

    assert_includes out, "scout: Avi owes this task an intent scout"
    assert_includes out, 'subagent_type: "avi"'
    assert_includes out, "run_in_background: true"
    assert_includes out, "docs/agents/agents/avi/sops/intent-scout.md"
    assert out.index("scout: Avi owes") > out.index("next: build"), "the scout block follows the handoff line"
    assert_includes out, "Auto-launch did not run (", "the suite never launches; the block says why"
  end

  # [integration]
  def test_begin_resuming_a_building_task_prints_the_launch_and_posts_no_second_owed_note
    requests, out, err, status, = run_begin([SLUG], existing: building_task)

    assert status.success?, err
    assert_empty owed_notes(requests), "a resume already carries its owed note"
    assert_includes out, "scout: Avi owes this task an intent scout"
  end

  # [integration]
  def test_a_refused_owed_note_warns_and_begin_still_succeeds
    requests, out, err, status, = run_begin([SLUG], existing: building_task(stage: "designed"), fail_activities: true)

    assert status.success?, "the owed note is best-effort; begin must not fail on it:\n#{err}"
    assert_equal 1, owed_notes(requests).size
    assert_includes err, "could not record the owed intent scout"
    assert_includes out, "scout: Avi owes this task an intent scout", "the launch line still prints"
    assert(requests.any? { |r| r[:method] == "PATCH" }, "the claim landed before the note was tried")
  end

  # [integration] A board that drops the owed-note POST (a network error) costs a
  # warning only; the launch lines still print and begin still succeeds.
  def test_a_network_error_on_the_owed_note_warns_and_begin_still_succeeds
    requests, out, err, status, = run_begin([SLUG], existing: building_task(stage: "designed"), fail_activities: :drop)

    assert status.success?, "a network error on the owed note must not fail begin:\n#{err}"
    assert_equal 1, owed_notes(requests).size
    assert_includes err, "could not record the owed intent scout"
    assert_includes out, "scout: Avi owes this task an intent scout"
  end

  # [integration] A board that hangs on the owed note is cut off at the scout's own
  # short deadline (INTENT_SCOUT_TIMEOUT), not the 30-second board default.
  def test_a_hung_owed_note_times_out_quickly_and_begin_still_succeeds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _requests, out, err, status, = run_begin([SLUG], existing: building_task(stage: "designed"), fail_activities: :hang,
                                                     env: { "INTENT_SCOUT_TIMEOUT" => "1" })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert status.success?, "a hung owed note must not fail begin:\n#{err}"
    assert_match(/could not record the owed intent scout \(Net::ReadTimeout/, err)
    assert_includes out, "scout: Avi owes this task an intent scout"
    assert elapsed < 20, "the scout deadline bounds begin (took #{elapsed.round(1)}s)"
  end

  # [integration] The launch lines print before the owed note is posted.
  def test_the_launch_lines_print_before_the_owed_note_is_posted
    _requests, out, err, status, = run_begin([SLUG], existing: building_task(stage: "designed"), fail_activities: true)

    assert status.success?, err
    assert_includes out, "scout: Avi owes this task an intent scout"
    assert_includes err, "the scout: lines at the end of begin's output", "the warning points DOWN at the lines printed last"
  end

  # --- the auto-launch (scout-launches-itself) ------------------------------------
  # begin launches the scout itself, detached, once; the scout lines print LAST.

  # A stub `claude` that records its argv and cwd. The scout's env is an allow-list,
  # so the record path is baked into the script rather than passed in the env.
  def scout_stub
    record = File.join(sandbox_root, "scout-calls.log")
    stub = File.join(sandbox_root, "claude-stub")
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(#{record.inspect}, "a") { |f| f.puts([Dir.pwd, ENV.key?("CLAUDE_CODE_SESSION_ID"), *ARGV.first(9)].join("\t")) }
      sleep 2 # a real scout runs for minutes; one that exits at once is a failed launch
    RUBY
    FileUtils.chmod("+x", stub)
    [stub, record]
  end

  def wait_for_lines(path, count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      lines = File.exist?(path) ? File.readlines(path, chomp: true) : []
      return lines if lines.size >= count || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def last_line(stream)
    stream.lines.map(&:chomp).reject(&:empty?).last
  end

  # [integration] The default in the suite: no launch, and the paste-ready block is
  # the LAST thing in the merged stream, after the dream bank and the owed note.
  def test_the_scout_block_prints_last_in_the_merged_stream
    # --agent names a builder soul, so the dream bank prints (it is what cut the
    # block on navbar-first-name-only); without one the order proves nothing.
    _requests, out, _err, status, = run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP,
                                               "--agent", "pokemon", *CREATE_METADATA], merged: true)

    assert status.success?, out
    assert_includes last_line(out), "scout-brief #{SLUG}", "the block's read-back line ends begin's output:\n#{out}"
    block_start = out.rindex("scout: Avi owes")
    dream = out.index("**Q: ")
    assert block_start, out
    assert dream, "the dream bank must print in this run, or the order is unproven:\n#{out}"
    assert_operator dream, :<, block_start, "the dream bank prints BEFORE the scout block"
    refute_includes out[block_start..], "**Q: ", "nothing from the dream bank prints after the scout block"
    assert_operator out.index("scout: NOT launched"), :<, out.index("next: build"),
                    "the top summary names the scout too, so head keeps it"
  end

  # [integration] Opted in with a stub CLI: begin launches the scout once, the
  # launched line is last, the child carries no builder session, and a second
  # begin (the re-claim of a building task) spawns nothing more.
  def test_begin_launches_the_stubbed_scout_once_and_a_resume_does_not_relaunch
    stub, record = scout_stub
    home = File.join(sandbox_root, "scout-home")
    config = File.join(sandbox_root, "claude-config")
    FileUtils.mkdir_p(File.join(config, "agents"))
    File.write(File.join(config, "agents", "avi.md"), "---\nname: avi\ndescription: Avi.\n---\n\nYou are Avi.\n")
    env = { "INTENT_SCOUT_AUTO" => "1", "TASK_BEGIN_SCOUT_BIN" => stub, "INTENT_SCOUT_HOME" => home,
            "CLAUDE_CONFIG_DIR" => config,
            "CLAUDE_CODE_SESSION_ID" => "builder-session-1" }
    requests, out, _err, status, = run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP,
                                              *CREATE_METADATA], merged: true, env: env)

    assert status.success?, out
    assert_match(/\Ascout: Avi launched in the background \(pid \d+, log .*#{SLUG}\.log\) - do not launch another/,
                 last_line(out))
    refute_includes out, "Agent(subagent_type", "never both"
    calls = wait_for_lines(record, 1)
    assert_equal 1, calls.size, calls.inspect
    _cwd, session_inherited, *argv = calls.first.split("\t")
    assert_equal "false", session_inherited, "the builder's session must not reach the scout"
    assert_equal "-p", argv[0]
    assert_equal ["--setting-sources", "project", "--strict-mcp-config", "--agents"], argv[2, 4]
    pid = File.read(File.join(home, "#{SLUG}.pid")).strip
    assert_match(/\A\d+\z/, pid)
    owed = owed_notes(requests)
    assert_equal 1, owed.size
    assert_includes owed.first["description"], "pid #{pid}", "the owed note carries the pid"

    _requests, again, _err, status, = run_begin([SLUG], existing: building_task, merged: true, env: env)
    assert status.success?, again
    assert_includes last_line(again), "already launched for this task (pid #{pid}"
    sleep 0.3
    assert_equal 1, File.readlines(record).size, "a resume must not spawn a second scout"
  end

  # --- guard catalog row 4.4: the shape is decided at create --------------------
  # Each refusal writes nothing: no POST, no worktree step, no claim.

  def assert_create_refused(args, message)
    requests, _out, err, status, lines = run_begin(["--title", "Add Widget Cache", *args])

    refute status.success?, "begin must refuse this create:\n#{err}"
    assert_includes err, message
    assert_includes err, "Nothing was written."
    refute(requests.any? { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }, "nothing may be created")
    assert_empty lines, "no worktree or preflight step may run"
  end

  def test_begin_refuses_a_create_with_no_shape
    assert_create_refused(["--repo", APP, *CREATE_METADATA], "begin creates a feature task only with --shape")
  end

  def test_begin_refuses_a_create_with_an_unknown_shape
    assert_create_refused(["--shape", "bogus", "--repo", APP, *CREATE_METADATA], 'unknown --shape "bogus"')
  end

  def test_begin_refuses_a_create_short_of_its_metadata
    assert_create_refused(["--shape", "backend", "--repo", APP], "shape backend needs --accept, --risk, --test")
  end

  # local_url is produced during the build, so a ui shape is created without it.
  def test_begin_creates_a_ui_shape_without_a_local_url
    _requests, out, err, status, = run_begin(["--title", "Add Widget Cache", "--shape", "ui-only", "--repo", APP,
                                              *CREATE_METADATA])

    assert status.success?, "#{err}\n#{out}"
  end

  # An exempt kind's diff is not known at create; dor-check decides at ship.
  def test_begin_creates_an_exempt_kind_without_a_shape
    requests, out, err, status, = run_begin(["--title", "Add Widget Cache", "--kind", "docs", "--repo", APP])

    assert status.success?, "#{err}\n#{out}"
    assert(requests.any? { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" })
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

  # [integration] Guard catalog row 4.2, scoped by decision 6: begin on a REWORK-blocked
  # task is the answer to the block, so it clears it (PATCH .../unblock, naming who).
  def test_begin_on_a_rework_blocked_task_clears_the_block_and_names_who
    blocked = building_task.merge("blocked_at" => "2026-10-07T08:00:00Z", "block_kind" => "rework")
    requests, _out, err, status, = run_begin([SLUG, "--agent", "pokemon"], existing: blocked)

    assert status.success?, "a blocked task's begin must complete, got:\n#{err}"
    assert(requests.any? { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/#{SLUG}/unblock" },
           "begin must clear the block, got: #{requests.map { |r| "#{r[:method]} #{r[:path]}" }.inspect}")
    assert_equal "pokemon", @unblocked_by, "the clear names who made it"
    assert_includes err, "rework block is cleared by this begin (recorded as pokemon)"
    assert_nil @task["blocked_at"]
  end

  # Environment and dependency blocks wait on something outside the desk: no unblock.
  def test_begin_leaves_a_dependency_or_environment_block_standing
    %w[dependency environment].each do |kind|
      blocked = building_task.merge("blocked_at" => "2026-10-07T08:00:00Z", "block_kind" => kind)
      requests, _out, err, status, = run_begin([SLUG], existing: blocked)

      assert status.success?, err
      refute(requests.any? { |r| r[:path].to_s.end_with?("/unblock") }, "a #{kind} block must not be cleared")
      assert_includes err, "carries a #{kind} block, which this begin does not clear"
      assert_equal "2026-10-07T08:00:00Z", @task["blocked_at"]
    end
  end

  # An escalation the board refuses (409) stands, and begin says so and completes.
  def test_begin_reports_a_refused_escalation_and_completes
    blocked = building_task.merge("blocked_at" => "2026-10-07T08:00:00Z", "block_kind" => "rework", "escalated" => true)
    _requests, _out, err, status, = run_begin([SLUG], existing: blocked)

    assert status.success?, err
    assert_includes err, "block stands"
    assert_includes err, "only Alex McRitchie answers"
    assert_equal "2026-10-07T08:00:00Z", @task["blocked_at"]
  end

  # [unit] The control: an unblocked task sends no unblock.
  def test_begin_on_an_unblocked_task_sends_no_unblock
    requests, _out, err, status, = run_begin([SLUG], existing: building_task)

    assert status.success?, err
    refute(requests.any? { |r| r[:path].to_s.end_with?("/unblock") })
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
  # runs the SAME desk rule inline (bin/lib/desk_claim.rb): refuse only a foreign
  # live desk with uncommitted changes, before any worktree step.

  def test_begin_resume_claims_with_the_session_and_no_lease
    requests, _out, err, status, lines = run_begin(
      [SLUG], existing: building_task, env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "resuming with no foreign desk must proceed, got:\n#{err}"
    body = JSON.parse(patches_of(requests).last[:body])
    assert_equal "building", body["stage"], "the claim names stage: building (unchanged, so no event)"
    assert_equal SESSION, body.dig("event", "session"), "and the session making it"
    %w[claimed_session claim_nonce claim_expires_at].each do |key|
      refute body.fetch("devops").key?(key), "the resume writes no lease key (#{key})"
    end
    steps = lines.map(&:first)
    assert_includes steps, "WORKTREE"
    assert_includes steps, "PREFLIGHT"
  end

  def test_begin_resume_refuses_a_foreign_desk_with_uncommitted_work
    desk = foreign_desk!
    requests, _out, err, status, lines = run_begin(
      [SLUG], existing: building_task, env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    refute status.success?, "a resume over another live session's dirty desk must refuse"
    assert_includes err, desk, "the refusal must name the desk"
    assert_includes err, "uncommitted changes"
    assert_includes err, "begin #{SLUG} --steal",
                    "the steal hint must name begin's OWN resume command, not the move's"
    assert_empty patches_of(requests), "a refused resume must write NOTHING to the board"
    assert_empty lines, "the gate must refuse BEFORE any worktree/preflight step"
  end

  def test_begin_resume_with_steal_claims_over_the_foreign_desk
    foreign_desk!
    requests, _out, err, status, lines = run_begin(
      [SLUG, "--steal"], existing: building_task, env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "--steal must let the resume through, got:\n#{err}"
    assert_match(/--steal: claiming #{SLUG} over 1 foreign desk/, err, "the override names what it waives")
    body = JSON.parse(patches_of(requests).last[:body])
    assert_equal SESSION, body.dig("event", "session")
    assert_includes lines.map(&:first), "PREFLIGHT"
  end

  def test_begin_resume_proceeds_over_a_clean_foreign_desk
    foreign_desk!(dirty: false)
    _requests, _out, err, status, = run_begin(
      [SLUG], existing: building_task, env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "a clean foreign desk holds no work to lose, got:\n#{err}"
  end

  def test_begin_forwards_steal_to_the_child_move
    # A DESIGNED task's claim gate rides the child `move building`; begin must
    # forward --steal so the one flag overrides the gate on BOTH paths.
    foreign_desk!
    requests, _out, err, status, = run_begin(
      [SLUG, "--steal"],
      existing: building_task(stage: "designed"),
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )

    assert status.success?, "begin --steal must ride into the child move's gate, got:\n#{err}"
    move = patches_of(requests).find { |r| JSON.parse(r[:body])["stage"] == "building" }
    assert move, "the child move must have claimed the task"
    assert_equal SESSION, JSON.parse(move[:body]).dig("event", "session")
  end

  # --- the desk's git identity (turf-monster-git-identity-wrong) ----------------
  # A hand commit in a desk never passes through bin/submit's per-commit author, so
  # begin stamps the desk itself: `new --soul` at the moment it is cut, then a
  # read-back of the RECORDED claim settles any case --agent did not name.

  def identity_calls(lines)
    lines.select { |l| l[0] == "WORKTREE" && l[1] == "identity" }
  end

  def test_begin_with_agent_stamps_the_desk_as_it_is_cut
    _requests, _out, err, status, lines =
      run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP, *CREATE_METADATA, "--agent", "carl"])

    assert status.success?, "expected green begin, got:\n#{err}"
    new_call = lines.find { |l| l[0] == "WORKTREE" && l[1] == "new" }
    soul_at = new_call.index("--soul")
    assert soul_at, "begin must hand --soul to `new`, got argv: #{new_call.inspect}"
    assert_equal "carl", new_call[soul_at + 1]
    assert_empty identity_calls(lines),
                 "the claim recorded carl, which `new` already stamped — a second stamp is noise"
  end

  def test_begin_without_agent_stamps_the_builder_the_claim_recorded
    # A resume with no --agent keeps the builder already on record (rule 2), so the
    # desk must be stamped with THAT soul — the one bin/submit will author as.
    existing = building_task
    existing["metadata"]["devops"]["built_by"] = "shannon"

    _requests, _out, err, status, lines = run_begin([SLUG], existing: existing)

    assert status.success?, "expected green begin, got:\n#{err}"
    refute_includes lines.find { |l| l[0] == "WORKTREE" && l[1] == "new" }, "--soul",
                    "with no --agent begin was told no builder, so `new` must not guess one"
    assert_equal [["WORKTREE", "identity", APP, SLUG, "shannon"]], identity_calls(lines).map { |l| l[0, 5] }
  end

  def test_begin_without_agent_or_any_builder_defaults_to_pokemon_and_says_so
    # The 2026-10-14 approve-intent-brief-dream incident: a blank author set made
    # the docs reviewer's merge permit refuse. begin now names the general builder.
    requests, _out, err, status, lines = run_begin([SLUG], existing: building_task,
                                                   env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    assert status.success?, "expected green begin, got:\n#{err}"
    assert_equal 1, err.scan("the builder defaults to pokemon").size, "one line names the default:\n#{err}"
    new_call = lines.find { |l| l[0] == "WORKTREE" && l[1] == "new" }
    assert_equal "pokemon", new_call[new_call.index("--soul") + 1], "the desk is cut as the default builder"
    claim = patches_of(requests).map { |r| JSON.parse(r[:body]) }.find { |b| b["stage"] == "building" }
    assert_equal "pokemon", claim.dig("event", "actor"), "the claim stamps built_by through rule 1"
    refute_match(/UNSTAMPED/, err)
  end

  def test_begin_create_without_agent_defaults_to_pokemon_through_the_child_move
    _requests, _out, err, status, lines =
      run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP, *CREATE_METADATA])

    assert status.success?, "expected green begin, got:\n#{err}"
    assert_includes err, "no --agent, so the builder defaults to pokemon"
    new_call = lines.find { |l| l[0] == "WORKTREE" && l[1] == "new" }
    assert_equal "pokemon", new_call[new_call.index("--soul") + 1], "the desk is cut as the default builder"
  end

  def test_the_default_is_the_sessions_acting_soul_when_it_narrates_as_one
    # The sticky marker `bin/agent-activity --agent <soul>` writes; review-claim reads
    # the same one. A session acting as jasper builds as jasper, not as the Pokémon.
    sessions = File.join(sandbox_root, "projects", ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    File.write(File.join(sessions, "#{SESSION}.acting-agent"), "jasper\n")

    _requests, _out, err, status, lines = run_begin([SLUG], existing: building_task,
                                                    env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    assert status.success?, err
    assert_includes err, "the builder defaults to jasper"
    new_call = lines.find { |l| l[0] == "WORKTREE" && l[1] == "new" }
    assert_equal "jasper", new_call[new_call.index("--soul") + 1]
  end

  def test_an_explicit_agent_or_a_recorded_builder_is_never_replaced_by_the_default
    _requests, _out, err, = run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP,
                                       *CREATE_METADATA, "--agent", "carl"])
    refute_includes err, "defaults to pokemon", "--agent overrides the default"

    existing = building_task
    existing["metadata"]["devops"]["built_by"] = "shannon"
    _requests, _out, err, = run_begin([SLUG], existing: existing)
    refute_includes err, "defaults to pokemon", "a recorded builder is kept on a resume"

    assigned = building_task.merge("agent_slug" => "jasper")
    _requests, _out, err, = run_begin([SLUG], existing: assigned)
    refute_includes err, "defaults to pokemon", "a soul assignee is the board's rule 4, not overridden"
  end

  def test_begin_with_no_builder_on_record_says_unstamped_and_stamps_nothing
    # A persona that names no soul blocks the default (the task already says who acts)
    # and stamps nobody, so the read-back is still blank: the UNSTAMPED warning stands.
    existing = building_task
    existing["metadata"]["devops"]["persona"] = "ghost"
    _requests, _out, err, status, lines = run_begin([SLUG], existing: existing)

    assert status.success?, "an unstamped desk is still a whole desk — begin must not die:\n#{err}"
    assert_empty identity_calls(lines), "no soul on record means nothing to stamp — never a guess"
    assert_match(/UNSTAMPED/, err, "the unstamped desk must be announced, not left silent")
    # The worktree bin begin shells is the harness stub here, so key on ITS path —
    # the remedy must name the same executable begin itself runs.
    assert_includes err, "#{File.join(sandbox_root, "worktree-stub")} identity #{APP} #{SLUG} <soul>",
                    "the announcement must name the stamp command"
  end

  def test_a_failed_stamp_warns_and_begin_still_completes
    existing = building_task
    existing["metadata"]["devops"]["built_by"] = "shannon"
    stub = File.join(sandbox_root, "failing-identity-worktree-stub")
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["WORKTREE", *ARGV, Dir.pwd].join("\\t")) }
      exit(ARGV.first == "identity" ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)

    _requests, _out, err, status, lines =
      run_begin([SLUG], existing: existing, env: { "TASK_BEGIN_WORKTREE_BIN" => stub })

    assert status.success?, "a stamp that did not land must not fail a begin past its claim:\n#{err}"
    assert_includes err, "desk identity did not land"
    assert(lines.any? { |l| l[0] == "PREFLIGHT" }, "begin must still preflight the desk")
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
    # THE BANNER ECHOES THE INVOCATION. remedy-hints-second-wave gave every usage banner
    # `$PROGRAM_NAME` — a banner is a synopsis of the grammar the reader JUST TYPED, not
    # a command handed over — so this run, which reaches bin/task by its ABSOLUTE path,
    # is told `usage: /…/bin/task begin`. Keyed on the script the banner names rather
    # than on a bare spelling this harness can never produce.
    banner = err[/usage: (\S+) begin/, 1]

    refute_nil banner, "the no-title/no-slug door must still print its usage banner:\n#{err}"
    assert_equal "task", File.basename(banner), "the banner must name THIS program:\n#{err}"
    assert_equal BIN, banner, "the banner must echo the invocation it was reached by:\n#{err}"
  end

  # Guard catalog row 3.8: the preflight runs BEFORE the claim. When it cannot
  # describe the desk (exit 2) nothing is claimed, and the refusal names the resume.
  def test_begin_preflight_that_cannot_describe_the_desk_refuses_before_the_claim
    requests, _out, err, status, lines =
      run_begin(["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP, *CREATE_METADATA],
                env: { "FAIL_PREFLIGHT" => "2" })

    refute status.success?, "a preflight that cannot describe the desk must refuse the claim"
    # Filesystem-keyed for the reason test/lib/remedy_test.rb spells out:
    # an absolute path CONTAINS "bin/task begin <slug>", so a substring assertion
    # here passes the bare form as readily as the fixed one.
    resume = err[%r{re-run: (\S*/bin/task) begin #{SLUG}}, 1]
    refute_nil resume, "the failure must name the resume:\n#{err}"
    assert File.executable?(resume), "the resume must name a runnable script, got #{resume.inspect}"
    assert_includes err, "nothing was claimed"
    assert(lines.any? { |l| l[0] == "PREFLIGHT" }, "the preflight must have been attempted")
    refute(patches_of(requests).any? { |r| JSON.parse(r[:body])["stage"] == "building" },
           "no claim may be written before a preflight that could not describe the desk")
    assert_equal "designed", @task["stage"]
  end

  # Findings (exit 1) are a report: the claim proceeds and begin completes.
  def test_begin_preflight_findings_are_a_report_and_the_claim_proceeds
    requests, out, err, status, = run_begin(
      ["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP, *CREATE_METADATA],
      env: { "FAIL_PREFLIGHT" => "1" }
    )

    assert status.success?, "findings must not fail begin:\n#{err}\n#{out}"
    assert_includes err, "found work for this desk"
    assert(patches_of(requests).any? { |r| JSON.parse(r[:body])["stage"] == "building" }, "the claim must land")
    assert_equal "building", @task["stage"]
  end

  # The order itself: the preflight is logged before the claim's child move.
  def test_begin_runs_the_preflight_before_the_claim
    _requests, _out, err, status, = run_begin(
      ["--title", "Add Widget Cache", "--shape", "backend", "--repo", APP, *CREATE_METADATA]
    )

    assert status.success?, err
    assert_operator err.index("begin 4/5 preflight"), :<, err.index("begin 5/5 claim"), err
  end
end

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

require "time"
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
      "AGENT_API_TOKEN" => nil, # a parent bin/submit hands one down; this test reads the bearer chain itself
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
