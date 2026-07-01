# frozen_string_literal: true

# Tests for bin/atomic-event — the agent's self-narration CLI (start/end a span).
#
#   ruby -Itest test/lib/atomic_event_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the pure helpers — argv parsing, session resolution, the local
#                 category guard — loaded in process (main is guarded so `load`
#                 is side-effect free).
#   [integration] the real script, shelled out against a localhost stub HTTP
#                 server, mints a token then POSTs the right open/close shape.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"

load File.expand_path("../../bin/atomic-event", __dir__)

class AtomicEventCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/atomic-event", __dir__)
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

  def cli(env = {})
    AtomicEventCli.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env))
  end

  # ── [unit] argv + session resolution ─────────────────────────────────────

  def test_unit_parse_flags_reads_double_dash_values
    flags = cli.parse_flags(%w[--category Explore --reason find issue])
    assert_equal "Explore", flags["category"]
    # A bare token after the value is not a flag — last --flag wins its next token.
    assert_equal "find", flags["reason"]
  end

  def test_unit_session_prefers_explicit_then_env
    assert_equal "flag-sid", cli.resolve_session_id("session" => "flag-sid")
    assert_equal "claude-sid",
                 cli("CLAUDE_CODE_SESSION_ID" => "claude-sid").resolve_session_id({})
    assert_equal "codex-sid",
                 cli("CODEX_THREAD_ID" => "codex-sid").resolve_session_id({})
    assert_equal "", cli.resolve_session_id({})
  end

  def test_unit_category_vocabulary_matches_the_model
    assert_equal %w[Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan],
                 AtomicEventCli::CATEGORIES
  end

  # ── [unit] resolve_marker: base mascot = session, task_slug/stage = desk ──

  def test_unit_resolve_marker_base_mascot_is_the_session_not_the_desk
    Dir.mktmpdir do |proj|
      proj = File.realpath(proj)
      # The bound task's DESK marker (.agent-context.json) carries the TASK's
      # builder mascot — the value that used to FLIP the base (Shellder→Sandshrew).
      write_context_marker(proj, "task_record_slug" => "desk-task",
                                 "mascot" => "sandshrew", "stage" => "reviewed")
      # The session marker carries the session's OWN Pokémon (its stable base).
      write_session_marker(proj, SESSION, "mascot" => "shellder")

      marker = Dir.chdir(proj) { cli("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(session_id: SESSION) }

      assert_equal "shellder", marker["mascot"], "base mascot = the session's OWN, never the desk/task builder mascot"
      assert_equal "desk-task", marker["task_slug"], "task_slug still describes the desk"
      assert_equal "reviewed", marker["stage"], "stage still describes the desk"
    end
  end

  def test_unit_resolve_marker_falls_back_to_desk_mascot_when_the_session_has_none
    Dir.mktmpdir do |proj|
      proj = File.realpath(proj)
      write_context_marker(proj, "task_record_slug" => "desk-task", "mascot" => "sandshrew")
      # No session-marker mascot → fall back to the desk so we never regress to nil.
      marker = Dir.chdir(proj) { cli("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(session_id: SESSION) }

      assert_equal "sandshrew", marker["mascot"]
    end
  end

  # ── [integration] start POSTs an open span ───────────────────────────────

  def test_integration_start_mints_token_and_opens_span
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                           "task_slug" => "narrated-trajectory-events", "mascot" => "caterpie", "stage" => "building")
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason find-issue-with-api],
                         proj: proj)

      auth = requests.find { |r| r[:path] == "/api/v1/auth" }
      refute_nil auth, "expected a token mint"

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      refute_nil open, "expected a POST /api/v1/atomic_events"
      assert_equal "Bearer stub-token", open[:headers]["authorization"]

      body = JSON.parse(open[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "Explore", body["category"]
      assert_equal "find-issue-with-api", body["reason"]
      assert_equal "narrated-trajectory-events", body["task_slug"]
      assert_equal "caterpie", body["mascot"]
      assert_equal "building", body["stage"]
    end
  end

  def test_integration_end_posts_close_with_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[end --session #{SESSION} --outcome located-the-bug], proj: proj)

      close = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events/close" }
      refute_nil close, "expected a POST /api/v1/atomic_events/close"
      body = JSON.parse(close[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "located-the-bug", body["outcome"]
    end
  end

  # ── [integration] --agent stamps the acting soul on the span ─────────────

  def test_integration_start_stamps_agent_on_the_open_span
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[start --session #{SESSION} --category Edit --reason add-guard --agent avi], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      refute_nil open, "expected a POST /api/v1/atomic_events"
      body = JSON.parse(open[:body])
      assert_equal "avi", body["agent"], "--agent rides the open-span POST"
      assert_equal "shellder", body["mascot"], "the base session mascot rides alongside, unchanged"
    end
  end

  def test_integration_next_carries_agent_across_the_boundary
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[next --session #{SESSION} --outcome done --category Edit --reason go --agent carl],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      assert_equal "carl", JSON.parse(open[:body])["agent"]
    end
  end

  def test_integration_start_without_agent_omits_the_key
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason look], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      refute JSON.parse(open[:body]).key?("agent"), "a bare start sends no agent key"
    end
  end

  # ── [integration] base mascot stays the session's own across a task bind ──

  def test_integration_base_mascot_stays_the_session_mascot_across_a_task_bind
    Dir.mktmpdir do |proj|
      # The session's OWN Pokémon (its stable base mascot)…
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      # …and a bound task's DESK marker carrying the TASK's builder mascot — this
      # used to FLIP the base (the observed Shellder→Sandshrew switch). It must not.
      write_context_marker(proj, "task_record_slug" => "someone-elses-task",
                                 "mascot" => "sandshrew", "stage" => "reviewed")

      requests = run_cli(%W[start --session #{SESSION} --category Verify --reason review], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      body = JSON.parse(open[:body])
      assert_equal "shellder", body["mascot"],
                   "base mascot stays the session's own, not the bound task's builder mascot"
      assert_equal "someone-elses-task", body["task_slug"],
                   "the desk task_slug is still recorded (builder mascot stays reachable via it)"
      assert_equal "reviewed", body["stage"], "stage still describes the desk"
    end
  end

  # ── [integration] BOUNDARY transition: next / start --outcome ────────────

  def test_integration_next_opens_with_prior_outcome_in_one_call
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[next --session #{SESSION} --outcome found-the-bug --category Edit --reason add-the-guard],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      refute_nil open, "next opens the new span (carrying the prior outcome)"
      body = JSON.parse(open[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "Edit", body["category"]
      assert_equal "add-the-guard", body["reason"]
      assert_equal "found-the-bug", body["prior_outcome"], "the prior span's outcome rides the SAME call"
    end
  end

  def test_integration_start_with_outcome_carries_prior_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --outcome wrapped-explore --category Edit --reason change-it],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      body = JSON.parse(open[:body])
      assert_equal "wrapped-explore", body["prior_outcome"]
    end
  end

  def test_integration_start_without_outcome_omits_prior_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason look], proj: proj)
      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events" }
      refute JSON.parse(open[:body]).key?("prior_outcome"), "a bare start sends no prior_outcome key"
    end
  end

  # ── [integration] session-end teardown: close-open ───────────────────────

  def test_integration_close_open_reads_session_from_stdin_and_posts_close_all
    Dir.mktmpdir do |proj|
      # The SessionEnd hook pipes its event JSON on stdin; no --session, no env id.
      requests = run_cli(%w[close-open], proj: proj, with_session_env: false,
                         stdin: JSON.generate("session_id" => SESSION, "reason" => "logout"))

      close_all = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events/close_all" }
      refute_nil close_all, "close-open posts to /api/v1/atomic_events/close_all"
      body = JSON.parse(close_all[:body])
      assert_equal SESSION, body["session_id"], "the session id comes from the stdin payload"
      assert_equal "session ended", body["outcome"], "defaults to a generic teardown outcome"
    end
  end

  def test_integration_close_open_respects_explicit_outcome_and_session_flag
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[close-open --session #{SESSION} --outcome wrapped-it-up], proj: proj)

      close_all = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_events/close_all" }
      body = JSON.parse(close_all[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "wrapped-it-up", body["outcome"]
    end
  end

  def test_integration_close_open_with_no_session_anywhere_hits_no_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%w[close-open], proj: proj, with_session_env: false, stdin: "")
      assert_empty requests, "no session id (flag / env / stdin) → nothing to close → no network"
    end
  end

  def test_integration_unknown_category_never_hits_the_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --category Vibe --reason nope], proj: proj)
      assert_empty requests, "a locally-invalid category must POST nothing"
    end
  end

  def test_integration_no_session_id_never_hits_the_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%w[start --category Explore --reason x], proj: proj, with_session_env: false)
      assert_empty requests, "no session id → nothing to narrate → no network"
    end
  end

  def test_integration_always_exits_zero_even_when_endpoint_is_down
    Dir.mktmpdir do |proj|
      _out, _err, status = Open3.capture3(
        base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1"),
        RbConfig.ruby, BIN, "start", "--session", SESSION, "--category", "Explore", "--reason", "x",
        chdir: proj
      )
      assert_equal 0, status.exitstatus, "the CLI must always exit 0"
    end
  end

  private

  def write_session_marker(projects_dir, session_id, attrs)
    sessions = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    File.write(File.join(sessions, "#{session_id}.json"), JSON.generate(attrs))
  end

  # The worktree DESK marker (.agent-context.json) — carries the BOUND task's
  # context (task slug + its builder mascot). resolve_marker walks up from cwd to
  # find it, so tests write it at the proj dir they chdir into.
  def write_context_marker(dir, attrs)
    File.write(File.join(dir, ".agent-context.json"), JSON.generate(attrs))
  end

  def base_env(projects_dir)
    {
      "AGENT_API_SECRET" => "test-secret",
      "CLAUDE_PROJECTS_DIR" => projects_dir,
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil
    }
  end

  # Shell out to the real CLI against a one-shot stub server; returns the recorded
  # requests. chdir into the isolated proj dir so no stray .agent-context.json up
  # the real tree leaks into the marker resolution.
  def run_cli(argv, proj:, with_session_env: true, stdin: nil)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    env = base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}")
    env["CLAUDE_CODE_SESSION_ID"] = SESSION if with_session_env && !argv.include?("--session")
    opts = { chdir: proj }
    opts[:stdin_data] = stdin unless stdin.nil?
    Open3.capture3(env, RbConfig.ruby, BIN, *argv, **opts)
    requests
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
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, headers: headers, body: body }

      status, payload = response_for(method, path)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path)
    return ["200 OK", JSON.generate("token" => "stub-token", "expires_at" => (Time.now + 86_400).utc.iso8601)] if path == "/api/v1/auth"
    return ["201 Created", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/atomic_events"
    return ["200 OK", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/atomic_events/close"
    return ["200 OK", JSON.generate("data" => { "closed" => 1 })] if method == "POST" && path == "/api/v1/atomic_events/close_all"

    ["404 Not Found", JSON.generate("error" => "unexpected #{method} #{path}")]
  end
end
