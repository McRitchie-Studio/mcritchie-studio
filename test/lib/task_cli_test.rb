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

class TaskCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617"
  OTHER_SESSION = "9f9f9f9f-0000-1111-2222-333344445555"

  # Run bin/task against a one-shot stub server; returns [recorded_requests, out].
  # `env` overrides merge onto a clean base (auth secret + base url + skip marker);
  # a nil value deletes that var from the child (used to clear the session vars so
  # the test never depends on a real ambient session).
  def run_task(args, env: {}, stub_devops: { "kind" => "feature" }, stub_stage: "building", chdir: nil, fail_get: nil,
               stub_session_mascot: { "mascot" => "snorlax", "mascot_color" => "#A8A77A", "mascot_emoji" => "🔶",
                                      "app" => "mcritchie-studio", "app_color" => "#B57EDC" },
               stub_agent: { "name" => "Jasper", "status_color" => "#22D3EE", "emoji" => "🧪" })
    # The GET response the stub serves — lets a test seed an existing claim so the
    # move-to-building gate (and the heartbeat) read a real claim state.
    @stub_devops = stub_devops
    @stub_stage = stub_stage
    # The POST /api/v1/sessions/:id/mascot response (the eager session-mascot draw).
    @stub_session_mascot = stub_session_mascot
    @stub_agent = stub_agent
    # When set, GET /api/v1/tasks/<slug> returns this non-2xx status — used to
    # force the board-mascot fallback read to fail (a transient 429 / 5xx).
    @fail_get = fail_get
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    base_env = {
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      # A fixed instance nonce so the CLI never shells out to `ps` in a test; the
      # gate cases override it to play a second / different live instance.
      "TASK_CLAIM_NONCE" => "inst-default",
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil
    }.merge(env)

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

      status, payload = response_for(method, path)
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
  def response_for(method, path)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"

    if method == "POST" && path =~ %r{\A/api/v1/sessions/.+/mascot\z}
      return ["200 OK", JSON.generate("data" => @stub_session_mascot)]
    end

    if method == "GET" && path =~ %r{\A/api/v1/agents/[^/]+\z}
      return ["200 OK", JSON.generate("data" => @stub_agent)]
    end

    if @fail_get && method == "GET" && path.start_with?("/api/v1/tasks/")
      return ["#{@fail_get} Service Unavailable", JSON.generate("error" => "stubbed board read failure")]
    end

    # The GET in the move read-merge returns an existing task carrying prior
    # devops (configurable per-test via stub_devops), so the test can prove the
    # session stamp / claim is MERGED, not a wipe, and seed an existing claim.
    ["200 OK", JSON.generate("data" => {
      "slug" => "demo-task", "stage" => @stub_stage,
      "metadata" => { "devops" => @stub_devops }
    })]
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

  def test_create_sends_release_slug_metadata
    requests, = run_task(
      ["create", "--title", "Release slug task", "--release-slug", "rel-2026-06-27-docs"]
    )
    create = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil create, "expected a POST /api/v1/tasks"
    devops = devops_of(create)
    assert_equal "rel-2026-06-27-docs", devops["release_slug"]
    refute devops.key?("release_train")
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

  def test_block_agent_flag_stamps_the_block_transition_actor
    requests, = run_task(["block", "demo-task", "--kind", "rework", "--feedback", "Needs rework.", "--agent", "shannon"])
    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" }
    refute_nil patch, "expected a PATCH for the block"

    parsed = JSON.parse(patch[:body])
    assert_equal "blocked", parsed["stage"]
    assert_equal "rework", parsed.dig("devops", "block_kind")
    assert_equal "cli", parsed.dig("event", "source")
    assert_equal "shannon", parsed.dig("event", "actor"), "--agent should persist on the blocked TaskEvent"

    note = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    refute_nil note, "expected a qa_feedback activity"
    assert_equal "shannon", JSON.parse(note[:body])["agent_slug"]
  end

  def test_block_without_a_named_actor_does_not_stamp_the_raw_session
    requests, = run_task(
      ["block", "demo-task", "--kind", "dependency"],
      env: { "CLAUDE_CODE_SESSION_ID" => SESSION }
    )
    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" }
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

    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" }
    parsed = JSON.parse(patch[:body])
    assert_equal "blocked", parsed["stage"]
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

      patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" }
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

    patch = requests.find { |r| r[:method] == "PATCH" && r[:path] == "/api/v1/tasks/demo-task" }
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
      assert_equal 6150, event["tokens_in"]   # 100 + 50 + 6000
      assert_equal 4000, event["tokens_out"]
      assert_equal "0.1038", event["cost"]     # (100*5 + 4000*25 + 50*5*1.25 + 6000*5*0.1)/1e6
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
      assert_equal 500, event["tokens_in"]
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
      assert_equal 6150, event["tokens_in"], "delta is turn 2 only — the review work since the intent"
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
      assert_equal 6150, event["tokens_in"], "delta is turn 2 only — the design work since create"
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

  # An invalid size is rejected client-side (exit 1, clear message) BEFORE any
  # request goes out — never reaching the API as a 422.
  def test_create_rejects_an_invalid_size
    requests, _out, err, status = run_task(["create", "--title", "Bad size task", "--po-size", "huge"])
    refute status.success?, "an invalid size must fail fast"
    assert_match(/--po-size must be one of: small, medium, large, xl/, err)
    assert_nil requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" },
               "a rejected size must not POST the task"
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
end
