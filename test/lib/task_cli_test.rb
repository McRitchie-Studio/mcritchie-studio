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
  def run_task(args, env: {}, stub_devops: { "kind" => "feature" }, stub_stage: "building")
    # The GET response the stub serves — lets a test seed an existing claim so the
    # move-to-building gate (and the heartbeat) read a real claim state.
    @stub_devops = stub_devops
    @stub_stage = stub_stage
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

    out, err, status = Open3.capture3(base_env, RbConfig.ruby, BIN, *args)
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
    # devops (configurable per-test via stub_devops), so the test can prove the
    # session stamp / claim is MERGED, not a wipe, and seed an existing claim.
    JSON.generate("data" => {
      "slug" => "demo-task", "stage" => @stub_stage,
      "metadata" => { "devops" => @stub_devops }
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
end
