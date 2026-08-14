# frozen_string_literal: true

# Standalone integration test for bin/task's session-resume capture. Shells out
# to bin/task against a localhost stub HTTP server (no Rails, no real network),
# so it deterministically asserts that the CLI stamps devops.session_id +
# session_provider from Claude/Codex session env on `create` and on the move to
# `building` (the claim moment) — and stamps nothing when no session env is set.
#
#   ruby -Itest test/lib/task_cli_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../support/session_env"
# The idle window the desk-keyed heartbeat decides on. Read from the module the
# CLI itself reads, never re-spelled here: a test that pins its own copy of a
# derived threshold goes green while the real one drifts out from under it.
require_relative "../../lib/claim_lease"

class TaskCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  # A REAL past session id — which is exactly why the sandbox exists: its 30MB
  # transcript still sits in the operator's ~/.claude, so an unpinned child globs
  # it and captures 1.9B real tokens under a stub slug. Pinned HOME makes the id
  # inert; the sandbox makes an unpinned run impossible.
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617"
  OTHER_SESSION = "9f9f9f9f-0000-1111-2222-333344445555"

  # One sandbox root per TEST (not per run_task call): a case may invoke the CLI
  # twice and expect the second run to read the baseline the first one wrote.
  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("task-cli-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # Run bin/task against a one-shot stub server; returns [recorded_requests, out].
  # `env` overrides merge onto a clean base (auth secret + base url + skip marker);
  # a nil value deletes that var from the child (used to clear the session vars so
  # the test never depends on a real ambient session).
  def run_task(args, env: {}, stub_devops: { "kind" => "feature" }, stub_stage: "building", chdir: nil, fail_get: nil,
               fail_get_body: nil, stub_persist: true, fail_patch: nil, stub_progress: nil,
               stub_columns: {}, stub_omit_columns: [], stub_bounces: [],
               stub_session_mascot: { "mascot" => "snorlax", "mascot_color" => "#A8A77A", "mascot_emoji" => "🔶",
                                      "app" => "mcritchie-studio", "app_color" => "#B57EDC" },
               stub_agent: { "name" => "Jasper", "status_color" => "#22D3EE", "emoji" => "🧪" })
    # Extra TOP-LEVEL columns on the served record — the fields that are NOT
    # under metadata.devops. The base record mirrors the real API, which renders
    # `task.as_json` and therefore always carries EVERY column key (null when
    # unset); stub_omit_columns removes a key ENTIRELY, which is a genuinely
    # different state from a null one and the only way to exercise the UNREPORTED
    # rendering (an older board, a trimmed serializer).
    @stub_columns = stub_columns
    @stub_omit_columns = Array(stub_omit_columns).map(&:to_s)
    # The qa_feedback rows GET /api/v1/activities serves — the bounce ledger the
    # two-bounce circuit breaker counts before a rework block. Empty = a task with a
    # clean record, which is what every pre-existing case in this file assumes.
    @stub_bounces = Array(stub_bounces)
    # The GET response the stub serves — lets a test seed an existing claim so the
    # move-to-building gate (and the heartbeat) read a real claim state.
    @stub_devops = stub_devops
    @stub_progress = stub_progress
    @stub_stage = stub_stage
    # The board's PERSISTED stage, which a GET reads back. A stage-move PATCH
    # advances it — UNLESS stub_persist is false, which models the false-success
    # bug: the PATCH 200s and echoes the requested stage (the assigned-but-unsaved
    # in-memory record) but the persisted stage never changes, so a read-back
    # still shows the old one. fail_patch forces the PATCH itself to a non-2xx.
    @persisted_stage = stub_stage
    # The board's PERSISTED merged git-location, read back by `bin/task merged`'s
    # verification. A merged PATCH advances it UNLESS stub_persist is false (the
    # false-success shape: 200 + echoed value, but the persisted value never moves).
    @persisted_merged = ""
    @stub_persist = stub_persist
    @fail_patch = fail_patch
    # The POST /api/v1/sessions/:id/mascot response (the eager session-mascot draw).
    @stub_session_mascot = stub_session_mascot
    @stub_agent = stub_agent
    # When set, GET /api/v1/tasks/<slug> returns this non-2xx status — used to
    # force the board-mascot fallback read to fail (a transient 429 / 5xx).
    # fail_get_body overrides the failure body, so the exit-code tests can serve
    # the API's exact "task not found" shape vs a router/route-style 404 page.
    @fail_get = fail_get
    @fail_get_body = fail_get_body
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    # SessionEnv.neutralized: bin/task resolves SessionIdentity for actor/persona
    # defaulting, so the child must name NO session unless a case opts one in via
    # `env:` (which merges on top). See test/support/session_env.rb — without this
    # the CLI reads the LIVE agent session and this file goes red from an agent run.
    #
    # TaskUsageSandboxEnv.child_env: PIN THE WRITE ROOTS. bin/task resolves two
    # stores by fallback — the usage/cost baselines (TASK_USAGE_DIR) and the session
    # marker (CLAUDE_PROJECTS_DIR) — and this file used to pin neither, so a case
    # that opted a session in wrote a fixture row straight into the operator's real
    # cost store (see the sandbox section below for the damage). HOME is pinned with
    # them because it is the READ half: SESSION is a real past session id, and an
    # unpinned HOME let the child glob the operator's actual 30MB transcript.
    # A case may still override any of the three (with_session_transcript does).
    base_env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      # A fixed instance nonce so the CLI never shells out to `ps` in a test; the
      # gate cases override it to play a second / different live instance.
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(sandbox_root)).merge(env))

    spawn_opts = chdir ? { chdir: chdir } : {}
    out, err, status = Open3.capture3(base_env, RbConfig.ruby, BIN, *args, **spawn_opts)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  # Minimal HTTP/1.1 stub: records each request and returns canned JSON. bin/task
  # opens one connection per request (auth, then the task call(s)).
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
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, body: body }

      status, payload = response_for(method, path, body)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  # Returns [status_line, json_body]. Defaults to 200; @fail_get forces the board
  # read (GET /api/v1/tasks/<slug>) to a non-2xx so the board-mascot fallback is
  # exercised under a transient failure — without breaking auth or the PATCH/POST.
  def response_for(method, path, body = nil)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"

    if method == "POST" && path =~ %r{\A/api/v1/sessions/.+/mascot\z}
      return ["200 OK", JSON.generate("data" => @stub_session_mascot)]
    end

    if method == "GET" && path =~ %r{\A/api/v1/agents/[^/]+\z}
      return ["200 OK", JSON.generate("data" => @stub_agent)]
    end

    if @fail_get && method == "GET" && path.start_with?("/api/v1/tasks/")
      return ["#{@fail_get} Service Unavailable", @fail_get_body || JSON.generate("error" => "stubbed board read failure")]
    end

    if @fail_patch && method == "PATCH" && path.start_with?("/api/v1/tasks/")
      return ["#{@fail_patch} Service Unavailable", JSON.generate("error" => "stubbed board write failure")]
    end

    # A stage-move PATCH (PATCH /api/v1/tasks/<slug> carrying "stage"). The server
    # returns the ASSIGNED record, so the response echoes the requested stage —
    # TRUE whether the save persisted or not. In the default persisting mode a
    # later GET reads that stage back; with stub_persist:false the persisted stage
    # does NOT advance (the false-success bug: 200 + echoed stage, but the board
    # still reads the old stage), so the read-back verification must catch it.
    if method == "PATCH" && path =~ %r{\A/api/v1/tasks/[^/]+\z}
      requested = move_stage_of(body)
      if requested
        @persisted_stage = requested if @stub_persist
        return ["200 OK", task_response(requested)]
      end
      # A `bin/task merged` PATCH carries the git-location, no stage. Advance the
      # persisted merged value (unless stub_persist:false models the dropped write)
      # so the CLI's read-back verification reads it back.
      merged = merged_of(body)
      if merged
        @persisted_merged = merged if @stub_persist
        return ["200 OK", task_response(@persisted_stage)]
      end
    end

    # The tasks INDEX (bin/task list): data is an ARRAY, not a single record. Without
    # this the fallback below returns one object and `list` would iterate a Hash.
    if method == "GET" && path =~ %r{\A/api/v1/tasks(\?.*)?\z}
      return ["200 OK", JSON.generate("data" => [])]
    end

    # The ACTIVITIES index — an ARRAY too, and `bin/task block --kind rework` reads
    # it before every bounce (the two-bounce circuit breaker; bin/lib/bounce_ledger.rb).
    # The catch-all below answers a single OBJECT, which the ledger correctly REFUSES
    # as an unreadable answer rather than scoring it zero bounces — so without this
    # branch every rework block in this file dies at the breaker instead of blocking.
    # @stub_bounces lets a case seed prior send-backs and exercise the refusal.
    if method == "GET" && path =~ %r{\A/api/v1/activities(\?.*)?\z}
      rows = @stub_bounces || []
      return ["200 OK", JSON.generate("data" => rows,
                                      "meta" => { "page" => 1, "per_page" => 100,
                                                  "total" => rows.size, "total_pages" => 1 })]
    end

    # The GET in the move read-merge returns an existing task carrying prior
    # devops (configurable per-test via stub_devops), so the test can prove the
    # session stamp / claim is MERGED, not a wipe, and seed an existing claim. Its
    # stage is the board's PERSISTED stage, which the move read-back verifies.
    ["200 OK", task_response(@persisted_stage)]
  end

  # The stage a PATCH body requests, or nil when the body carries none (a devops-
  # only PATCH — update / heartbeat / block — never advances the persisted stage).
  def move_stage_of(body)
    return nil if body.to_s.empty?

    JSON.parse(body)["stage"]
  rescue JSON::ParserError
    nil
  end

  # The git-location a `bin/task merged` PATCH requests, or nil when the body
  # carries none (so an ordinary stage/devops PATCH never touches @persisted_merged).
  def merged_of(body)
    return nil if body.to_s.empty?

    JSON.parse(body)["merged"]
  rescue JSON::ParserError
    nil
  end

  # The API projects the PROGRESS fact alongside the claim (see Api::V1::TasksController
  # #task_json), so the claim gate can tell a second agent what the holder has actually
  # PRODUCED — not merely that its terminal is painting. @stub_progress seeds it.
  def task_response(stage)
    data = {
      "slug" => "demo-task", "stage" => stage, "merged" => @persisted_merged,
      "release_slug" => nil,
      "metadata" => { "devops" => @stub_devops }
    }.merge(@stub_columns || {})
    Array(@stub_omit_columns).each { |key| data.delete(key) }
    JSON.generate("data" => data.merge(@stub_progress || {}))
  end

  def devops_of(request)
    JSON.parse(request[:body]).fetch("devops", {})
  end

  def test_create_stamps_session_from_claude_env
    requests, = run_task(
      ["create", "--title", "Session demo task", "--kind", "feature"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create, "expected a POST /api/v1/tasks"
    devops = devops_of(create)
    assert_equal SESSION, devops["session_id"]
    assert_equal "claude", devops["session_provider"]
    assert_equal "feature", devops["kind"]
  end

  def test_create_stamps_session_from_codex_thread_env
    requests, = run_task(
      ["create", "--title", "Session demo task", "--kind", "feature"],
      env: { "CODEX_THREAD_ID" => SESSION }
    )
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create, "expected a POST /api/v1/tasks"
    devops = devops_of(create)
    assert_equal SESSION, devops["session_id"]
    assert_equal "codex", devops["session_provider"]
    assert_equal "feature", devops["kind"]
  end

  # --release-slug is RETIRED (release-slug-two-universes). It wrote a devops key
  # that no release code read, while the sweep wrote the same-named column — so the
  # flag could persist a value that looked like release membership and meant
  # nothing. Membership is attached by Release#record_members, never typed.
  # The failure must be at the FLAG (exit nonzero, before any request), not a
  # request the server then rejects: the CLI should not offer the wrong door.
  def test_create_rejects_the_retired_release_slug_flag
    requests, _out, err, status = run_task(
      ["create", "--title", "Release slug task", "--release-slug", "rel-2026-06-27-docs"]
    )

    refute status.success?, "a retired flag must exit nonzero, not quietly write a shadow"
    assert_match(/unknown flag "--release-slug"/, err)
    assert_empty requests.select { |r| r[:method] == "POST" },
                 "nothing should be created from a rejected flag"
  end

  def test_create_rejects_the_retired_release_train_flag
    _requests, _out, err, status = run_task(
      ["create", "--title", "Release train task", "--release-train", "rel-2026-06-27-docs"]
    )

    refute status.success?
    assert_match(/unknown flag "--release-train"/, err)
  end

  def test_move_to_building_stamps_session_and_preserves_devops
    requests, = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch, "expected a PATCH for the move"
    parsed = JSON.parse(patch[:body])
    assert_equal "building", parsed["stage"]
    assert_equal SESSION, parsed.dig("devops", "session_id")
    assert_equal "claude", parsed.dig("devops", "session_provider")
    # read-merge-write keeps the existing devops field rather than wiping it
    assert_equal "feature", parsed.dig("devops", "kind")
  end

  def test_move_to_building_stamps_codex_thread_and_preserves_devops
    requests, = run_task(
      ["move", "demo-task", "building"],
      env: { "CODEX_THREAD_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch, "expected a PATCH for the move"
    parsed = JSON.parse(patch[:body])
    assert_equal "building", parsed["stage"]
    assert_equal SESSION, parsed.dig("devops", "session_id")
    assert_equal "codex", parsed.dig("devops", "session_provider")
    assert_equal "feature", parsed.dig("devops", "kind")
  end

  def test_create_without_a_session_env_stamps_nothing
    requests, = run_task(["create", "--title", "No session task", "--kind", "feature"])
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create
    devops = devops_of(create)
    refute devops.key?("session_id"), "no session env should stamp no session_id"
    refute devops.key?("session_provider")
  end

  def test_move_to_a_non_building_stage_does_not_stamp_session
    requests, = run_task(
      ["move", "demo-task", "submitted"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    # submitted is not the claim moment → no GET read-merge, no devops sent.
    patch = requests.find { |r| r[:method] == "PATCH" }
    parsed = JSON.parse(patch[:body])
    assert_equal "submitted", parsed["stage"]
    refute parsed.key?("devops"), "non-building moves should not send devops"
  end

  # The mover — not the build session that claimed the task at `building` — owns
  # this transition's actor. So every move defaults event.actor to the running
  # session, since the server no longer backfills actor from devops_session_id.
  def test_move_defaults_event_actor_to_the_running_session
    requests, = run_task(
      ["move", "demo-task", "reviewed"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    event = JSON.parse(patch[:body]).fetch("event")
    assert_equal "cli", event["source"]
    assert_equal SESSION, event["actor"], "move should attribute to the mover's session"
  end

  def test_move_actor_flag_overrides_the_session_default
    requests, = run_task(
      ["move", "demo-task", "reviewed", "--actor", "avi"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    event = JSON.parse(patch[:body]).fetch("event")
    assert_equal "avi", event["actor"], "--actor must override the session default"
  end

  def test_move_without_a_session_stamps_no_actor
    requests, = run_task(["move", "demo-task", "reviewed"])
    patch = requests.find { |r| r[:method] == "PATCH" }
    event = JSON.parse(patch[:body]).fetch("event")
    refute event.key?("actor"), "a plain shell / CI run (no session) stamps no actor"
  end

  # --- a move must never report success on a stage that did not persist --------
  # THE BUG: `bin/task move <slug> submitted` PRINTED "[submitted]" and exited 0
  # while a fresh read still showed "building" — the stage PATCH 200'd (echoing
  # the assigned-but-unsaved in-memory record) but never persisted. The stranded
  # task is invisible to reviewers and skipped by the qa-release sweep, and it
  # once made a supervisor misread the failed write as a rival session re-claiming
  # the task. The move now reads the task back and confirms the persisted stage
  # matches the requested one before reporting success. stub_persist:false models
  # the board that 200s the PATCH but does NOT advance the persisted stage.
  def test_move_that_does_not_persist_exits_nonzero_not_false_success
    requests, out, err, status = run_task(
      ["move", "demo-task", "submitted"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION },
      stub_stage: "building",
      stub_persist: false
    )
    refute status.success?, "a move whose write did not persist must exit nonzero, not report success"
    assert(requests.any? { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" },
           "the move PATCH is still issued")
    assert(requests.any? { |r| r[:method] == "GET" && r[:path] == "/api/v1/tasks/demo-task" },
           "the move reads the task back to VERIFY the transition actually persisted")
    assert_match(/not persist/i, err, "the failure is loud and names the non-persistence")
    assert_match(/building/, err, "and names the stage the board actually still shows")
    refute_match(/\[submitted\]/, out, "it must NOT print the success line for a stage it never reached")
  end

  # The verification must not turn a genuine, persisted move into a false failure:
  # once the read-back CONFIRMS the requested stage, the move still reports success.
  def test_move_that_persists_still_reports_success
    requests, out, _err, status = run_task(
      ["move", "demo-task", "submitted"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION },
      stub_stage: "building" # stub_persist defaults true → the PATCH advances the board
    )
    assert status.success?, "a persisted move still exits 0"
    assert_match(/\[submitted\]/, out, "and prints the confirmed stage")
    assert(requests.any? { |r| r[:method] == "GET" && r[:path] == "/api/v1/tasks/demo-task" },
           "even the happy path reads back to confirm persistence before reporting success")
  end

  # Acceptance #2: a failed board WRITE (a non-2xx stage PATCH) exits nonzero and
  # loud — it must never read as a successful move. api() already dies on a
  # non-2xx; pin it for the mutation path so the "reports success on work it did
  # not do" family can never regress on the write leg either.
  def test_move_with_a_failed_write_exits_nonzero_and_loud
    _requests, out, err, status = run_task(
      ["move", "demo-task", "submitted"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION },
      fail_patch: 503
    )
    refute status.success?, "a non-2xx stage PATCH must exit nonzero, never report success"
    assert_match(%r{PATCH /api/v1/tasks/demo-task -> 503}, err, "the failure names the write and its status")
    refute_match(/\[submitted\]/, out, "no success line for a write that failed")
  end

  def test_block_agent_flag_stamps_the_block_transition_actor
    requests, = run_task(["block", "demo-task", "--kind", "rework", "--feedback", "Needs rework.", "--agent", "shannon"])
    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task/block" }
    refute_nil patch, "expected a PATCH to the block endpoint"

    parsed = JSON.parse(patch[:body])
    assert_equal "rework", parsed["kind"], "block_kind rides the block endpoint (a column now)"
    assert_equal "shannon", parsed["by"], "--agent is the blocker (blocked_by)"
    assert_equal "cli", parsed.dig("event", "source")
    assert_equal "shannon", parsed.dig("event", "actor"), "--agent stamps the →building transition actor"

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    refute_nil note, "expected a qa_feedback activity"
    assert_equal "shannon", JSON.parse(note[:body])["agent_slug"]
  end

  def test_block_summary_rides_into_the_qa_feedback_metadata
    requests, = run_task([
      "block", "demo-task", "--kind", "rework",
      "--summary", "Stage move skips server guard",
      "--feedback", "The stage transition bypasses the server guard; re-gate it before resubmit.",
      "--agent", "shannon"
    ])

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    refute_nil note, "expected a qa_feedback activity"
    body = JSON.parse(note[:body])
    assert_equal "qa_feedback", body["activity_type"]
    assert_equal "The stage transition bypasses the server guard; re-gate it before resubmit.",
                 body["description"], "--feedback stays the details body"
    assert_equal "Stage move skips server guard", body.dig("metadata", "summary"),
                 "--summary rides into the activity metadata (no column)"
  end

  def test_block_details_alias_writes_the_feedback_body
    requests, = run_task([
      "block", "demo-task", "--kind", "rework",
      "--summary", "Missing regression test",
      "--details", "Add a failing test for the nil guard first.",
      "--agent", "shannon"
    ])

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    refute_nil note, "expected a qa_feedback activity from --details"
    body = JSON.parse(note[:body])
    assert_equal "Add a failing test for the nil guard first.", body["description"],
                 "--details is an alias for the feedback body"
    assert_equal "Missing regression test", body.dig("metadata", "summary")
  end

  # SUPERSEDED PREMISE, deliberately rewritten rather than deleted. This used to
  # assert that no --summary meant NO metadata key at all. That stopped being true
  # when the block kind started riding in metadata (the two-bounce circuit breaker
  # reads it back: the block_kind COLUMN is wiped by a compliant resubmission, so
  # the activity row is the only durable record of what kind of block this was).
  # The invariant that actually mattered is preserved and still asserted below —
  # no --summary means no `summary` KEY, which is what makes Activity#block_summary
  # derive a headline from the details for a legacy-shaped block.
  def test_block_without_a_summary_omits_the_summary_key_but_still_stamps_the_kind
    requests, = run_task(["block", "demo-task", "--kind", "rework", "--feedback", "Needs rework.", "--agent", "shannon"])

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    body = JSON.parse(note[:body])
    refute body.dig("metadata").key?("summary"),
           "no --summary means no summary key — Activity#block_summary derives one from the details"
    assert_equal "rework", body.dig("metadata", "kind"),
                 "the kind rides regardless: without it the bounce ledger cannot classify this row"
  end

  # THE TWO-BOUNCE CIRCUIT BREAKER, at the block command's own CLI contract. The
  # deep coverage lives in test/lib/bounce_check_cli_test.rb; this is the seam
  # assertion that belongs beside the other `block` cases — a second send-back is
  # REFUSED before it lands, not warned about after.
  def test_a_rework_block_is_refused_when_a_prior_send_back_exists
    prior = { "created_at" => "2026-08-01T12:00:00Z", "description" => "First send-back",
              "metadata" => { "kind" => "rework", "summary" => "Missing regression test" } }
    requests, _out, err, status = run_task(
      ["block", "demo-task", "--kind", "rework", "--feedback", "Again.", "--agent", "carl"],
      stub_bounces: [prior]
    )

    assert_equal 10, status.exitstatus, "a tripped breaker REFUSES with exit 10: #{err}"
    assert_match(/BREAKER: TRIPPED/, err)
    refute requests.any? { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" },
           "refused means the second bounce never lands"
  end

  def test_block_without_a_named_actor_does_not_stamp_the_raw_session
    requests, = run_task(
      ["block", "demo-task", "--kind", "dependency"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task/block" }
    event = JSON.parse(patch[:body]).fetch("event")
    assert_equal "cli", event["source"]
    refute event.key?("actor"), "block should not persist an opaque session id as the blocker"
  end

  def test_block_defaults_rework_from_submitted_to_avi_when_no_agent_context
    requests, = run_task(
      ["block", "demo-task", "--kind", "rework", "--feedback", "Needs review rework."],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION },
      stub_stage: "submitted"
    )

    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task/block" }
    parsed = JSON.parse(patch[:body])
    assert_equal "avi", parsed["by"], "submitted rework blocks default to Avi as the blocker"
    assert_equal "avi", parsed.dig("event", "actor"), "submitted rework blocks default to Avi, not a session id"

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    assert_equal "avi", JSON.parse(note[:body])["agent_slug"], "qa_feedback should carry the resolved blocker"
  end

  def test_note_posts_clarification_activity
    requests, out, _err, status = run_task(
      ["note", "demo-task", "--clarification", "Can you confirm whether this needs a PR comment too?", "--agent", "avi"]
    )

    assert status.success?
    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    refute_nil note, "expected a clarification activity"
    parsed = JSON.parse(note[:body])
    assert_equal "demo-task", parsed["task_slug"]
    assert_equal "clarification", parsed["activity_type"]
    assert_equal "Can you confirm whether this needs a PR comment too?", parsed["description"]
    assert_equal "avi", parsed["agent_slug"]
    assert_includes out, "noted [clarification] on demo-task"
  end

  def test_block_defaults_event_actor_to_the_session_persona
    Dir.mktmpdir do |projects|
      sessions = File.join(projects, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      File.write(File.join(sessions, "#{SESSION}.json"), JSON.generate("persona" => "shannon"))

      requests, = run_task(
        ["block", "demo-task", "--kind", "dependency"],
        env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "CLAUDE_PROJECTS_DIR" => projects }
      )

      patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task/block" }
      event = JSON.parse(patch[:body]).fetch("event")
      assert_equal "cli", event["source"]
      assert_equal "shannon", event["actor"], "block should prefer the session persona over the raw session id"
    end
  end

  def test_block_defaults_event_actor_to_the_task_persona_before_session_id
    requests, = run_task(
      ["block", "demo-task", "--kind", "dependency"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION },
      stub_devops: { "kind" => "bug", "persona" => "carl" }
    )

    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task/block" }
    event = JSON.parse(patch[:body]).fetch("event")
    assert_equal "cli", event["source"]
    assert_equal "carl", event["actor"], "task persona should beat the opaque session id"
  end

  def test_note_handoff_can_mark_feedback_resolved
    requests, = run_task(["note", "demo-task", "--handoff", "Addressed the blocker.", "--resolves-feedback", "--agent", "hitmonchan"])

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    refute_nil note
    parsed = JSON.parse(note[:body])
    assert_equal "handoff", parsed["activity_type"]
    assert_equal "hitmonchan", parsed["agent_slug"]
    assert_equal true, parsed.dig("metadata", "resolves_feedback")
  end

  def test_note_comment_with_resolves_feedback_dies_naming_the_handoff_form
    requests, _out, err, status = run_task(["note", "demo-task", "--comment", "Addressed the blocker.", "--resolves-feedback"])

    refute status.success?, "--resolves-feedback on a non-handoff note must die, not silently no-op"
    assert_empty requests, "the guard should fail before auth or POST"
    assert_match(/--resolves-feedback/, err)
    assert_match(/--handoff/, err, "the error should name the correct form")
  end

  def test_move_with_legacy_stage_name_suggests_the_live_stage
    requests, _out, err, status = run_task(["move", "demo-task", "pr_review"])

    refute status.success?
    assert_empty requests, "stage validation should fail before auth or PATCH"
    assert_match(/unknown stage "pr_review"/, err)
    assert_match(/legacy stage; use "submitted"/, err)
  end

  def test_intent_with_legacy_stage_name_suggests_the_live_stage
    requests, _out, err, status = run_task(["intent", "demo-task", "--to", "in_progress"])

    refute status.success?
    assert_empty requests, "stage validation should fail before auth or POST"
    assert_match(/unknown stage "in_progress"/, err)
    assert_match(/legacy stage; use "building"/, err)
  end

  # --- The sandbox: a test child may NEVER write the operator's real store ----
  #
  # THE BUG THIS FILE *WAS*. bin/task resolves two write roots by FALLBACK:
  #
  #   usage/cost store   TASK_USAGE_DIR     else <projects>/.agents/task-usage
  #   session marker     CLAUDE_PROJECTS_DIR else <projects>/.agents/sessions
  #
  # and this file pinned NEITHER. Worse, SESSION above is a REAL past session id
  # whose 30MB transcript still sits in the operator's ~/.claude — HOME was not
  # pinned either — so a plain `bin/task create` under this suite globbed that
  # transcript and wrote its ~1.9-BILLION-token cumulative totals into the
  # operator's LIVE cost store, keyed by the stub's slug ("demo-task"). That
  # fixture row then poisons every consumer of measured $cost: Task#actual_size
  # (which buckets on it) and the reviewer-select baselines.
  #
  # The fix is two-layered, and this is the layer that must never rot:
  #   1. CONFIGURED — base_env now pins all three (TASK_USAGE_DIR,
  #      CLAUDE_PROJECTS_DIR, HOME) into a per-test tmpdir.
  #   2. ASSERTED — TASK_USAGE_SANDBOX (set process-wide by test/support/
  #      task_usage_sandbox.rb, so every child inherits it) makes the CLI FAIL
  #      CLOSED: with the sandbox on, an unpinned write root ABORTS the command
  #      instead of falling back to the real one. Configuration alone is not a
  #      guarantee — the next test to forget a pin would silently pollute again.
  #
  # This case proves layer 2 end-to-end. It hands the child a STAND-IN projects
  # root (never the real one) and deletes the usage pin: today's code happily
  # writes a baseline there, which in production IS the operator's store.
  def test_sandboxed_run_refuses_to_fall_back_to_the_projects_root_usage_store
    Dir.mktmpdir do |projects|
      _requests, _out, err, status = run_task(
        ["create", "--title", "Session demo task", "--kind", "feature"],
        env: {
          "CLAUDE_CODE_SESSION_ID" => SESSION,
          "CLAUDE_PROJECTS_DIR" => projects, # a stand-in for the real projects root
          "TASK_USAGE_DIR" => nil            # nil DELETES the pin → the fallback fires
        },
        stub_stage: "designed"
      )

      refute_equal 0, status.exitstatus,
                   "an unpinned usage store must ABORT a sandboxed run, never fall back to <projects>/.agents"
      assert_match(/TASK_USAGE_DIR/, err, "the abort must name the var that pins the store")
      assert_empty Dir.glob(File.join(projects, ".agents", "task-usage", "*")),
                   "a sandboxed run must not write a baseline into the projects-root store"
    end
  end

  # The PATH half of the rule — "no write may land inside the real
  # <projects>/.agents, whatever env var pointed there" — is unit-tested in
  # test/lib/task_usage_sandbox_test.rb against an INJECTED stand-in state dir.
  # It is deliberately not exercised from here: to prove it end-to-end the child
  # would have to attempt a write into the operator's real store, and a red run
  # (or a broken fix) would then do exactly the damage this task exists to stop.

  # --- Auto-captured move usage (from the session transcript) ----------------

  # Build a fake $HOME holding a Claude transcript for SESSION with the given
  # assistant usage turns, plus an isolated usage-state dir; yields the env
  # overrides (and the state dir) for run_task.
  def with_session_transcript(turns)
    Dir.mktmpdir do |home|
      proj = File.join(home, ".claude", "projects", "-Users-alex-projects")
      FileUtils.mkdir_p(proj)
      lines = turns.map do |u|
        JSON.generate("type" => "assistant", "message" => {
          "model" => "claude-opus-4-8",
          "usage" => {
            "input_tokens" => u[:input], "output_tokens" => u[:output],
            "cache_creation_input_tokens" => u[:cc], "cache_read_input_tokens" => u[:cr]
          }
        })
      end
      File.write(File.join(proj, "#{SESSION}.jsonl"), "#{lines.join("\n")}\n")
      usage_dir = File.join(home, "usage-state")
      yield({ "CLAUDE_CODE_SESSION_ID" => SESSION, "HOME" => home, "TASK_USAGE_DIR" => usage_dir }, usage_dir)
    end
  end

  def with_codex_session_transcript(turns)
    Dir.mktmpdir do |home|
      proj = File.join(home, ".codex", "sessions", "2026", "06", "26")
      FileUtils.mkdir_p(proj)
      lines = [{ "type" => "turn_context", "payload" => { "model" => "gpt-5.5" } }]
      totals = { input: 0, output: 0, cached: 0 }
      turns.each do |u|
        totals[:input] += u[:input]
        totals[:output] += u[:output]
        totals[:cached] += u[:cached]
        lines << {
          "type" => "event_msg",
          "payload" => {
            "info" => {
              "total_token_usage" => {
                "input_tokens" => totals[:input],
                "cached_input_tokens" => totals[:cached],
                "output_tokens" => totals[:output],
                "reasoning_output_tokens" => u.fetch(:reasoning, 0),
                "total_tokens" => totals[:input] + totals[:output]
              }
            }
          }
        }
      end
      File.write(
        File.join(proj, "rollout-2026-06-26T13-04-23-#{SESSION}.jsonl"),
        "#{lines.map { |line| JSON.generate(line) }.join("\n")}\n"
      )
      usage_dir = File.join(home, "usage-state")
      yield({ "CODEX_THREAD_ID" => SESSION, "HOME" => home, "TASK_USAGE_DIR" => usage_dir }, usage_dir)
    end
  end

  def test_move_auto_captures_the_usage_delta_from_the_transcript
    turns = [
      { input: 1000, output: 2000, cc: 0,  cr: 5000 },
      { input: 100,  output: 4000, cc: 50, cr: 6000 }
    ]
    with_session_transcript(turns) do |env, usage_dir|
      # Seed the baseline at the first turn's totals so the move's delta is
      # exactly the second turn.
      FileUtils.mkdir_p(usage_dir)
      File.write(File.join(usage_dir, "#{SESSION}.json"),
                 JSON.generate("demo-task" => { "input" => 1000, "output" => 2000, "cache_creation" => 0, "cache_read" => 5000 }))

      requests, = run_task(["move", "demo-task", "submitted"], env: env)
      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")

      assert_equal "claude-opus-4-8", event["model"]
      assert_equal 150, event["tokens_in"]   # 100 + 50 (cache_read 6000 excluded)
      assert_equal 4000, event["tokens_out"]
      assert_equal "0.1040", event["cost"]     # (100*5 + 4000*25 + 50*5*2.0 + 6000*5*0.1)/1e6
      assert_equal SESSION, event["actor"]
    end
  end

  def test_codex_move_auto_captures_the_usage_delta_from_the_transcript
    turns = [
      { input: 1000, output: 200, cached: 300 },
      { input: 500,  output: 80,  cached: 200 }
    ]
    with_codex_session_transcript(turns) do |env, usage_dir|
      FileUtils.mkdir_p(usage_dir)
      File.write(File.join(usage_dir, "#{SESSION}.json"),
                 JSON.generate("demo-task" => { "input" => 700, "output" => 200,
                                                "cache_creation" => 0, "cache_read" => 300 }))

      requests, = run_task(["move", "demo-task", "submitted"], env: env)
      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")

      assert_equal "gpt-5.5", event["model"]
      assert_equal 300, event["tokens_in"]   # cache_read excluded from the count (cost unchanged)
      assert_equal 80, event["tokens_out"]
      assert_equal "0.0040", event["cost"]
      assert_equal SESSION, event["actor"]
    end
  end

  def test_first_move_with_no_baseline_records_model_only
    with_session_transcript([{ input: 1000, output: 2000, cc: 0, cr: 5000 }]) do |env, _dir|
      requests, = run_task(["move", "demo-task", "submitted"], env: env)
      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")

      assert_equal "claude-opus-4-8", event["model"]
      refute event.key?("tokens_in"), "no baseline yet → no token delta to report"
      refute event.key?("cost")
    end
  end

  def test_explicit_usage_flag_disables_auto_capture
    with_session_transcript([{ input: 1000, output: 2000, cc: 0, cr: 5000 }]) do |env, _dir|
      requests, = run_task(["move", "demo-task", "submitted", "--tokens-in", "42"], env: env)
      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")

      assert_equal 42, event["tokens_in"]
      refute event.key?("model"), "an explicit usage flag turns auto-capture off"
      refute event.key?("cost")
    end
  end

  # Like with_session_transcript, but writes RAW transcript lines verbatim so a
  # test can include valid-JSON-but-non-object lines (42, [1,2], null, true) —
  # the exact shape that once made sum_usage raise a TypeError on obj["type"].
  def with_raw_session_transcript(raw_lines)
    Dir.mktmpdir do |home|
      proj = File.join(home, ".claude", "projects", "-Users-alex-projects")
      FileUtils.mkdir_p(proj)
      File.write(File.join(proj, "#{SESSION}.jsonl"), "#{raw_lines.join("\n")}\n")
      usage_dir = File.join(home, "usage-state")
      yield({ "CLAUDE_CODE_SESSION_ID" => SESSION, "HOME" => home, "TASK_USAGE_DIR" => usage_dir }, usage_dir)
    end
  end

  # Acceptance #5: a malformed transcript must degrade to a SPINE-ONLY move, never
  # abort it. A non-object JSON line (42) once raised TypeError inside the capture,
  # and autofill_move_usage had no rescue, so the exception escaped BEFORE the
  # stage-transition PATCH fired — strictly worse than spine-only. Prove the PATCH
  # still fires and carries no usage. (Regression for the rework on PR #121.)
  def test_move_with_a_malformed_transcript_still_records_the_spine
    with_raw_session_transcript(["42", "[1,2,3]", "null", "true", '"bare string"']) do |env, _dir|
      requests, = run_task(["move", "demo-task", "submitted"], env: env)
      patch = requests.find { |r| r[:method] == "PATCH" }

      refute_nil patch, "the stage PATCH must still fire — a capture failure can't abort the move"
      parsed = JSON.parse(patch[:body])
      assert_equal "submitted", parsed["stage"]
      event = parsed.fetch("event")
      assert_equal "cli", event["source"]
      refute event.key?("model"), "a malformed transcript yields a spine-only event"
      refute event.key?("tokens_in")
      refute event.key?("cost")
    end
  end

  def transcript_line(input:, output:, cc:, cr:)
    JSON.generate("type" => "assistant", "message" => {
      "model" => "claude-opus-4-8",
      "usage" => {
        "input_tokens" => input, "output_tokens" => output,
        "cache_creation_input_tokens" => cc, "cache_read_input_tokens" => cr
      }
    })
  end

  # The fix for the zeroed first-move baseline: a review INTENT seeds the baseline
  # at the session's CURRENT totals, so the reviewer's FIRST move (submitted→
  # reviewed) records the real work delta instead of model-only. Contrast with
  # test_first_move_with_no_baseline_records_model_only (no intent → model only),
  # which is exactly the Submitted→Reviewed chip bug this task fixes. End-to-end
  # through bin/task against the stub board, sharing the on-disk usage baseline
  # across the two invocations (same HOME + TASK_USAGE_DIR).
  def test_intent_seeds_baseline_so_first_review_move_records_a_delta
    Dir.mktmpdir do |home|
      proj = File.join(home, ".claude", "projects", "-Users-alex-projects")
      FileUtils.mkdir_p(proj)
      transcript = File.join(proj, "#{SESSION}.jsonl")
      env = { "CLAUDE_CODE_SESSION_ID" => SESSION, "HOME" => home, "TASK_USAGE_DIR" => File.join(home, "usage-state") }

      # The reviewer's session has burned turn-1 tokens by the time they pick up
      # the review and record the intent — which seeds the baseline here.
      File.write(transcript, "#{transcript_line(input: 1000, output: 2000, cc: 0, cr: 5000)}\n")
      _req, _out, _err, status = run_task(["intent", "demo-task", "--to", "reviewed"], env: env)
      assert status.success?, "the intent should record + seed cleanly"

      # The review work happens (turn 2), then the reviewer moves to reviewed.
      File.open(transcript, "a") { |f| f.puts transcript_line(input: 100, output: 4000, cc: 50, cr: 6000) }
      requests, = run_task(["move", "demo-task", "reviewed"], env: env)

      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")
      assert_equal "claude-opus-4-8", event["model"]
      assert_equal 150, event["tokens_in"], "delta is turn 2 only — the review work since the intent (cache_read excluded)"
      assert_equal 4000, event["tokens_out"]
      assert event.key?("cost"), "a real delta records cost too"
    end
  end

  # The DESIGN-PHASE analog of the intent-seed fix: `bin/task create` seeds the
  # baseline at the session's CURRENT totals, so the FIRST work transition
  # (designed→building) records the real design-phase delta instead of model-only.
  # Before this fix the create handler seeded nothing, so the designed→building
  # move had no baseline to diff and dropped to the model-only chip — TOKENS — /
  # COST — on the "Designed → Building" card even though MODEL/DURATION populated.
  # End-to-end through bin/task against the stub board (whose create POST returns
  # slug "demo-task"), sharing the on-disk baseline across the two invocations
  # (same HOME + TASK_USAGE_DIR). Contrast test_first_move_with_no_baseline_records_
  # model_only — that's the bug this closes for the build CLAIM move.
  def test_create_seeds_baseline_so_first_build_move_records_a_delta
    Dir.mktmpdir do |home|
      proj = File.join(home, ".claude", "projects", "-Users-alex-projects")
      FileUtils.mkdir_p(proj)
      transcript = File.join(proj, "#{SESSION}.jsonl")
      env = { "CLAUDE_CODE_SESSION_ID" => SESSION, "HOME" => home, "TASK_USAGE_DIR" => File.join(home, "usage-state") }

      # The agent has burned turn-1 tokens (reading the docs, shaping the feature)
      # by the time it creates the task — which seeds the baseline here.
      File.write(transcript, "#{transcript_line(input: 1000, output: 2000, cc: 0, cr: 5000)}\n")
      _req, _out, _err, status = run_task(["create", "--title", "Design phase task", "--kind", "feature"], env: env)
      assert status.success?, "the create should record + seed the baseline cleanly"

      # The design work happens (turn 2 — worktree setup, reading the code, the
      # plan), then the agent claims the task at building.
      File.open(transcript, "a") { |f| f.puts transcript_line(input: 100, output: 4000, cc: 50, cr: 6000) }
      requests, = run_task(["move", "demo-task", "building"], env: env)

      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")
      assert_equal "claude-opus-4-8", event["model"]
      assert_equal 150, event["tokens_in"], "delta is turn 2 only — the design work since create (cache_read excluded)"
      assert_equal 4000, event["tokens_out"]
      assert event.key?("cost"), "a real design-phase delta records cost too"
    end
  end

  def test_move_without_a_transcript_records_spine_only
    Dir.mktmpdir do |home| # $HOME with no transcript file present
      requests, = run_task(["move", "demo-task", "submitted"],
                           env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "HOME" => home, "TASK_USAGE_DIR" => File.join(home, "u") })
      event = JSON.parse(requests.find { |r| r[:method] == "PATCH" }[:body]).fetch("event")

      assert_equal "cli", event["source"]
      refute event.key?("model"), "no transcript → spine-only event"
      refute event.key?("tokens_in")
    end
  end

  # --- Build claim lease gate (V2) — the move-to-building enforcement ---------

  # A devops slice carrying an existing claim with a lease `expires_in` seconds out.
  def claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300)
    {
      "kind" => "feature",
      "claimed_session" => session,
      "claim_nonce" => nonce,
      "claim_expires_at" => (Time.now + expires_in).utc.iso8601
    }
  end

  def patch_of(requests)
    requests.find { |r| r[:method] == "PATCH" }
  end

  def patch_devops(requests)
    JSON.parse(patch_of(requests)[:body]).fetch("devops")
  end

  # AC #1 + #4: a live claim held by a DIFFERENT instance (same session, other
  # nonce ⇒ the terminal-A/terminal-B case) REFUSES the move — exit 1, loud, and
  # NO stage PATCH — and points the operator at --steal.
  def test_move_to_building_refuses_a_live_foreign_claim
    requests, _out, err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300)
    )
    refute status.success?, "a live foreign claim must refuse the move (non-zero exit)"
    assert_nil patch_of(requests), "a refused move must NOT PATCH the stage"
    assert_match(/different live instance/i, err)
    assert_match(/--steal/, err)
  end

  # [integration] The refusal must name the PROGRESS fact, not just the heartbeat.
  # A heartbeat says only "a terminal is painting" — it stayed green through the
  # 2026-07-13 wedge. A second agent deciding whether to --steal needs to know what
  # the holder has actually LANDED, so the gate prints the last durable artifact.
  #
  # Holder-SCOPED since 2026-08-13: the artifact must be one the holder produced.
  # See test_refusal_never_credits_the_challengers_own_work_to_the_holder for the
  # failure that forced the scoping.
  def test_refusal_names_the_holders_last_durable_progress
    _requests, _out, err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300),
      stub_progress: { "progress_seconds_ago" => 9000, "last_progress_label" => "g1_cert failed",
                       "last_progress_actor" => SESSION,
                       "holder_progress_seconds_ago" => 9000,
                       "holder_progress_label" => "g1_cert failed",
                       "progress_quiet" => true }
    )
    refute status.success?
    assert_match(/last durable progress by the holder ~2\.5h ago \(g1_cert failed\)/, err)
    assert_match(/nothing has landed in a long time/, err)
    # ...and it still refuses. Naming a quiet holder never frees the desk: the
    # operator still has to choose --steal. Nothing here reclaims anything.
    assert_match(/--steal/, err)
  end

  # A healthy holder mid-cert is NOT dressed up as trouble — the gate reports its
  # progress plainly, with no quiet warning.
  def test_refusal_reports_a_progressing_holder_without_alarm
    _requests, _out, err, = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300),
      stub_progress: { "progress_seconds_ago" => 120, "last_progress_label" => "g1_cert running",
                       "last_progress_actor" => SESSION,
                       "holder_progress_seconds_ago" => 120,
                       "holder_progress_label" => "g1_cert running",
                       "progress_quiet" => false }
    )
    assert_match(/last durable progress by the holder ~2m ago \(g1_cert running\)/, err)
    refute_match(/nothing has landed/, err)
  end

  # Fail safe: a board that reports no progress fact (an older API, a task that has
  # produced nothing yet) must read as UNKNOWN — never as a stalled holder.
  def test_refusal_states_unknown_progress_honestly
    _requests, _out, err, = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300)
    )
    assert_match(/none recorded yet/, err)
    refute_match(/nothing has landed/, err)
  end

  # AC #1: --steal overrides the gate and takes the claim for the stealer's instance.
  def test_move_to_building_with_steal_takes_the_claim
    requests, _out, _err, status = run_task(
      ["move", "demo-task", "building", "--steal"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300)
    )
    assert status.success?, "--steal must let the move through"
    devops = patch_devops(requests)
    assert_equal SESSION, devops["claimed_session"]
    assert_equal "inst-B", devops["claim_nonce"], "the stealer's instance now holds the claim"
    assert devops["claim_expires_at"], "a fresh lease is written"
  end

  # AC #3: an EXPIRED lease is reclaimed automatically — no --steal, no refusal.
  def test_move_to_building_reclaims_an_expired_lease
    requests, _out, _err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: OTHER_SESSION, nonce: "inst-A", expires_in: -30)
    )
    assert status.success?, "an expired lease is silently reclaimable"
    devops = patch_devops(requests)
    assert_equal SESSION, devops["claimed_session"]
    assert_equal "inst-B", devops["claim_nonce"]
  end

  # A CORRUPT (unparseable) lease keeps the gate's fail-open posture: the move
  # claims freely — no --steal, no refusal — and writing the fresh lease heals
  # the garbled record. Deliberately opposite to the reclaim guard
  # (bin/agent-worktree), which WITHHOLDS on :corrupt: claiming writes state,
  # reclaiming destroys it. Pinned here so a future "corrupt must block
  # everywhere" refactor trips this test instead of silently changing bin/task.
  def test_move_to_building_reclaims_a_corrupt_expiry_lease
    corrupt = claim_devops(session: OTHER_SESSION, nonce: "inst-A")
    corrupt["claim_expires_at"] = "not-a-time"
    requests, _out, _err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: corrupt
    )
    assert status.success?, "a corrupt lease stays fail-open at the BUILD gate (heal by re-claiming)"
    devops = patch_devops(requests)
    assert_equal SESSION, devops["claimed_session"]
    assert_equal "inst-B", devops["claim_nonce"]
    refute_nil Time.parse(devops["claim_expires_at"]), "the re-claim writes a fresh PARSEABLE lease"
  end

  # AC #3: an unclaimed task is claimed on the move with the mover's identity.
  def test_move_to_building_claims_an_unclaimed_task
    requests, _out, _err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: { "kind" => "feature" }
    )
    assert status.success?
    devops = patch_devops(requests)
    assert_equal SESSION, devops["claimed_session"]
    assert_equal "inst-B", devops["claim_nonce"]
    assert_equal "feature", devops["kind"], "existing devops is preserved (read-merge-write)"
  end

  # AC #2: the SAME instance (session AND nonce match) re-moving renews, no --steal.
  def test_move_to_building_same_instance_renews_its_own_claim
    requests, _out, _err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-A" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30)
    )
    assert status.success?, "re-moving my own task is fine"
    devops = patch_devops(requests)
    assert_equal SESSION, devops["claimed_session"]
    assert_equal "inst-A", devops["claim_nonce"]
  end

  # --- Heartbeat (the lease renewal bin/statusline drives) --------------------

  def test_heartbeat_renews_an_unclaimed_task_for_this_instance
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-A" },
      stub_devops: { "kind" => "feature" }
    )
    assert status.success?
    devops = patch_devops(requests)
    assert_equal SESSION, devops["claimed_session"]
    assert_equal "inst-A", devops["claim_nonce"]
    assert devops["claim_expires_at"], "the heartbeat writes a fresh lease"
  end

  def test_heartbeat_renews_this_instances_own_claim
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-A" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 20)
    )
    assert status.success?
    assert_equal SESSION, patch_devops(requests)["claimed_session"]
  end

  # A heartbeat must NOT steal a live claim held by a different instance.
  def test_heartbeat_does_not_steal_a_live_foreign_claim
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 300)
    )
    assert status.success?, "the heartbeat is best-effort and silent"
    assert_nil patch_of(requests), "a heartbeat never steals a live foreign claim"
  end

  def test_heartbeat_without_a_session_is_a_silent_noop
    requests, _out, _err, status = run_task(["heartbeat", "demo-task"])
    assert status.success?
    assert_nil patch_of(requests), "no session → no claim write"
  end

  # The authoritative guard: a heartbeat renews a BUILD claim, and a build claim
  # only exists once the task is actually `building`. A task still in `designed`
  # (the create default) is unclaimed by definition — `bin/task create` repoints
  # the creator's session marker to it, and a stray heartbeat must NOT forge a
  # live claim there (the creator's mascot ticking on an unowned `designed` task).
  def test_heartbeat_skips_a_designed_task
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-A" },
      stub_devops: { "kind" => "feature" },
      stub_stage: "designed"
    )
    assert status.success?, "the heartbeat stays best-effort and silent"
    assert_nil patch_of(requests), "a non-building task is unclaimed — no claim is forged"
  end

  # And the same for any other non-build stage (e.g. an already-`submitted` task) —
  # only the live BUILD stage is renewed.
  def test_heartbeat_skips_a_submitted_task
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-A" },
      stub_devops: { "kind" => "feature" },
      stub_stage: "submitted"
    )
    assert status.success?
    assert_nil patch_of(requests), "only a `building` task heartbeats — never a submitted one"
  end

  # --- The desk-keyed heartbeat (a lease renewed by WORK, not by a status line)
  #
  # bin/statusline fires `heartbeat` every ~45s from a painting terminal, so before
  # this the lease said only "a terminal is open" — and this machine carries
  # `claude` processes days old. These cases are written as the two errors the
  # guard can make, and they are not symmetric: renewing a dead claim costs other
  # agents minutes of waiting, while declining a LIVE one costs a worker its desk.

  # Build a desk bound to `slug`, holding one file `age` seconds old.
  def desk(slug: "demo-task", age: 5, name: "app/models/thing.rb")
    root = File.join(sandbox_root, "desk-#{age}-#{name.gsub(%r{[/.]}, '-')}")
    FileUtils.mkdir_p(File.join(root, File.dirname(name)))
    File.write(File.join(root, ".agent-context.json"), JSON.generate("task_slug" => slug))
    path = File.join(root, name)
    File.write(path, "x")
    at = Time.now - age
    File.utime(at, at, path)
    # The context file is written NOW, so it would read as fresh activity on its
    # own; age it with the rest so a "quiet desk" is genuinely quiet.
    File.utime(at, at, File.join(root, ".agent-context.json"))
    root
  end

  def heartbeat_env(session: SESSION, nonce: "inst-A")
    { "CLAUDE_CODE_SESSION_ID" => session, "TASK_CLAIM_NONCE" => nonce }
  end

  # THE ONE THAT PROTECTS A REAL WORKER. The holder is editing files in its desk
  # and has written NOTHING to the board for far longer than the idle window — the
  # exact 2026-08-13 session, which was writing bespoke test files while looking
  # dead from the board's side. Its claim must survive.
  def test_heartbeat_renews_a_claim_whose_desk_is_being_written_even_with_a_silent_board
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: 3)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => 100 * ClaimLease::DESK_IDLE_SECONDS,
                       "gate_in_flight" => false }
    )
    assert status.success?
    devops = patch_devops(requests)
    refute_nil devops, "a session writing its desk is WORKING — its lease must be renewed"
    assert_equal SESSION, devops["claimed_session"]
    assert devops["claim_expires_at"], "the lease is pushed out on desk evidence alone"
  end

  # The bug itself: an open terminal on a desk nobody is touching, with nothing
  # landing on the board either. Every channel silent, so the heartbeat declines
  # and the lease lapses on the ordinary TTL.
  def test_heartbeat_declines_to_renew_a_claim_whose_desk_has_gone_quiet
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "gate_in_flight" => false }
    )
    assert status.success?, "the heartbeat stays best-effort and silent"
    assert_nil patch_of(requests),
               "an open terminal is not a worker — a status line must not renew an abandoned claim"
  end

  # A cert writes nothing into the desk while it runs (measured g1_cert p99: 94
  # minutes). Without this channel a long green cert is indistinguishable from a
  # walked-away terminal, and the gate would evict an agent mid-certification.
  def test_heartbeat_renews_a_quiet_desk_while_a_gate_is_in_flight
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "gate_in_flight" => true }
    )
    assert status.success?
    refute_nil patch_devops(requests), "a cert in flight is work — the desk is quiet because certs are quiet"
  end

  # THE INCIDENT, VERBATIM — and the reason "the gate prints an honest message" was
  # only half the fix. The holder walked away. A QUEUED CHALLENGER then ran
  # `bin/full-suite-check` on the held slug, which lands a checkpoint AND opens a
  # g1_cert on a task it does not hold. Task-wide the board now looks busy — recent
  # progress, a gate in flight — and reading those two task-wide facts renewed the
  # abandoned lease for another 1h29m, which is the stall this task exists to end.
  # Holder-scoped, both facts say what is actually true: the holder has produced
  # nothing in far longer than the window, and the running gate is not its own.
  def test_heartbeat_declines_when_only_a_challengers_cert_is_moving_the_task
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => 120, "gate_in_flight" => true,
                       "holder_liveness_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "holder_gate_in_flight" => false }
    )
    assert status.success?, "the heartbeat stays best-effort and silent"
    assert_nil patch_of(requests),
               "a challenger's own cert is not evidence the holder is alive — the lease must still lapse"
  end

  # THE CONVERSE, which is what the actor filter has to buy without losing. The
  # HOLDER is mid-cert: a cert writes nothing into the desk for up to the measured
  # 94-minute p99, so the desk is legitimately silent and this channel is the only
  # thing between a working agent and eviction. Filtering the channel by actor
  # keeps it for the holder — dropping it would have reaped exactly this session.
  def test_heartbeat_renews_a_silent_desk_while_the_holders_own_gate_is_in_flight
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "gate_in_flight" => true,
                       "holder_liveness_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "holder_gate_in_flight" => true }
    )
    assert status.success?
    refute_nil patch_devops(requests),
               "the holder's own cert is the one thing that proves it is still there — never reap mid-cert"
  end

  # A board that does not publish the holder-scoped fact at all (an older
  # deployment, a trimmed serializer) is an UNKNOWN, and an unknown may never free
  # a desk. The fallback is the task-wide twin, which is strictly more protective
  # because it counts everyone's work. Without it a missing key would read as "the
  # holder has produced nothing, ever" and reap a live holder on a schema gap.
  def test_heartbeat_falls_back_to_the_task_wide_progress_when_the_board_omits_the_holder_scoped_one
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => 120, "gate_in_flight" => false }
    )
    assert status.success?
    refute_nil patch_devops(requests), "a board that cannot answer the question has not answered it 'no'"
  end

  # Parked on the operator is not abandoned: the agent is right to be doing
  # nothing, and the task record says so.
  def test_heartbeat_renews_a_quiet_desk_awaiting_operator_approval
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A",
                                expires_in: 30).merge("approval_status" => "waiting"),
      stub_progress: { "progress_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "gate_in_flight" => false }
    )
    assert status.success?
    refute_nil patch_devops(requests), "a task waiting on Mr. McRitchie is blocked on a human, not abandoned"
  end

  # FAIL TOWARD NOT STEALING. No desk resolves (a primary checkout, an unbound
  # session), so we know nothing about whether this holder is working — and
  # nothing must never free a desk. Renew, exactly as before this change.
  def test_heartbeat_renews_when_no_desk_can_be_resolved
    plain = File.join(sandbox_root, "no-context")
    FileUtils.mkdir_p(plain)

    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", plain],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => 100 * ClaimLease::DESK_IDLE_SECONDS,
                       "gate_in_flight" => false }
    )
    assert status.success?
    refute_nil patch_devops(requests), "an unreadable desk is no evidence at all — it must never free a claim"
  end

  # A desk bound to a DIFFERENT task tells us nothing about this one. It must be
  # refused rather than read: the primary checkout is written by every agent on
  # the machine, so judging a claim there would renew it forever.
  def test_heartbeat_refuses_to_judge_this_claim_by_another_tasks_desk
    foreign = desk(slug: "somebody-elses-task", age: 3)

    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task", "--desk", foreign],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => 100 * ClaimLease::DESK_IDLE_SECONDS,
                       "gate_in_flight" => false }
    )
    assert status.success?
    # Renewed, because a refused desk is UNKNOWN, not quiet — but the point is
    # that the foreign desk's freshness played no part in the decision.
    refute_nil patch_devops(requests)
  end

  # Without --desk the heartbeat still tries its cwd, so a desk session gets the
  # guard even if a caller forgets the flag.
  def test_heartbeat_falls_back_to_the_working_directory_for_the_desk
    requests, _out, _err, status = run_task(
      ["heartbeat", "demo-task"],
      env: heartbeat_env,
      stub_devops: claim_devops(session: SESSION, nonce: "inst-A", expires_in: 30),
      stub_progress: { "progress_seconds_ago" => ClaimLease::DESK_IDLE_SECONDS + 600,
                       "gate_in_flight" => false },
      chdir: desk(age: ClaimLease::DESK_IDLE_SECONDS + 600)
    )
    assert status.success?
    assert_nil patch_of(requests), "cwd is a bound desk and it is quiet — the claim is not renewed"
  end

  # --- Certs must SIGN their artifacts ---------------------------------------
  #
  # A cert emits two durable artifacts (this checkpoint and a g1_cert GateRun) and
  # neither carried an owner, which is what let the claim gate credit a
  # challenger's cert to the holder. The stamp is the input the attribution above
  # depends on; without it every artifact is unowned and the gate is blind again.

  def test_a_cert_checkpoint_records_the_session_that_produced_it
    requests, _out, _err, status = run_task(
      ["checkpoint", "demo-task", "cert", "--status", "completed"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    assert status.success?
    post = requests.find { |r| r[:method] == "POST" && r[:path].include?("/events/cert/complete") }
    refute_nil post, "expected the checkpoint POST"
    assert_equal SESSION, JSON.parse(post[:body]).dig("event", "metadata", "session"),
                 "an unsigned artifact gets credited to whoever holds the claim"
  end

  # A plain shell / CI run names no session, and an unattributed artifact must
  # stay honestly unattributed rather than be stamped with a guess.
  def test_a_cert_checkpoint_without_a_session_stamps_nobody
    requests, _out, _err, status = run_task(["checkpoint", "demo-task", "cert", "--status", "started"])

    assert status.success?
    post = requests.find { |r| r[:method] == "POST" && r[:path].include?("/events/cert/start") }
    refute_nil post
    assert_nil JSON.parse(post[:body]).dig("event", "metadata"),
               "no session means no owner — never a guessed one"
  end

  # --- The refusal's evidence must be the HOLDER's ---------------------------

  # The circular refusal, as it actually happened. The challenger ran
  # bin/full-suite-check, its cert landed a g1_cert row on the task, and the gate
  # quoted that back at the challenger as proof the holder was alive. The gate may
  # not cite the challenger's own work as the holder's.
  def test_refusal_never_credits_the_challengers_own_work_to_the_holder
    _requests, _out, err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: OTHER_SESSION, nonce: "inst-A", expires_in: 300),
      # The newest artifact belongs to the CHALLENGER; the holder has produced
      # nothing attributable to it.
      stub_progress: { "progress_seconds_ago" => 120, "last_progress_label" => "g1_cert passed",
                       "last_progress_actor" => SESSION,
                       "holder_progress_seconds_ago" => nil, "holder_progress_label" => nil,
                       "progress_quiet" => false }
    )
    refute status.success?
    refute_match(/progress by the holder/, err,
                 "the holder produced nothing — reporting its progress would be inventing it")
    assert_match(/THIS session's own work/, err,
                 "the challenger must be told the cert it is being refused on is its own")
    assert_match(/says nothing about the holder/, err)
  end

  # And when the holder HAS landed something of its own, that is what gets
  # reported — attributed, and scoped to the holder rather than to the task.
  def test_refusal_reports_the_holders_own_durable_progress
    _requests, _out, err, status = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: OTHER_SESSION, nonce: "inst-A", expires_in: 300),
      stub_progress: { "progress_seconds_ago" => 120, "last_progress_label" => "g1_cert passed",
                       "last_progress_actor" => SESSION,
                       "holder_progress_seconds_ago" => 1_680,
                       "holder_progress_label" => "moved to building",
                       "progress_quiet" => false }
    )
    refute status.success?
    assert_match(/last durable progress by the holder ~28m ago \(moved to building\)/, err)
    refute_match(/THIS session's own work/, err,
                 "the holder's own progress is the answer — the challenger's cert is not mentioned")
  end

  # Progress with no recorded owner is reported as exactly that. An older row, or a
  # plain-shell run, names nobody — and "nobody" must not quietly become "the holder".
  def test_refusal_states_unattributed_progress_as_unowned
    _requests, _out, err, = run_task(
      ["move", "demo-task", "building"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION, "TASK_CLAIM_NONCE" => "inst-B" },
      stub_devops: claim_devops(session: OTHER_SESSION, nonce: "inst-A", expires_in: 300),
      stub_progress: { "progress_seconds_ago" => 300, "last_progress_label" => "g1_cert passed",
                       "last_progress_actor" => nil, "holder_progress_seconds_ago" => nil }
    )
    assert_match(/has no recorded owner/, err)
    refute_match(/progress by the holder/, err)
  end

  # --- show --json / --verbose (the visibility wins) --------------------------

  # --json prints the FULL fetched record as valid JSON — the machine-readable
  # path that retires the curl + auth-token dance.
  def test_show_json_emits_valid_json_of_the_fetched_data
    _requests, out, _err, status = run_task(
      ["show", "demo-task", "--json"],
      stub_devops: { "kind" => "feature", "acceptance" => ["a", "b"] }
    )
    assert status.success?
    parsed = JSON.parse(out) # raises (fails the test) if --json emitted non-JSON
    assert_equal "demo-task", parsed["slug"]
    assert_equal "building", parsed["stage"]
    assert_equal ["a", "b"], parsed.dig("metadata", "devops", "acceptance")
  end

  # --verbose expands the acceptance BULLETS (not just the count) and prints
  # agent_context — the human-readable expansion.
  def test_show_verbose_prints_acceptance_bullets_and_agent_context
    _requests, out, _err, status = run_task(
      ["show", "demo-task", "--verbose"],
      stub_devops: {
        "kind" => "feature",
        "acceptance" => ["first bullet here", "second bullet here"],
        "agent_context" => "the why behind it"
      }
    )
    assert status.success?
    assert_match(/- first bullet here/, out)
    assert_match(/- second bullet here/, out)
    assert_match(/agent_context: the why behind it/, out)
  end

  # The default `show` stays terse — it counts the acceptance items, it does not
  # expand them (so the verbose path is the only one that does).
  def test_show_default_stays_terse
    _requests, out, _err, status = run_task(
      ["show", "demo-task"],
      stub_devops: { "acceptance" => ["only bullet"] }
    )
    assert status.success?
    assert_match(/acceptance: 1 item/, out)
    refute_match(/- only bullet/, out)
  end

  # --- the top-level columns in --verbose (merged / release_slug) -------------
  #
  # `merged` is the stamp the release sweep reads to decide whether a `reviewed`
  # task rides the candidate, so it is read back constantly — and --verbose used
  # to print every devops neighbour around it and not the field itself. Agents
  # looked in `metadata.devops.merged`, found null (nothing writes there, ever),
  # and read that as a dropped write; three did inside 24 hours. These cases pin
  # the three states apart THROUGH THE REAL CLI, so the fix cannot regress into
  # "prints something" while losing the distinction that is the actual fix.

  def test_show_verbose_prints_the_merged_stamp_from_the_top_level_column
    _requests, out, _err, status = run_task(
      ["show", "demo-task", "--verbose"],
      stub_columns: { "merged" => "accepted" }
    )
    assert status.success?
    assert_match(/merged: accepted/, out)
  end

  # An empty column reads as a definite negative IN WORDS. The bare "-" this
  # output uses for empty devops fields is exactly the glyph that read as
  # "nothing to tell you", so it must not appear as the merged value.
  def test_show_verbose_states_an_unstamped_task_as_not_merged
    _requests, out, _err, status = run_task(["show", "demo-task", "--verbose"])
    assert status.success?
    assert_match(/merged: not merged/, out)
    refute_match(/merged: -/, out)
  end

  # The state that had no rendering at all before: the board returns no `merged`
  # key. That is NOT "not merged" — it is "this tool cannot tell you" — and the
  # two must not read alike.
  def test_show_verbose_marks_an_unreported_merged_field_as_unreported
    _requests, unreported_out, _err, status = run_task(
      ["show", "demo-task", "--verbose"], stub_omit_columns: ["merged"]
    )
    assert status.success?
    assert_match(/merged: UNREPORTED/, unreported_out)

    _requests, unset_out, = run_task(["show", "demo-task", "--verbose"])
    merged_line = ->(out) { out.lines.find { |l| l.include?("merged:") }.to_s.strip }
    refute_equal merged_line.call(unset_out), merged_line.call(unreported_out),
                 "an empty column and an unreported one must not render alike"
  end

  # The line is UNCONDITIONAL. A field printed only when set is the defect in a
  # new costume: its absence still reads as "this tool does not report it".
  def test_show_verbose_always_prints_the_column_line_and_says_where_it_lives
    %w[accepted release main].each do |stamp|
      _requests, out, = run_task(["show", "demo-task", "--verbose"], stub_columns: { "merged" => stamp })
      assert_match(/merged: #{stamp}/, out)
      assert_match(/top-level Task columns/, out, "the locator must print even when the value is set")
      assert_match(/metadata\.devops/, out)
    end
  end

  # release_slug WAS the same trap, one worse: a top-level column with a same-named
  # devops key that the board form and this CLI's own --release-slug flag wrote and
  # no release code read. The shadow is retired now (Task::DEVOPS_COLUMN_KEYS), so
  # this case guards the read against a row written before that landed — --verbose
  # must resolve from the column, exactly like `field`.
  def test_show_verbose_reads_release_slug_from_the_column_not_the_devops_shadow
    _requests, out, _err, status = run_task(
      ["show", "demo-task", "--verbose"],
      stub_devops: { "kind" => "feature", "release_slug" => "shadow-never-read" },
      stub_columns: { "release_slug" => "rel-2026-08-11-hub" }
    )
    assert status.success?
    assert_match(/release_slug: rel-2026-08-11-hub/, out)
    refute_match(/shadow-never-read/, out)
  end

  def test_show_verbose_states_an_unreleased_task_as_not_on_a_release
    _requests, out, = run_task(["show", "demo-task", "--verbose"])
    assert_match(/release_slug: not on a release/, out)
  end

  # The terse view is unchanged — the columns are a --verbose expansion.
  def test_show_default_does_not_print_the_column_line
    _requests, out, = run_task(["show", "demo-task"], stub_columns: { "merged" => "accepted" })
    refute_match(/merged:/, out)
  end

  # --- `bin/task field` reaches the columns too --------------------------------
  #
  # The machine-readable half of the same trap: `field` did a devops-only lookup,
  # so `field <slug> merged` printed NOTHING and exited 0 — indistinguishable
  # from an unstamped task, in the surface scripts capture from.

  def test_field_reads_a_top_level_column
    _requests, out, _err, status = run_task(
      ["field", "demo-task", "merged"], stub_columns: { "merged" => "accepted" }
    )
    assert status.success?
    assert_equal "accepted", out.strip
  end

  def test_field_reads_release_slug_from_the_column
    _requests, out, = run_task(
      ["field", "demo-task", "release_slug"], stub_columns: { "release_slug" => "rel-2026-08-11-hub" }
    )
    assert_equal "rel-2026-08-11-hub", out.strip
  end

  # THE MUTATION PROOF for the machine-readable surface. `field` used to resolve
  # devops-first for every key, so a task carrying a devops release_slug shadow
  # printed the shadow here while `show --verbose` printed the column — the same
  # task, two answers, and the wrong one in the surface scripts capture from.
  # Column-backed names now resolve from the column, full stop. A reader that
  # reinstates the devops-first fallback prints "from-devops" and fails here.
  def test_field_reads_a_column_backed_name_from_the_column_never_the_devops_shadow
    %w[release_slug merged].each do |key|
      _requests, out, = run_task(
        ["field", "demo-task", key],
        stub_devops: { key => "from-devops" },
        stub_columns: { key => "from-column" }
      )
      assert_equal "from-column", out.strip, "#{key} is column-backed — devops must never win"
    end
  end

  # …and the general rule is UNCHANGED for every other key, so ordinary callers
  # (`field <slug> mascot|branch|worktree_slug`) keep devops-first resolution.
  # This is the guard against "fix it by making the column always win".
  def test_field_still_prefers_devops_for_a_key_that_is_not_column_backed
    _requests, out, = run_task(
      ["field", "demo-task", "worktree_slug"],
      stub_devops: { "worktree_slug" => "from-devops" },
      stub_columns: { "worktree_slug" => "from-column" }
    )
    assert_equal "from-devops", out.strip
  end

  def test_field_stays_silent_for_a_key_in_neither_place
    _requests, out, _err, status = run_task(["field", "demo-task", "nope"])
    assert status.success?
    assert_equal "", out.strip
  end

  # --- stale (the stale war) --------------------------------------------------

  def git!(dir, cmd)
    out = `git -C #{dir} #{cmd} 2>&1`
    raise "git #{cmd} failed in #{dir}:\n#{out}" unless $?.success?

    out
  end

  # Build a throwaway repo wired to a LOCAL bare origin (no network), seeded into
  # one of three states for the task's feat/demo-task branch. Yields the working
  # checkout for TASK_GIT_DIR so bin/task's git checks run against it.
  def with_git_repo(branch_state)
    Dir.mktmpdir do |root|
      origin = File.join(root, "origin.git")
      work = File.join(root, "work")
      git!(".", "init --quiet --bare #{origin}")
      FileUtils.mkdir_p(work)
      git!(work, "init --quiet")
      git!(work, "config user.email t@t.t")
      git!(work, "config user.name Tester")
      git!(work, "config commit.gpgsign false")
      File.write(File.join(work, "README"), "x")
      git!(work, "add -A")
      git!(work, "commit --quiet -m init")
      git!(work, "branch -M main")
      git!(work, "remote add origin #{origin}")
      git!(work, "push --quiet -u origin main")

      case branch_state
      when :on_main # feat branch == main → its commits are already on main
        git!(work, "branch feat/demo-task main")
        git!(work, "push --quiet origin feat/demo-task")
      when :not_merged # feat branch carries a commit main does not have
        git!(work, "checkout --quiet -b feat/demo-task")
        File.write(File.join(work, "feature.txt"), "y")
        git!(work, "add -A")
        git!(work, "commit --quiet -m feat")
        git!(work, "push --quiet origin feat/demo-task")
        git!(work, "checkout --quiet main")
      when :no_branch then nil # leave feat/demo-task absent
      end
      yield work
    end
  end

  # The headline case: a task whose branch already merged to origin/main (fixed
  # out-of-band) while it lags at building → flagged, with the move suggestion.
  def test_stale_flags_a_branch_already_on_main
    with_git_repo(:on_main) do |work|
      _requests, out, _err, status = run_task(["stale", "demo-task"], env: { "TASK_GIT_DIR" => work })
      assert status.success?
      assert_match(/work already on main/i, out)
      assert_match(/move demo-task shipped/, out)
      assert_match(/archived/, out)
    end
  end

  # A branch with un-merged commits is active, not stale — no false positive.
  def test_stale_reports_a_not_yet_merged_branch_as_active
    with_git_repo(:not_merged) do |work|
      _requests, out, _err, status = run_task(["stale", "demo-task"], env: { "TASK_GIT_DIR" => work })
      assert status.success?
      assert_match(/not yet on main/i, out)
      refute_match(/already on main/i, out)
    end
  end

  # No pushed branch → degrade cleanly (skip), never crash and never false-flag.
  def test_stale_degrades_when_the_branch_does_not_exist
    with_git_repo(:no_branch) do |work|
      _requests, out, _err, status = run_task(["stale", "demo-task"], env: { "TASK_GIT_DIR" => work })
      assert status.success?
      assert_match(%r{no origin/feat/demo-task branch}i, out)
    end
  end

  # --- Active-feature marker: the pinned, no-downgrade session mascot -----------
  # The session's mascot is STICKY. write_feature_marker keeps the last-good on-disk
  # mascot (name + color + emoji) over the MOVED task's, which the board serves
  # WITHOUT mascot_color/mascot_emoji (server-owned, not DEVOPS_KEYS) — the gap that
  # dropped bin/statusline to its pink "🛠 ⊙" fallback when you reviewed someone
  # else's task. A persona ("act as <soul>") is the one deliberate override.

  MARKER_SESSION = "5c5c5c5c-1111-2222-3333-444455556666"

  # Run bin/task with the per-session marker ENABLED, isolated to a throwaway
  # projects dir (CLAUDE_PROJECTS_DIR) and a non-worktree cwd (chdir there) so the
  # `/.worktrees/` skip-guard doesn't suppress the write. `pre_marker` seeds an
  # existing on-disk marker; `fail_get` forces the board read to a non-2xx.
  # Returns [parsed marker hash (or nil if unwritten), process status]. `stub_stage`
  # sets the stage the stub serves (the create/move response) — a created task is
  # `designed`, so create tests pass stub_stage: "designed".
  def run_with_marker(args, stub_devops:, pre_marker: nil, fail_get: nil, stub_stage: "building")
    Dir.mktmpdir do |projects|
      sessions = File.join(projects, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      marker_path = File.join(sessions, "#{MARKER_SESSION}.json")
      File.write(marker_path, JSON.generate(pre_marker)) if pre_marker

      _requests, _out, _err, status = run_task(
        args,
        env: {
          "CLAUDE_CODE_SESSION_ID" => MARKER_SESSION,
          "CLAUDE_PROJECTS_DIR" => projects,
          "TASK_SKIP_MARKER" => nil # nil deletes it from the child → the marker writes
        },
        stub_devops: stub_devops,
        stub_stage: stub_stage,
        chdir: projects, # a non-worktree cwd so write_feature_marker doesn't skip
        fail_get: fail_get
      )

      marker = File.exist?(marker_path) ? JSON.parse(File.read(marker_path)) : nil
      [marker, status]
    end
  end

  # --- create + the active-feature marker (the self-claim fix) ----------------

  # By DEFAULT, create repoints the session marker to the new task (genesis
  # trickle-down — your status line shows what you just filed). But a created task
  # is `designed`, so the marker carries stage=designed — which bin/statusline +
  # `bin/task heartbeat` both refuse to renew. So create no longer self-CLAIMS,
  # even though it still sets display context.
  def test_create_repoints_the_marker_as_designed_not_building
    marker, status = run_with_marker(
      ["create", "--title", "A fresh follow-up", "--kind", "chore"],
      stub_devops: { "kind" => "chore" },
      stub_stage: "designed"
    )
    assert status.success?
    refute_nil marker, "create still writes the display marker by default"
    assert_equal "demo-task", marker["slug"]
    assert_equal "designed", marker["stage"], "the marker carries the real `designed` stage — never a self-claim"
  end

  # --no-claim files the task WITHOUT touching the session marker at all — the
  # conductor (bin/release) filing follow-ups must not drag its status line (and
  # its live build-claim) off whatever it was onto each fresh `designed` task.
  def test_create_no_claim_leaves_an_active_build_marker_untouched
    active = { "slug" => "my-active-build", "task_slug" => "my-active-build",
               "stage" => "building", "mascot" => "eevee" }
    marker, status = run_with_marker(
      ["create", "--no-claim", "--title", "A filed follow-up", "--kind", "chore"],
      stub_devops: { "kind" => "chore" },
      stub_stage: "designed",
      pre_marker: active
    )
    assert status.success?
    assert_equal "my-active-build", marker["slug"], "--no-claim must not repoint the marker"
    assert_equal "building", marker["stage"], "the conductor's real build-claim context is preserved"
  end

  # --- genesis: the session's write-once first task ---------------------------

  # The session's FIRST task-bearing marker write seeds genesis_* — the durable
  # "why was this session spun up" the status line keeps its bearing on.
  def test_first_marker_write_seeds_the_genesis_fields
    marker, status = run_with_marker(
      ["create", "--title", "A fresh fixture task", "--kind", "feature"],
      stub_devops: { "kind" => "feature", "worktree_slug" => "fixture-feature" },
      stub_stage: "designed"
    )
    assert status.success?
    assert_equal "demo-task", marker["genesis_slug"], "the first task IS the genesis"
    assert_equal "fixture-feature", marker["genesis_feature"]
    assert_includes marker["genesis_url"].to_s, "/tasks/demo-task"
    refute_nil marker["genesis_at"]
  end

  # The guarantee under test: a later create/move repoints the ACTIVE context
  # (slug/app/feature/stage) but the genesis is carried forward verbatim.
  def test_later_writes_repoint_the_active_context_but_never_the_genesis
    origin = {
      "slug" => "origin-task", "task_slug" => "origin-task", "stage" => "building",
      "genesis_slug" => "origin-task", "genesis_feature" => "origin-task",
      "genesis_url" => "https://mcritchie.studio/tasks/origin-task",
      "genesis_at" => "2026-08-09T09:00:00Z"
    }
    marker, status = run_with_marker(
      ["move", "demo-task", "building"],
      stub_devops: { "kind" => "feature" },
      pre_marker: origin
    )
    assert status.success?
    assert_equal "demo-task", marker["slug"], "the active context repoints to the moved task"
    assert_equal "origin-task", marker["genesis_slug"], "the genesis never repoints"
    assert_equal "2026-08-09T09:00:00Z", marker["genesis_at"], "carried forward verbatim, not re-stamped"
  end

  # A pre-genesis marker (mascot-only, written by session-mascot before any task)
  # is NOT a genesis: the first TASK-bearing write still seeds it.
  def test_a_task_less_marker_does_not_preempt_the_genesis
    marker, = run_with_marker(
      ["move", "demo-task", "building"],
      stub_devops: { "kind" => "feature" },
      pre_marker: { "mascot" => "eevee", "app" => "mcritchie-studio" }
    )
    assert_equal "demo-task", marker["genesis_slug"],
                 "the first task-bearing write seeds genesis even after a mascot-only marker"
  end

  # The bug: a move whose API response carries NO mascot must NOT blank an
  # already-known mascot out of the marker — that flip-flops bin/statusline off
  # its ⊙<mascot> handle to the bare task-link fallback. The last-good on-disk
  # value is kept instead.
  def test_marker_keeps_a_known_mascot_when_the_response_lacks_one
    marker, = run_with_marker(
      ["move", "demo-task", "building"],
      stub_devops: { "kind" => "feature" }, # response carries no mascot
      pre_marker: { "slug" => "demo-task", "mascot" => "snorlax" } # last-good on disk
    )
    refute_nil marker, "the marker must still be written"
    assert_equal "snorlax", marker["mascot"], "a mascot-less response must not downgrade the marker"
  end

  # The COLOR analog of the mascot stickiness: a mascot-less response must keep the
  # last-good COLOR too, not just the name. Before the fix the name stuck (via the
  # on-disk fallback) but mascot_color read straight from the empty response, so it
  # dropped to nil and bin/statusline reverted ⊙<Name> to the default pink tint
  # while the name stayed. Regression for the reverting-color bug.
  def test_marker_keeps_a_known_mascot_color_when_the_response_lacks_one
    marker, = run_with_marker(
      ["move", "demo-task", "building"],
      stub_devops: { "kind" => "feature" }, # response carries no mascot, color, or emoji
      pre_marker: { "slug" => "demo-task", "mascot" => "dugtrio",
                    "mascot_color" => "#E2BF65", "mascot_emoji" => "🏔" }
    )
    assert_equal "dugtrio", marker["mascot"], "the name still sticks"
    assert_equal "#E2BF65", marker["mascot_color"],
                 "and its color rides with it — no revert to the default tint"
    assert_equal "🏔", marker["mascot_emoji"],
                 "and its type emoji rides with it too — no revert to the 🛠 ⊙ glyphs"
  end

  # The core user scenario: reviewing/moving ANOTHER session's task. Its response
  # carries that task's mascot — name only, no color/emoji (the board doesn't serve
  # them). The pinned session mascot must stay, name + color + emoji intact; the
  # stray mascot is ignored, never replacing the pin with a pink-fallback handle.
  def test_a_stray_response_mascot_never_replaces_the_pinned_session_mascot
    marker, = run_with_marker(
      ["move", "demo-task", "reviewed"],
      stub_devops: { "kind" => "bug", "mascot" => "rhyhorn" }, # another task's mascot, no color/emoji
      pre_marker: { "slug" => "demo-task", "mascot" => "dugtrio",
                    "mascot_color" => "#E2BF65", "mascot_emoji" => "🏔" }
    )
    assert_equal "dugtrio", marker["mascot"], "the pinned session mascot stays"
    assert_equal "#E2BF65", marker["mascot_color"], "its color rides with it"
    assert_equal "🏔", marker["mascot_emoji"], "and its emoji"
    refute_equal "rhyhorn", marker["mascot"], "the stray task mascot is ignored"
  end

  # Even a FULLY attributed stray (color + emoji and all) does not override the pin —
  # the session's own mascot owns the line; another task's identity never hijacks it.
  def test_even_a_fully_attributed_stray_mascot_does_not_override_the_pin
    marker, = run_with_marker(
      ["move", "demo-task", "reviewed"],
      stub_devops: { "kind" => "bug", "mascot" => "gengar",
                     "mascot_color" => "#735797", "mascot_emoji" => "👻" },
      pre_marker: { "slug" => "demo-task", "mascot" => "dugtrio",
                    "mascot_color" => "#E2BF65", "mascot_emoji" => "🏔" }
    )
    assert_equal "dugtrio", marker["mascot"], "the pin holds even over a colored stray"
    assert_equal "#E2BF65", marker["mascot_color"]
    assert_equal "🏔", marker["mascot_emoji"]
  end

  # No pin yet (a fresh session that skipped the session-mascot hook): with nothing
  # on disk to keep, the response's mascot IS adopted — SessionMascot makes it the
  # session handle anyway, and any missing color/emoji renders clean, never pink.
  def test_marker_adopts_the_response_mascot_when_no_disk_marker
    marker, = run_with_marker(
      ["move", "demo-task", "reviewed"],
      stub_devops: { "kind" => "bug", "mascot" => "gengar" },
      pre_marker: nil
    )
    assert_equal "gengar", marker["mascot"], "no pin → adopt the response mascot"
  end

  # The one deliberate override: "act as <soul>" stamps the soul's name+color+emoji
  # and carries a `persona` flag, which DOES replace the pinned Pokémon.
  def test_a_persona_response_overrides_the_pinned_session_mascot
    marker, = run_with_marker(
      ["move", "demo-task", "reviewed"],
      stub_devops: { "kind" => "bug", "persona" => "jasper", "mascot" => "Jasper",
                     "mascot_color" => "#22D3EE", "mascot_emoji" => "🧪" },
      pre_marker: { "slug" => "demo-task", "mascot" => "dugtrio",
                    "mascot_color" => "#E2BF65", "mascot_emoji" => "🏔" }
    )
    assert_equal "Jasper", marker["mascot"], "a persona overrides the pin"
    assert_equal "#22D3EE", marker["mascot_color"]
    assert_equal "🧪", marker["mascot_emoji"]
  end

  # The board-fallback path: when BOTH the response and the on-disk marker lack a
  # mascot, marker_mascot falls through to a board API read (board_mascot). That
  # read MUST NOT be able to abort the command. board_mascot used to call api()
  # in-process, so a non-2xx board read → api's die! → exit 1 → SystemExit, which
  # is NOT a StandardError and so escaped BOTH board_mascot's and
  # write_feature_marker's `rescue StandardError` — killing the whole move with
  # exit 1 AFTER its stage PATCH had already landed (a false command failure on a
  # transient board 429 / 5xx). A non-building move isolates the board read as the
  # only task GET, so fail_get hits exactly that read. Regression for PR #158.
  def test_a_board_read_failure_never_aborts_the_command
    marker, status = run_with_marker(
      ["move", "demo-task", "reviewed"],     # non-building: the board read is the only task GET
      stub_devops: { "kind" => "feature" },  # response carries no mascot → fall through
      pre_marker: nil,                       # nothing on disk → the board lambda is reached
      fail_get: 503                          # the board GET fails (a transient 5xx / 429)
    )
    assert status.success?, "a failed board read must not abort the command (expected exit 0)"
    refute_nil marker, "the marker must still be written despite the failed board read"
    assert_nil marker["mascot"], "an unreachable board cleanly yields no mascot (no downgrade, no abort)"
    assert_equal "demo-task", marker["slug"]
  end

  # --- session-mascot: paint the session's mascot before any task exists -------

  # The SessionStart-hook command draws the session's mascot from the board and
  # writes it (with color + emoji) to the per-session marker, so bin/statusline
  # shows it in seconds — no task required.
  def test_session_mascot_writes_the_session_marker
    Dir.mktmpdir do |projects|
      FileUtils.mkdir_p(File.join(projects, ".agents", "sessions"))
      marker_path = File.join(projects, ".agents", "sessions", "#{MARKER_SESSION}.json")

      _req, _out, _err, status = run_task(
        ["session-mascot"],
        env: { "CLAUDE_CODE_SESSION_ID" => MARKER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )

      assert status.success?
      assert File.exist?(marker_path), "the session marker is written before any task"
      marker = JSON.parse(File.read(marker_path))
      assert_equal "snorlax", marker["mascot"]
      assert_equal "#A8A77A", marker["mascot_color"]
      assert_equal "🔶", marker["mascot_emoji"]
    end
  end

  def test_session_mascot_writes_shiny_marker_fields
    Dir.mktmpdir do |projects|
      FileUtils.mkdir_p(File.join(projects, ".agents", "sessions"))
      marker_path = File.join(projects, ".agents", "sessions", "#{MARKER_SESSION}.json")

      _req, _out, _err, status = run_task(
        ["session-mascot"],
        env: { "CLAUDE_CODE_SESSION_ID" => MARKER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects,
        stub_session_mascot: { "mascot" => "snorlax", "mascot_color" => "#A8A77A",
                               "mascot_emoji" => "🔶", "mascot_shiny" => true,
                               "app" => "mcritchie-studio", "app_color" => "#B57EDC" }
      )

      assert status.success?
      marker = JSON.parse(File.read(marker_path))
      assert_equal true, marker["mascot_shiny"]
      assert_equal "🔶✨", marker["mascot_emoji"]
    end
  end

  def test_session_mascot_writes_a_codex_session_marker_and_prints_it
    Dir.mktmpdir do |projects|
      marker_path = File.join(projects, ".agents", "sessions", "#{MARKER_SESSION}.json")

      _req, out, _err, status = run_task(
        ["session-mascot", "--print"],
        env: { "CODEX_THREAD_ID" => MARKER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )

      assert status.success?
      marker = JSON.parse(File.read(marker_path))
      assert_equal "snorlax", marker["mascot"]
      assert_equal "mcritchie-studio", marker["app"]
      assert_equal "🔶 Snorlax · mcritchie-studio", out.strip
    end
  end

  def test_session_mascot_sends_parent_session_context_when_present
    Dir.mktmpdir do |projects|
      requests, _out, _err, status = run_task(
        ["session-mascot"],
        env: { "CODEX_THREAD_ID" => MARKER_SESSION,
               "MCRITCHIE_PARENT_SESSION_ID" => OTHER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )

      assert status.success?
      mascot_request = requests.find { |req| req[:path] == "/api/v1/sessions/#{MARKER_SESSION}/mascot" }
      assert_equal({ "parent_session_id" => OTHER_SESSION }, JSON.parse(mascot_request[:body]))
    end
  end

  # No session → a clean no-op (the hook must never break or delay session start).
  def test_session_mascot_is_a_noop_without_a_session
    Dir.mktmpdir do |projects|
      _req, _out, _err, status = run_task(
        ["session-mascot"],
        env: { "CLAUDE_CODE_SESSION_ID" => nil,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )
      assert status.success?, "no session id → silent success, no crash"
    end
  end

  # It MERGES into an existing marker (a task already wrote one), never wiping the
  # app/feature/task context — only setting the mascot trio.
  def test_session_mascot_merges_into_an_existing_marker
    Dir.mktmpdir do |projects|
      FileUtils.mkdir_p(File.join(projects, ".agents", "sessions"))
      marker_path = File.join(projects, ".agents", "sessions", "#{MARKER_SESSION}.json")
      File.write(marker_path, JSON.generate("slug" => "demo-task", "app" => "mcritchie-studio"))

      run_task(
        ["session-mascot"],
        env: { "CLAUDE_CODE_SESSION_ID" => MARKER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )

      marker = JSON.parse(File.read(marker_path))
      assert_equal "demo-task", marker["slug"], "existing context is preserved"
      assert_equal "mcritchie-studio", marker["app"]
      assert_equal "snorlax", marker["mascot"], "…and the mascot is set"
    end
  end

  def test_session_mascot_persona_temporarily_replaces_then_reverts
    Dir.mktmpdir do |projects|
      marker_path = File.join(projects, ".agents", "sessions", "#{MARKER_SESSION}.json")

      _req, out, _err, status = run_task(
        ["session-mascot", "--persona", "jasper", "--print"],
        env: { "CODEX_THREAD_ID" => MARKER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )

      assert status.success?
      marker = JSON.parse(File.read(marker_path))
      assert_equal "jasper", marker["persona"]
      assert_equal "Jasper", marker["mascot"]
      assert_equal "🧪 Jasper · mcritchie-studio", out.strip

      _req, out, _err, status = run_task(
        ["session-mascot", "--persona", "none", "--print"],
        env: { "CODEX_THREAD_ID" => MARKER_SESSION,
               "CLAUDE_PROJECTS_DIR" => projects, "TASK_SKIP_MARKER" => nil },
        chdir: projects
      )

      assert status.success?
      marker = JSON.parse(File.read(marker_path))
      refute marker.key?("persona")
      assert_equal "snorlax", marker["mascot"]
      assert_equal "🔶 Snorlax · mcritchie-studio", out.strip
    end
  end

  # --- Size trio flags (--po-size / --dev-size / --pm-size) -------------------

  # Avi (the default sizer) seeds po_size at creation; the sizes are TOP-LEVEL
  # Task columns, sent as top-level body keys (not nested under devops).
  def test_create_sends_size_columns_at_top_level
    requests, = run_task(["create", "--title", "Sized new task", "--po-size", "medium", "--pm-size", "small"])
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create
    body = JSON.parse(create[:body])
    assert_equal "medium", body["po_size"], "po_size rides as a top-level column, not in devops"
    assert_equal "small", body["pm_size"]
    refute body.dig("devops", "po_size"), "sizes must NOT leak into devops"
  end

  # update can backfill a size later (size isn't required at creation).
  def test_update_sends_size_columns_at_top_level
    requests, = run_task(["update", "demo-task", "--po-size", "large"])
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    assert_equal "large", JSON.parse(patch[:body])["po_size"]
  end

  def test_update_sends_operator_approval_status
    requests, = run_task(
      ["update", "demo-task", "--approval", "waiting", "--local-url", "http://localhost:3001/demo"]
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    devops = JSON.parse(patch[:body]).fetch("devops")
    assert_equal "waiting", devops["approval_status"]
    assert_equal "http://localhost:3001/demo", devops["local_url"]
  end

  # --- cert evidence is machine-owned (regression) ---
  # `--checks` REPLACES the author's checks_run lines. It must NOT be able to
  # replace the fingerprint-bound cert lines bin/fast-check / bin/full-suite-check
  # stamp: recording a test plan after certifying used to wipe the cert, and
  # bin/dor-check then called freshly certified code "full-suite: MISSING". The
  # CLI already GETs the task before the PATCH, so it carries the evidence forward
  # itself — the board enforces the same rule for every other writer.
  FULL_EVIDENCE = "[full-suite@1512171634558ef1234567890abcdef123456789] bin/rails test (782 runs, 0 failures)"
  RUBOCOP_EVIDENCE = "[rubocop@1512171634558ef1234567890abcdef123456789] bin/rubocop (clean)"

  def test_update_checks_preserves_machine_written_cert_evidence
    requests, = run_task(
      ["update", "demo-task", "--checks", "[unit] bin/rails test test/models", "--checks",
       "[integration] bin/rails test test/controllers"],
      stub_devops: { "kind" => "bug", "checks_run" => [FULL_EVIDENCE, RUBOCOP_EVIDENCE] }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    checks = JSON.parse(patch[:body]).dig("devops", "checks_run")
    assert_includes checks, FULL_EVIDENCE, "--checks wiped the full-suite cert evidence"
    assert_includes checks, RUBOCOP_EVIDENCE, "--checks wiped the rubocop cert evidence"
    assert_includes checks, "[unit] bin/rails test test/models"
    assert_includes checks, "[integration] bin/rails test test/controllers"
  end

  # The author's OWN lines are still replaced wholesale — --checks stays a
  # replace, just scoped to the namespace the author owns.
  def test_update_checks_still_replaces_author_lines
    requests, = run_task(
      ["update", "demo-task", "--checks", "[unit] fresh plan"],
      stub_devops: { "kind" => "bug", "checks_run" => ["[unit] stale plan", FULL_EVIDENCE] }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    assert_equal ["[unit] fresh plan", FULL_EVIDENCE], JSON.parse(patch[:body]).dig("devops", "checks_run")
  end

  # A cert writer supersedes the lanes it SUPPLIES (that is how bin/fast-check and
  # bin/full-suite-check re-stamp their own lane) — the rest is carried over.
  def test_update_checks_supersedes_a_lane_it_supplies
    stale_full = "[full-suite@0000000000000000000000000000000000000000] bin/rails test (781 runs, 0 failures)"
    requests, = run_task(
      ["update", "demo-task", "--checks", "[unit] plan", "--checks", FULL_EVIDENCE],
      stub_devops: { "kind" => "bug", "checks_run" => ["[unit] plan", stale_full, RUBOCOP_EVIDENCE] }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    checks = JSON.parse(patch[:body]).dig("devops", "checks_run")
    assert_equal ["[unit] plan", FULL_EVIDENCE, RUBOCOP_EVIDENCE], checks
    refute_includes checks, stale_full, "a re-cert must replace its own stale lane"
  end

  # The reverse regression (2026-07-20, fast-check-preserves-checks): a cert
  # writer whose OWN read of checks_run came back stale/empty sends a
  # PURE-EVIDENCE --checks update. The CLI's read-merge (build_devops) reads the
  # board's CURRENT list right before the PATCH, so it must carry the tier tags
  # the writer's stale read missed — a write that supplies no author line may not
  # supersede the author namespace.
  def test_pure_evidence_update_carries_the_boards_tier_tags
    fast = "[fast-cert@1512171634558ef1234567890abcdef123456789] fast cert green: 4 mapped"
    requests, = run_task(
      ["update", "demo-task", "--checks", fast],
      stub_devops: { "kind" => "bug",
                     "checks_run" => ["[unit] bin/rails test test/models",
                                      "[integration] bin/rails test test/controllers"] }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    checks = JSON.parse(patch[:body]).dig("devops", "checks_run")
    assert_includes checks, "[unit] bin/rails test test/models",
                    "a pure-evidence cert write wiped the builder's tier tags"
    assert_includes checks, "[integration] bin/rails test test/controllers"
    assert_includes checks, fast
  end

  def test_update_normalizes_dashed_approval_status
    requests, = run_task(["update", "demo-task", "--approval-status", "changes-requested"])
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    assert_equal "changes_requested", JSON.parse(patch[:body]).dig("devops", "approval_status")
  end

  # An invalid size is rejected client-side (exit 1, clear message) BEFORE any
  # request goes out — never reaching the API as a 422.
  def test_create_rejects_an_invalid_size
    requests, _out, err, status = run_task(["create", "--title", "Bad size task", "--po-size", "huge"])
    refute status.success?, "an invalid size must fail fast"
    assert_match(/--po-size must be one of: small, medium, large, xl/, err)
    assert_nil requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" },
               "a rejected size must not POST the task"
  end

  def test_update_rejects_an_invalid_approval_status
    requests, _out, err, status = run_task(["update", "demo-task", "--approval", "maybe"])
    refute status.success?, "an invalid approval status must fail fast"
    assert_match(/--approval must be one of: waiting, approved, changes_requested, none/, err)
    assert_nil requests.find { |r| r[:method] == "PATCH" },
               "a rejected approval status must not PATCH the task"
  end

  # AC #3: the builder Pokémon stamps its own dev_size as it claims the task at
  # `building` — a top-level column alongside the stage move + claim devops.
  def test_move_to_building_with_dev_size_sets_the_column
    requests, = run_task(
      ["move", "demo-task", "building", "--dev-size", "medium"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch
    parsed = JSON.parse(patch[:body])
    assert_equal "building", parsed["stage"]
    assert_equal "medium", parsed["dev_size"], "the builder's estimate rides as a top-level column"
    assert_equal SESSION, parsed.dig("devops", "claimed_session"), "the claim still lands alongside it"
  end

  # A bare building move (no --dev-size) sends no dev_size — it's optional.
  def test_move_to_building_without_dev_size_omits_the_column
    requests, = run_task(["move", "demo-task", "building"], env: { "CLAUDE_CODE_SESSION_ID" => SESSION })
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute JSON.parse(patch[:body]).key?("dev_size"), "absent --dev-size sends no dev_size"
  end

  def test_move_rejects_an_invalid_dev_size
    _requests, _out, err, status = run_task(
      ["move", "demo-task", "building", "--dev-size", "enormous"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    refute status.success?
    assert_match(/--dev-size must be one of: small, medium, large, xl/, err)
  end

  # --- Unknown flags must be REJECTED, never silently dropped -----------------
  # The old parse_flags whitelist-and-skip loop dropped an unrecognized flag (and
  # its value) into ignored positionals and exited 0 — `update <slug> --pr <url>`
  # printed the task as if the PR were recorded while the board still said
  # `pr: -`, and bin/dor-check then failed NO_PR naming nothing about the real
  # cause. A CLI must never report an operation that did not happen.

  # The headline regression: --pr (the real flag is --pr-url) alongside a valid
  # flag used to exit 0 and PATCH without the PR — data silently dropped.
  def test_update_with_unknown_flag_dies_and_suggests_the_real_one
    requests, _out, err, status = run_task(
      ["update", "demo-task", "--pr", "https://github.com/x/y/pull/1", "--kind", "bug"]
    )
    refute status.success?, "an unknown flag must exit nonzero, not report success"
    assert_empty requests, "the rejection must fire BEFORE auth or any PATCH — no partial write"
    assert_match(/unknown flag "--pr"/, err, "the error names the offending flag")
    assert_match(/--pr-url/, err, "and suggests the nearest valid flag")
  end

  # The second failure mode: the unknown flag's VALUE also fell through to the
  # ignored positionals — both tokens vanished. Prove the value can never ride
  # into the request body as a stray positional or scalar.
  def test_create_with_unknown_flag_dies_instead_of_dropping_its_value
    requests, _out, err, status = run_task(
      ["create", "--title", "Some new task", "--pr", "https://github.com/x/y/pull/1"]
    )
    refute status.success?
    assert_empty requests, "no POST fires — the task is not created with the flag+value dropped"
    assert_match(/unknown flag "--pr"/, err)
  end

  def test_list_with_unknown_flag_dies_naming_it
    requests, _out, err, status = run_task(["list", "--stag", "building"])
    refute status.success?
    assert_empty requests
    assert_match(/unknown flag "--stag"/, err)
    assert_match(/--stage/, err, "a close typo earns a suggestion")
  end

  # --reviewable is the parallel-review queue filter: the SOP documents
  # `bin/task list --stage submitted --reviewable`, so the flag must be ACCEPTED (not
  # "unknown flag") and must append reviewable=1 — the same read as
  # GET /api/v1/tasks?reviewable=1, powered by Task.reviewable.
  def test_list_reviewable_appends_the_query_param
    requests, _out, err, status = run_task(["list", "--stage", "submitted", "--reviewable"])
    assert status.success?, "--reviewable is a valid list filter, not an unknown flag (#{err})"
    get = requests.find { |r| r[:method] == "GET" && r[:path].start_with?("/api/v1/tasks?") }
    assert get, "list issues a GET to the tasks index"
    assert_includes get[:path], "stage=submitted"
    assert_includes get[:path], "reviewable=1", "--reviewable appends reviewable=1"
  end

  # A misspelling (not a prefix) still earns the nearest-flag suggestion.
  def test_update_with_misspelled_flag_suggests_the_nearest_one
    _requests, _out, err, status = run_task(
      ["update", "demo-task", "--pr-ulr", "https://github.com/x/y/pull/1"]
    )
    refute status.success?
    assert_match(/unknown flag "--pr-ulr"/, err)
    assert_match(/--pr-url/, err)
  end

  # Strict subcommand loops (move/intent/...) already died on unknown flags; they
  # must keep doing so AND now honor --help (below) — pin the move contract.
  def test_move_with_unknown_flag_still_dies_naming_the_valid_set
    requests, _out, err, status = run_task(["move", "demo-task", "building", "--sizes", "small"])
    refute status.success?
    assert_empty requests
    assert_match(/unknown flag "--sizes"/, err)
    assert_match(/--dev-size/, err, "the valid flags (or a suggestion) are named")
  end

  # session-mascot's best-effort rescue used to swallow the die! — an unknown
  # flag printed the error yet exited 0. Parsing now fails before best-effort.
  def test_session_mascot_with_unknown_flag_exits_nonzero
    _requests, _out, err, status = run_task(
      ["session-mascot", "--bogus"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    refute status.success?, "a parse error must not be swallowed by the best-effort rescue"
    assert_match(/unknown flag "--bogus"/, err)
  end

  # --- --help / -h print usage from any position; a flag is never a slug ------
  # `bin/task update --help` used to parse "--help" as the SLUG and 404 against
  # GET /api/v1/tasks/--help — actively misleading the one agent already confused
  # about the flags.

  def test_update_help_prints_usage_instead_of_a_slug_404
    requests, _out, err, status = run_task(["update", "--help"])
    assert status.success?, "--help exits 0"
    assert_empty requests, "no GET /api/v1/tasks/--help — help is never a slug"
    assert_match(/Usage:/, err)
  end

  def test_top_level_help_flag_prints_usage_and_exits_zero
    requests, _out, err, status = run_task(["--help"])
    assert status.success?
    assert_empty requests
    assert_match(/Usage:/, err)
  end

  def test_move_help_in_slug_position_prints_usage
    requests, _out, err, status = run_task(["move", "--help"])
    assert status.success?
    assert_empty requests
    assert_match(/Usage:/, err)
  end

  def test_move_help_in_flag_position_prints_usage
    requests, _out, err, status = run_task(["move", "demo-task", "building", "--help"])
    assert status.success?
    assert_empty requests, "help must print before any PATCH"
    assert_match(/Usage:/, err)
  end

  # Any other dashed token where a slug belongs dies loudly instead of becoming
  # a 404ing GET /api/v1/tasks/<flag>.
  def test_show_rejects_a_flag_in_slug_position
    requests, _out, err, status = run_task(["show", "--json"])
    refute status.success?
    assert_empty requests, "no GET /api/v1/tasks/--json"
    assert_match(/"--json"/, err, "the error names the misplaced flag")
  end

  # show's trailing flags are a closed set — a typo'd one must not silently
  # downgrade the output to the terse view.
  def test_show_with_unknown_trailing_flag_dies
    _requests, _out, err, status = run_task(["show", "demo-task", "--jsn"])
    refute status.success?
    assert_match(/unknown flag "--jsn"/, err)
    assert_match(/--json/, err)
  end

  # --- exit codes are a CONTRACT: 4 = the board ANSWERED "no such task" --------
  #
  # bin/agent-worktree's reclaim guard frees a desk when the board positively
  # answers "there is no such task" and WITHHOLDS it when the read failed — and it
  # classifies on bin/task's exit code (EXIT_TASK_NOT_FOUND = 4). These pins are
  # load-bearing on a destroy path: 4 must fire ONLY on the API's own not-found
  # answer (HTTP 404 + its exact "task not found" body), and every FAILED read —
  # 5xx, a Heroku router 404, a route-level 404 — must stay on 1, or an outage
  # reclassifies as "task gone → free to tear the desk down".

  TASK_NOT_FOUND_BODY = JSON.generate("error" => "task not found", "error_code" => "NOT_FOUND")

  def test_show_exits_4_when_the_board_answers_task_not_found
    _requests, _out, err, status = run_task(["show", "gone-task"], fail_get: 404, fail_get_body: TASK_NOT_FOUND_BODY)
    assert_equal 4, status.exitstatus, "the API's own 404 body is a definite answer -> EXIT_TASK_NOT_FOUND"
    # Older bin/agent-worktree classifies by pattern-matching this exact stderr
    # rendering ("-> 404" + "task not found"); the new exit code must not change it.
    assert_match(/-> 404: task not found/, err, "the stderr rendering old classifiers fall back on must survive")
  end

  # The contract lives in api(), not in a `show` special case — any slug-reading
  # command answers the same way (agent tooling shells out to more than `show`).
  def test_field_exits_4_when_the_board_answers_task_not_found
    _requests, _out, _err, status = run_task(["field", "gone-task", "mascot"], fail_get: 404,
                                                                               fail_get_body: TASK_NOT_FOUND_BODY)
    assert_equal 4, status.exitstatus, "the not-found exit code is shared by every API-reading command"
  end

  def test_show_exits_1_on_a_router_style_404
    _requests, _out, _err, status = run_task(
      ["show", "gone-task"],
      fail_get: 404, fail_get_body: "<!DOCTYPE html><html><body>There's nothing here, yet.</body></html>"
    )
    assert_equal 1, status.exitstatus,
                 "a 404 WITHOUT the API's body (Heroku router: app renamed/deleted) is a FAILED read, not an answer"
  end

  def test_show_exits_1_on_a_route_level_404
    _requests, _out, _err, status = run_task(
      ["show", "gone-task"],
      fail_get: 404, fail_get_body: JSON.generate("error" => "Not found", "error_code" => "NOT_FOUND")
    )
    assert_equal 1, status.exitstatus,
                 "the generic 'Not found' backstop is not the tasks API's own answer — a moved path or a " \
                 "stale board must read as a failed read, exactly as the stderr classifier treats it"
  end

  def test_show_exits_1_on_a_transport_failure
    _requests, _out, _err, status = run_task(["show", "gone-task"], fail_get: 500)
    assert_equal 1, status.exitstatus, "a 500 (outage) must never share the not-found code"
  end

  def test_show_exits_0_on_success
    _requests, _out, _err, status = run_task(["show", "demo-task"])
    assert_equal 0, status.exitstatus
  end

  def test_unknown_flag_rejection_never_reads_as_task_not_found
    _requests, _out, _err, status = run_task(["show", "demo-task", "--bogus"])
    assert_equal 1, status.exitstatus,
                 "flag rejection stays exit 1 — distinct from success (0) and from not-found (4): a parse " \
                 "rejection from a version-skewed caller must never read as 'task gone'"
  end

  # --- `bin/task merged` — the accepted-ladder git-location setter (Step B) -----

  def test_merged_sets_the_git_location_via_a_top_level_patch
    requests, out, _err, status = run_task(["merged", "demo-task", "accepted"])
    assert_equal 0, status.exitstatus, "the merged setter succeeds once the read-back confirms it"
    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" }
    refute_nil patch, "expected a PATCH carrying the merged git-location"
    body = JSON.parse(patch[:body])
    assert_equal "accepted", body["merged"], "merged rides as a TOP-LEVEL field, not under devops"
    refute body.key?("stage"), "the merged setter must not move the stage"
    assert_includes out, "merged set on demo-task: accepted"
  end

  def test_merged_accepts_release_and_main_too
    %w[release main].each do |state|
      requests, _out, _err, status = run_task(["merged", "demo-task", state])
      assert_equal 0, status.exitstatus
      patch = requests.find { |r| r[:method] == "PATCH" }
      assert_equal state, JSON.parse(patch[:body])["merged"]
    end
  end

  def test_merged_rejects_an_unknown_git_location_before_any_write
    requests, _out, err, status = run_task(["merged", "demo-task", "somewhere-else"])
    assert_equal 1, status.exitstatus, "an unknown git-location is a client-side reject"
    assert_match(/must be one of/, err)
    assert_empty requests.select { |r| r[:method] == "PATCH" }, "nothing is written on a rejected value"
  end

  def test_merged_needs_both_a_slug_and_a_state
    _requests, _out, _err, status = run_task(["merged", "demo-task"])
    assert_equal 1, status.exitstatus, "the state positional is required"
  end

  # A 200 is not persistence: if the board echoes the value but the write never
  # lands, the read-back must catch it and exit NONZERO — a silently-unstamped
  # `reviewed` member would be dropped by the sweep as a HELD anomaly.
  def test_merged_exits_nonzero_when_the_stamp_does_not_persist
    _requests, _out, err, status = run_task(["merged", "demo-task", "accepted"], stub_persist: false)
    assert_equal 1, status.exitstatus, "a non-persisting stamp must not report success"
    assert_match(/merged NOT persisted/, err)
  end

  # THE 2026-07-21 ROOT CAUSE: under board load the merged PATCH drops AND the read-back GET
  # fails together. The verifier read the failed GET as nil and treated nil as "persisted" —
  # absence of signal as success — so a dropped stamp reached a `reviewed` member as merged:None
  # and the sweep left nine tasks stranded. An UNREADABLE read-back must now fail closed, exactly
  # like a blank one: a failed read is never a confirmation.
  def test_merged_exits_nonzero_when_the_read_back_is_unreadable
    _requests, _out, err, status = run_task(["merged", "demo-task", "accepted"], fail_get: 503)
    assert_equal 1, status.exitstatus, "an unconfirmable stamp (board unreadable) must not report success"
    assert_match(/merged NOT persisted/, err)
    assert_match(/unreadable/i, err, "the failure names that the board could not be read")
  end
end
