# frozen_string_literal: true

# Standalone integration test for bin/task's session-resume capture. Shells out
# to bin/task against a localhost stub HTTP server (no Rails, no real network),
# so it deterministically asserts that the CLI stamps devops.session_id +
# session_provider from CLAUDE_CODE_SESSION_ID on `create` and on the move to
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

class TaskCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617"

  # Run bin/task against a one-shot stub server; returns [recorded_requests, out].
  # `env` overrides merge onto a clean base (auth secret + base url + skip marker);
  # a nil value deletes that var from the child (used to clear the session vars so
  # the test never depends on a real ambient session).
  def run_task(args, env: {})
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    base_env = {
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_SESSION_ID" => nil
    }.merge(env)

    out, = Open3.capture2(base_env, RbConfig.ruby, BIN, *args, err: File::NULL)
    [requests, out]
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

      payload = response_for(path)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(path)
    return JSON.generate("token" => "stub-token") if path == "/api/v1/auth"

    # The GET in the move read-merge returns an existing task carrying prior
    # devops, so the test can prove the session stamp is MERGED, not a wipe.
    JSON.generate("data" => {
      "slug" => "demo-task", "stage" => "building",
      "metadata" => { "devops" => { "kind" => "feature" } }
    })
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
end
