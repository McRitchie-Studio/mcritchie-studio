# frozen_string_literal: true

# Tests for bin/atomic-capture-hook — the Claude Code PostToolUse hook that
# streams each tool call into the atomic-capture endpoint.
#
#   ruby -Itest test/lib/atomic_capture_hook_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the pure builders — tool_name→kind mapping, truncation, outcome
#                 detection, marker derivation, and full payload shape — loaded in
#                 process (the bin's main is guarded so `load` is side-effect free).
#   [integration] the real script, shelled out against a localhost stub HTTP
#                 server, mints a token then POSTs the right shape to
#                 /api/v1/atomic_actions.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"

# Load the bin script in-process for the unit tier. The script's main is guarded
# by `$PROGRAM_NAME == __FILE__`, so loading it only defines AtomicCaptureHook.
load File.expand_path("../../bin/atomic-capture-hook", __dir__)

class AtomicCaptureHookTest < Minitest::Test
  BIN = File.expand_path("../../bin/atomic-capture-hook", __dir__)
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617"

  # An env-isolated hook instance (never touches the ambient session/secret env).
  def hook(env = {})
    AtomicCaptureHook.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env))
  end

  # ── [unit] tool_name → kind mapping ──────────────────────────────────────

  def test_unit_kind_mapping_covers_the_contract
    h = hook
    {
      "Read" => "read", "Glob" => "read", "Grep" => "read",
      "Edit" => "edit", "Write" => "edit", "NotebookEdit" => "edit",
      "Bash" => "bash",
      "Task" => "delegate", "Agent" => "delegate",
      "WebFetch" => "research", "WebSearch" => "research"
    }.each do |tool, kind|
      assert_equal kind, h.map_kind(tool), "#{tool} should map to #{kind}"
    end
  end

  def test_unit_unknown_tool_falls_back_to_downcased_name
    assert_equal "mcp__foo__bar", hook.map_kind("mcp__foo__bar".upcase.downcase)
    assert_equal "somenewtool", hook.map_kind("SomeNewTool")
  end

  # ── [unit] navigation drop ───────────────────────────────────────────────
  # Navigation (a bare directory move) owns no narrated span and is ~84% of the
  # noise, so it is DROPPED — never POSTed. A Bash call is navigation when its
  # command's first token is cd / pushd / popd / pwd.

  def test_unit_navigation_flags_directory_moves
    h = hook
    ["cd /Users/x", "cd ..", "  cd foo", "pushd bar", "popd", "pwd"].each do |command|
      event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
      assert h.navigation?(event), "#{command.inspect} should be navigation"
    end
  end

  def test_unit_navigation_ignores_non_nav_bash_and_other_tools
    h = hook
    ["ls -la", "git status", "cargo build", "cdless", "pwdx", "echo cd"].each do |command|
      event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
      refute h.navigation?(event), "#{command.inspect} is NOT navigation"
    end
    # Non-Bash tools are never navigation, whatever they carry.
    refute h.navigation?({ "tool_name" => "Read", "tool_input" => { "command" => "cd /x" } })
    refute h.navigation?({ "tool_name" => "Bash", "tool_input" => {} })
    refute h.navigation?({ "tool_name" => "Bash" })
  end

  # ── [unit] narration drop ────────────────────────────────────────────────
  # A Bash call whose invocation IS `bin/atomic-event` (the self-narration CLI) is
  # DROPPED like navigation — it's the span machinery, not work, and would otherwise
  # fall into "Unlabeled". Precise: only an INVOCATION, never a mention.

  def test_unit_narration_flags_atomic_event_invocations
    h = hook
    [
      "bin/atomic-event start --category Explore --reason x",
      "/Users/alex/projects/mcritchie-studio/bin/atomic-event next --outcome y --category Edit --reason z",
      "./bin/atomic-event end",
      "  bin/atomic-event close-open",
      "FOO=bar bin/atomic-event start --category Edit --reason z",           # inline ENV= prefix
      "ATOMIC_CAPTURE_URL=http://x /abs/bin/atomic-event end"                # ENV= + abs path
    ].each do |command|
      event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
      assert h.narration?(event), "#{command.inspect} should be narration (dropped)"
    end
  end

  def test_unit_narration_ignores_mentions_and_lookalikes_and_real_work
    h = hook
    [
      "grep atomic-event bin/",          # searching for it, not running it
      "cat bin/atomic-event",            # reading the file
      "echo bin/atomic-event",           # printing the string
      "bin/atomic-events-report",        # a different script (suffix)
      "bin/atomic-event-foo",            # not the bin (trailing chars)
      "ls -la",
      "git status",
      "bin/rails test"
    ].each do |command|
      event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
      refute h.narration?(event), "#{command.inspect} is NOT narration — must be kept"
    end
    # Non-Bash tools are never narration, whatever they carry (a real edit of the file).
    refute h.narration?({ "tool_name" => "Edit", "tool_input" => { "command" => "bin/atomic-event start" } })
    refute h.narration?({ "tool_name" => "Bash", "tool_input" => {} })
    refute h.narration?({ "tool_name" => "Bash" })
  end

  # ── [unit] serialization + truncation ────────────────────────────────────

  def test_unit_serialize_json_encodes_non_strings
    h = hook
    assert_equal "{\"a\":1}", h.serialize({ "a" => 1 })
    assert_equal "already a string", h.serialize("already a string")
    assert_equal "", h.serialize(nil)
  end

  def test_unit_truncate_caps_bytes_and_marks_dropped
    h = hook
    out = h.truncate("x" * 5000)
    assert_operator out.bytesize, :<=, AtomicCaptureHook::MAX_FIELD_BYTES + 64
    assert_includes out, "truncated 5000 bytes"
  end

  def test_unit_truncate_leaves_short_values_untouched
    assert_equal "small", hook.truncate("small")
  end

  # ── [unit] outcome detection ─────────────────────────────────────────────

  def test_unit_outcome_defaults_to_ok
    h = hook
    assert_equal "ok", h.outcome_for("plain output")
    assert_equal "ok", h.outcome_for({ "stdout" => "fine", "stderr" => "a warning", "interrupted" => false })
    assert_equal "ok", h.outcome_for({ "error" => nil })
  end

  def test_unit_outcome_flags_explicit_failures
    h = hook
    assert_equal "error", h.outcome_for({ "error" => "boom" })
    assert_equal "error", h.outcome_for({ "is_error" => true })
    assert_equal "error", h.outcome_for({ "success" => false })
    assert_equal "error", h.outcome_for({ "interrupted" => true })
  end

  # ── [unit] marker derivation ─────────────────────────────────────────────

  def test_unit_marker_from_session_file
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                            "task_slug" => "foo-task", "stage" => "building", "mascot" => "pidgeotto")
      marker = hook("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(cwd: nil, session_id: SESSION)
      assert_equal "foo-task", marker["task_slug"]
      assert_equal "building",  marker["stage"]
      assert_equal "pidgeotto", marker["mascot"]
    end
  end

  def test_unit_desk_wins_task_and_stage_but_base_mascot_is_the_session
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "session-task", "mascot" => "ekans")
      desk = File.join(proj, "wt")
      nested = File.join(desk, "deep", "nested")
      FileUtils.mkdir_p(nested)
      File.write(File.join(desk, ".agent-context.json"), JSON.generate(
        "task_record_slug" => "ctx-task", "task_slug" => "ignored",
        "stage" => nil, "mascot" => "caterpie"
      ))
      marker = hook("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(cwd: nested, session_id: SESSION)
      assert_equal "ctx-task", marker["task_slug"], "the worktree desk slug should win and walk up"
      assert_nil marker["stage"], "a blank desk stage stays nil (no false claim)"
      # The BASE mascot is the session's OWN Pokémon — NOT the desk's .agent-context.json
      # mascot (the bound task's builder mascot), which would FLIP the base when a
      # session works a task built by a different soul (Shellder→Sandshrew).
      assert_equal "ekans", marker["mascot"], "the base mascot stays the session's own, not the desk/task mascot"
    end
  end

  def test_unit_base_mascot_falls_back_to_desk_when_the_session_has_none
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "session-task") # no session mascot yet
      desk = File.join(proj, "wt")
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".agent-context.json"),
                 JSON.generate("task_record_slug" => "ctx-task", "mascot" => "caterpie"))
      marker = hook("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(cwd: desk, session_id: SESSION)
      assert_equal "caterpie", marker["mascot"], "with no session mascot, fall back to the desk (never regress to nil)"
    end
  end

  def test_unit_missing_marker_yields_nils
    marker = hook.resolve_marker(cwd: "/nope", session_id: "")
    assert_nil marker["task_slug"]
    assert_nil marker["stage"]
    assert_nil marker["mascot"]
  end

  # ── [unit] model derivation ──────────────────────────────────────────────
  # Claude Code does NOT ship the model in the PostToolUse stdin payload or any
  # env var; it IS in the transcript (assistant lines carry message.model) that the
  # payload's transcript_path points at. So the hook derives it from there — a real
  # model only, never fabricated.

  def test_unit_model_nil_when_no_source_available
    assert_nil hook.resolve_model({}), "no model field and no transcript ⇒ nil"
    assert_nil hook.resolve_model("transcript_path" => "/nonexistent-#{rand(10_000)}.jsonl")
  end

  def test_unit_model_prefers_a_direct_payload_field
    assert_equal "claude-direct", hook.resolve_model("model" => "claude-direct")
    assert_equal "claude-nested", hook.resolve_model("message" => { "model" => "claude-nested" })
  end

  def test_unit_model_reads_the_newest_assistant_line_from_the_transcript
    Dir.mktmpdir do |proj|
      path = File.join(proj, "transcript.jsonl")
      File.write(path, [
        JSON.generate("type" => "assistant", "message" => { "model" => "claude-old-4-1", "role" => "assistant" }),
        JSON.generate("type" => "user", "message" => { "role" => "user", "content" => "no model here" }),
        JSON.generate("type" => "assistant", "message" => { "model" => "claude-opus-4-8", "role" => "assistant" }),
        JSON.generate("type" => "user", "message" => { "role" => "user", "content" => "tool_result" })
      ].join("\n") + "\n")

      assert_equal "claude-opus-4-8", hook.read_model_from_transcript(path),
                   "the most recent assistant model wins"
      assert_equal "claude-opus-4-8", hook.resolve_model("transcript_path" => path)
    end
  end

  def test_unit_build_payload_stamps_the_transcript_model
    Dir.mktmpdir do |proj|
      path = File.join(proj, "transcript.jsonl")
      File.write(path, JSON.generate("type" => "assistant", "message" => { "model" => "claude-opus-4-8" }) + "\n")
      event = {
        "session_id" => SESSION, "cwd" => "/nope", "transcript_path" => path,
        "tool_name" => "Read", "tool_input" => {}, "tool_response" => {}
      }
      payload = hook("CLAUDE_PROJECTS_DIR" => proj).build_payload(event, now: Time.utc(2026, 6, 30, 12, 0, 0))
      assert_equal "claude-opus-4-8", payload["model"]
    end
  end

  # ── [unit] full payload shape ────────────────────────────────────────────

  def test_unit_build_payload_maps_the_whole_event
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                            "task_slug" => "tool-call-capture-hook", "stage" => "building", "mascot" => "caterpie")
      event = {
        "session_id" => SESSION, "cwd" => "/nope",
        "tool_name" => "Edit",
        "tool_input" => { "file_path" => "/x", "old_string" => "a", "new_string" => "b" },
        "tool_response" => { "ok" => true }
      }
      payload = hook("CLAUDE_PROJECTS_DIR" => proj).build_payload(event, now: Time.utc(2026, 6, 30, 12, 0, 0))
      assert_equal SESSION, payload["session_id"]
      assert_equal "edit", payload["kind"]
      assert_equal "tool-call-capture-hook", payload["task_slug"]
      assert_equal "building", payload["stage"]
      assert_equal "caterpie", payload["mascot"]
      assert_equal "agent", payload["actor"]
      assert_equal "ok", payload["outcome"]
      assert_equal "2026-06-30T12:00:00Z", payload["occurred_at"]
      assert_includes payload["input"], "file_path"
      assert_includes payload["output"], "ok"
      # No transcript on this event → zero usage and no source turn.
      assert_equal 0, payload["tokens_in"]
      assert_equal 0, payload["tokens_out"]
      assert_equal 0, payload["cache_read_tokens"]
      assert_nil payload["source_turn_uuid"]
      # A hook can't know these — they stay absent (capture fills defaults).
      refute payload.key?("seq")
      refute payload.key?("event_slug")
      refute payload.key?("cost"), "the hook never sends cost — capture DERIVES it server-side"
    end
  end

  # ── [unit] usage extraction (tokens + source turn) ───────────────────────
  # The PostToolUse payload carries no usage, but the transcript's assistant line
  # (the one with message.model) also carries message.usage and a uuid. The hook
  # reads model + usage + uuid from that ONE line and stamps tokens on the action.

  def test_unit_turn_usage_splits_fresh_from_cache_read
    h = hook
    usage = {
      "input_tokens" => 1200,
      "cache_creation_input_tokens" => 300,
      "cache_read_input_tokens" => 4500,
      "output_tokens" => 800
    }
    result = h.turn_usage(usage)
    assert_equal 1500, result[:tokens_in], "tokens_in = FRESH input + cache_creation (no cache_read)"
    assert_equal 800, result[:tokens_out]
    assert_equal 4500, result[:cache_read_tokens], "cache_read is carried apart for costing only"
  end

  def test_unit_turn_usage_is_zero_for_missing_or_non_hash
    h = hook
    zero = { tokens_in: 0, tokens_out: 0, cache_read_tokens: 0 }
    assert_equal(zero, h.turn_usage(nil))
    assert_equal(zero, h.turn_usage("nope"))
    assert_equal(zero, h.turn_usage({}))
  end

  def test_unit_reads_usage_and_uuid_from_the_newest_model_bearing_line
    Dir.mktmpdir do |proj|
      path = File.join(proj, "transcript.jsonl")
      File.write(path, [
        JSON.generate("type" => "assistant", "uuid" => "turn-old",
                      "message" => { "model" => "claude-opus-4-8", "usage" => { "input_tokens" => 1 } }),
        JSON.generate("type" => "assistant", "uuid" => "turn-new",
                      "message" => { "model" => "claude-opus-4-8[1m]",
                                     "usage" => { "input_tokens" => 2000, "cache_read_input_tokens" => 500, "output_tokens" => 900 } }),
        JSON.generate("type" => "user", "message" => { "role" => "user", "content" => "tool_result" })
      ].join("\n") + "\n")

      turn = hook.read_assistant_turn_from_transcript(path)
      assert_equal "claude-opus-4-8[1m]", turn["model"], "the newest model-bearing line wins"
      assert_equal "turn-new", turn["uuid"]
      usage = hook.turn_usage(turn["usage"])
      assert_equal 2000, usage[:tokens_in], "fresh input only — cache_read is excluded"
      assert_equal 900, usage[:tokens_out]
      assert_equal 500, usage[:cache_read_tokens]
    end
  end

  def test_unit_build_payload_stamps_tokens_and_source_turn_uuid
    Dir.mktmpdir do |proj|
      path = File.join(proj, "transcript.jsonl")
      # A long-session-shaped turn: small fresh input + cache_creation, a HUGE
      # cache_read (re-read context). Fresh tokens stay small; cache_read is carried
      # apart so cost can price it cheaply rather than at the full input rate.
      File.write(path, JSON.generate(
        "type" => "assistant", "uuid" => "turn-42",
        "message" => { "model" => "claude-opus-4-8",
                       "usage" => { "input_tokens" => 3000, "cache_creation_input_tokens" => 1000,
                                    "cache_read_input_tokens" => 304_000, "output_tokens" => 250 } }
      ) + "\n")
      event = {
        "session_id" => SESSION, "cwd" => "/nope", "transcript_path" => path,
        "tool_name" => "Read", "tool_input" => {}, "tool_response" => {}
      }
      payload = hook("CLAUDE_PROJECTS_DIR" => proj).build_payload(event, now: Time.utc(2026, 7, 1, 12, 0, 0))
      assert_equal "claude-opus-4-8", payload["model"]
      assert_equal 4000, payload["tokens_in"], "FRESH input + cache_creation only"
      assert_equal 250, payload["tokens_out"]
      assert_equal 304_000, payload["cache_read_tokens"], "cache_read is stamped apart, not lumped into tokens_in"
      assert_equal "turn-42", payload["source_turn_uuid"]
    end
  end

  # ── [integration] real script POSTs to the endpoint ──────────────────────

  def test_integration_hook_mints_token_and_posts_action
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                            "task_slug" => "tool-call-capture-hook", "stage" => "building", "mascot" => "caterpie")
      event = {
        "session_id" => SESSION, "cwd" => "/nope",
        "tool_name" => "Bash",
        "tool_input" => { "command" => "ls -la" },
        "tool_response" => { "stdout" => "total 0", "interrupted" => false }
      }
      requests = run_hook(event, env: { "CLAUDE_PROJECTS_DIR" => proj })

      auth = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/auth" }
      refute_nil auth, "expected a POST /api/v1/auth to mint a token"
      assert_equal "test-secret", JSON.parse(auth[:body])["secret"]

      post = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_actions" }
      refute_nil post, "expected a POST /api/v1/atomic_actions"
      assert_equal "Bearer stub-token", post[:headers]["authorization"]

      body = JSON.parse(post[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "bash", body["kind"]
      assert_equal "tool-call-capture-hook", body["task_slug"]
      assert_equal "building", body["stage"]
      assert_equal "caterpie", body["mascot"]
      assert_equal "agent", body["actor"]
      assert_equal "ok", body["outcome"]
      assert_includes body["input"], "ls -la"
      assert_includes body["output"], "total 0"
      refute_nil body["occurred_at"]
    end
  end

  def test_integration_secret_is_redacted_in_the_posted_body
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "redact-secrets-from-capture-hook")
      secret = "s3cr3t-VALUE-do-not-leak-9F2xQ"
      event = {
        "session_id" => SESSION, "cwd" => "/nope",
        "tool_name" => "Bash",
        "tool_input" => { "command" => "bin/secret agents 'Agent API Secret' AGENT_API_SECRET" },
        "tool_response" => { "stdout" => "AGENT_API_SECRET=#{secret}\n" }
      }
      requests = run_hook(event, env: { "CLAUDE_PROJECTS_DIR" => proj })

      post = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/atomic_actions" }
      refute_nil post, "expected a POST /api/v1/atomic_actions"
      refute_includes post[:body], secret,
                      "a secret must NOT reach the wire — redaction happens before the POST"
      assert_match(/redact/i, JSON.parse(post[:body])["output"].to_s, "the field is marked redacted")
    end
  end

  def test_integration_no_session_id_skips_the_post
    Dir.mktmpdir do |proj|
      event = { "cwd" => "/nope", "tool_name" => "Read", "tool_input" => {}, "tool_response" => {} }
      requests = run_hook(event, env: { "CLAUDE_PROJECTS_DIR" => proj })
      assert_empty requests, "a hook event without a session_id must POST nothing"
    end
  end

  def test_integration_navigation_is_dropped_no_post
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      event = {
        "session_id" => SESSION, "cwd" => "/nope",
        "tool_name" => "Bash",
        "tool_input" => { "command" => "cd /Users/alex/projects" },
        "tool_response" => { "stdout" => "" }
      }
      requests = run_hook(event, env: { "CLAUDE_PROJECTS_DIR" => proj })
      assert_empty requests, "a navigation Bash call must POST nothing — not even a token mint"
    end
  end

  def test_integration_atomic_event_narration_is_dropped_no_post
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      event = {
        "session_id" => SESSION, "cwd" => "/nope",
        "tool_name" => "Bash",
        "tool_input" => { "command" => "bin/atomic-event start --category Explore --reason orient" },
        "tool_response" => { "stdout" => "atomic-event: opened Explore · orient" }
      }
      requests = run_hook(event, env: { "CLAUDE_PROJECTS_DIR" => proj })
      assert_empty requests, "a bin/atomic-event narration call must POST nothing — not even a token mint"
    end
  end

  def test_integration_always_exits_zero_even_when_endpoint_is_down
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      event = { "session_id" => SESSION, "tool_name" => "Read", "tool_input" => {}, "tool_response" => {} }
      # Point at a closed port — delivery fails, but the hook must still exit 0.
      _out, _err, status = Open3.capture3(
        base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1"),
        RbConfig.ruby, BIN, stdin_data: JSON.generate(event)
      )
      assert_equal 0, status.exitstatus, "the hook must always exit 0"
    end
  end

  # ── [unit] secret redaction (audit 2026-07-02 high finding #6) ───────────
  # tool_input / tool_response are the sole source of AtomicAction.input/output,
  # which render on the PUBLIC /alex/heartbeat surface. The hook must never ship a
  # secret off the machine. Two layers: whole-field suppression for secret-reading
  # commands/files (a bare value has no key to match), and pattern redaction for
  # KEY=VALUE + known credential formats everywhere.
  SECRET = "s3cr3t-VALUE-do-not-leak-9F2xQ"

  def payload_for(tool_name:, tool_input:, tool_response:)
    hook.build_payload(
      { "session_id" => SESSION, "cwd" => "/nope",
        "tool_name" => tool_name, "tool_input" => tool_input, "tool_response" => tool_response },
      now: Time.utc(2026, 7, 3, 12, 0, 0)
    )
  end

  def test_unit_redact_suppresses_output_of_secret_reading_commands
    [
      "bin/secret agents 'Agent API Secret' AGENT_API_SECRET",
      "op read op://agents/Agent API Secret/AGENT_API_SECRET",
      "printenv AGENT_API_SECRET",
      "gh auth token",
      "heroku config:get SECRET_KEY_BASE -a mcritchie-studio",
      "cat .env",
      "cat /Users/alex/projects/mcritchie-studio/.env",
      "head -1 config/credentials.yml.enc"
    ].each do |command|
      payload = payload_for(tool_name: "Bash",
                            tool_input: { "command" => command },
                            tool_response: "AGENT_API_SECRET=#{SECRET}\n")
      refute_includes payload["output"].to_s, SECRET,
                      "output of a secret-reading command must be suppressed: #{command}"
      assert_match(/redact/i, payload["output"].to_s, "the suppressed field is marked: #{command}")
    end
  end

  def test_unit_redact_suppresses_reads_of_secret_files
    [
      { "file_path" => "/Users/alex/projects/mcritchie-studio/.env" },
      { "file_path" => "/Users/alex/.aws/credentials" },
      { "file_path" => "config/master.key" },
      { "file_path" => "/home/x/.ssh/id_rsa" },
      { "file_path" => "certs/server.pem" }
    ].each do |input|
      payload = payload_for(tool_name: "Read", tool_input: input,
                            tool_response: "AGENT_API_SECRET=#{SECRET}\nSTRIPE_KEY=#{SECRET}")
      refute_includes payload["output"].to_s, SECRET,
                      "reading #{input['file_path']} must not store its contents"
    end
  end

  def test_unit_redact_masks_key_value_secrets_anywhere
    command = "AGENT_API_SECRET=#{SECRET} STRIPE_SECRET_KEY=#{SECRET} bin/rails runner x"
    payload = payload_for(tool_name: "Bash", tool_input: { "command" => command },
                          tool_response: %(export DATABASE_PASSWORD="#{SECRET}"))
    refute_includes payload["input"].to_s, SECRET, "KEY=VALUE secrets in the command are redacted"
    refute_includes payload["output"].to_s, SECRET, "KEY=VALUE secrets in the output are redacted"
    # the KEY names survive — only the value is masked (still a legible trajectory)
    assert_includes payload["input"].to_s, "AGENT_API_SECRET"
  end

  def test_unit_redact_masks_known_credential_formats
    {
      "stripe" => "sk_live_#{"a" * 24}",
      "aws"    => "AKIA#{"B" * 16}",
      "github" => "ghp_#{"c" * 36}",
      "bearer" => "Authorization: Bearer #{"d" * 40}",
      "pem"    => "-----BEGIN RSA PRIVATE KEY-----\nMIIEabc123\n-----END RSA PRIVATE KEY-----"
    }.each do |label, blob|
      payload = payload_for(tool_name: "Bash", tool_input: { "command" => "echo hi" },
                            tool_response: "leaked #{blob} here")
      secret_core = blob[/(sk_live_\S+|AKIA\S+|ghp_\S+|d{40}|MIIEabc123)/] || blob
      refute_includes payload["output"].to_s, secret_core, "#{label} credential must be redacted"
    end
  end

  def test_unit_redact_leaves_ordinary_content_untouched
    # No false positives: env-ish non-secrets, normal file reads, plain output.
    command = "RAILS_ENV=test PORT=3007 bin/rails test"
    payload = payload_for(tool_name: "Bash", tool_input: { "command" => command },
                          tool_response: "5 runs, 0 failures\ndef insight_source\n  atomic_action\nend")
    assert_includes payload["input"].to_s, "RAILS_ENV=test", "a non-secret KEY=VALUE is preserved"
    assert_includes payload["input"].to_s, "PORT=3007"
    assert_includes payload["output"].to_s, "0 failures", "ordinary output passes through"
    assert_includes payload["output"].to_s, "insight_source"
  end

  def test_unit_redact_runs_before_truncate_so_no_secret_prefix_leaks
    # A secret near the 3KB cut must not survive as a truncated prefix.
    filler = "x" * 2990
    payload = payload_for(tool_name: "Read", tool_input: { "file_path" => "notes.txt" },
                          tool_response: "#{filler}AGENT_API_SECRET=#{SECRET}")
    refute_includes payload["output"].to_s, SECRET
  end

  private

  def write_session_marker(projects_dir, session_id, attrs)
    sessions = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    File.write(File.join(sessions, "#{session_id}.json"), JSON.generate(attrs))
  end

  def base_env(projects_dir)
    {
      "AGENT_API_SECRET" => "test-secret",
      "ATOMIC_CAPTURE_FOREGROUND" => "1", # run inline so the stub observes the POST
      "CLAUDE_PROJECTS_DIR" => projects_dir,
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil
    }
  end

  # Shell out to the real hook against a one-shot stub HTTP server; returns the
  # recorded requests.
  def run_hook(event, env: {})
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    full_env = base_env(env.fetch("CLAUDE_PROJECTS_DIR")).merge(env).merge(
      "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}"
    )
    Open3.capture3(full_env, RbConfig.ruby, BIN, stdin_data: JSON.generate(event))
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
    return ["201 Created", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/atomic_actions"

    ["404 Not Found", JSON.generate("error" => "unexpected #{method} #{path}")]
  end
end
