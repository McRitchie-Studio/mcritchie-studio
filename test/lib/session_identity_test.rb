# frozen_string_literal: true

# Tests for bin/lib/session_identity.rb — the Claude-then-Codex session-id
# chain shared by bin/task, bin/reviewer-select, bin/release.rb,
# bin/full-suite-check, bin/ci-scope-capture and bin/atomic-event. The chain is
# shared; the missing-session fallback stays per-caller, so identity returns
# [nil, nil] and callers map it.
#   ruby -Itest test/lib/session_identity_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

require File.expand_path("../../bin/lib/session_identity", __dir__)

class SessionIdentityTest < Minitest::Test
  def test_unit_claude_wins_over_codex
    env = { "CLAUDE_CODE_SESSION_ID" => "c-1", "CODEX_THREAD_ID" => "x-1" }
    assert_equal ["c-1", "claude"], SessionIdentity.identity(env)
  end

  def test_unit_codex_is_the_fallback
    assert_equal ["x-1", "codex"], SessionIdentity.identity("CODEX_THREAD_ID" => "x-1")
  end

  def test_unit_blank_values_are_skipped
    env = { "CLAUDE_CODE_SESSION_ID" => "   ", "CODEX_THREAD_ID" => "x-2" }
    assert_equal ["x-2", "codex"], SessionIdentity.identity(env)
  end

  def test_unit_ids_are_stripped
    assert_equal ["c-9", "claude"], SessionIdentity.identity("CLAUDE_CODE_SESSION_ID" => " c-9 ")
  end

  def test_unit_no_session_is_nil_nil
    assert_equal [nil, nil], SessionIdentity.identity({}),
                 "callers map [nil, nil] to their own fallback posture"
  end

  def test_unit_id_returns_the_bare_id_or_empty_string
    assert_equal "c-1", SessionIdentity.id("CLAUDE_CODE_SESSION_ID" => "c-1")
    assert_equal "", SessionIdentity.id({}), "the telemetry session gate keys off blank"
  end

  # The per-instance nonce (extracted from bin/task, now shared with bin/devops-shift).
  def test_unit_nonce_honors_the_explicit_override
    assert_equal "abc123", SessionIdentity.nonce("TASK_CLAIM_NONCE" => "abc123"),
                 "an injected nonce wins (tests + a future agent-exported token)"
  end

  def test_unit_nonce_resolves_deterministically_from_the_process_tree
    # No override → walks the ancestry; in-process it degrades to a stable, non-raising
    # value (an agent-hash, a tty-hash, or "" — never an exception).
    a = SessionIdentity.nonce({})
    b = SessionIdentity.nonce({})
    assert_kind_of String, a
    assert_equal a, b, "the same live instance resolves the SAME nonce across calls"
  end

  # --- the bg-spare anchor bug: a background claude is NEVER the lease anchor ----------
  # claude's pooled helpers (`claude bg-spare` / `claude bg-pty-host`) AND the `claude daemon
  # run` that roots the pool all OUTLIVE the session; anchoring a lease to any renews it forever
  # (a phantom that pins avi/steffon). The distinguisher is a subcommand token in the FULL argv,
  # which the pre-fix `comm.split.first` discarded (and `comm=` never showed for the daemon).

  def test_unit_owning_agent_accepts_a_real_cli_and_refuses_a_background_claude
    assert SessionIdentity.owning_agent?("claude"),                          "a bare claude is the owner"
    assert SessionIdentity.owning_agent?("claude --dangerously-skip-permissions")
    assert SessionIdentity.owning_agent?("codex")
    assert SessionIdentity.owning_agent?("/Users/x/.local/bin/claude"),      "a full path still resolves to claude"
    refute SessionIdentity.owning_agent?("claude bg-spare"),                 "a warm spare is NEVER the anchor"
    refute SessionIdentity.owning_agent?("claude bg-pty-host"),              "a pty-host helper is NEVER the anchor"
    # The daemon keeps its exec-path title, so only the full argv shows `daemon run` — it must
    # be refused too, or the pool's long-lived ROOT becomes the phantom anchor (carl, PR #639).
    refute SessionIdentity.owning_agent?("/Users/x/.local/bin/claude daemon run --origin transient"),
           "the pool-rooting claude daemon is NEVER the anchor"
    refute SessionIdentity.owning_agent?("ruby bin/task"),                   "a bin/ ruby is not an agent"
    refute SessionIdentity.owning_agent?("")
  end

  # The reproduction: a background-only ancestry must yield NO anchor. agent_process then returns
  # nil → the acquire starts no renewer → the lease lapses on TTL (recoverable), never a phantom.
  # Deleting the BACKGROUND_ROLE_MARKER refusal makes this anchor pid 4200 (the spare).
  def test_unit_agent_process_refuses_a_spare_only_ancestry
    spare_only = [
      { pid: 4242, ppid: 4200, tty: "??", command: "ruby bin/devops-shift" },
      { pid: 4200, ppid: 1,    tty: "??", command: "claude bg-spare --bg-spare /tmp/x.sock" },
    ]
    assert_nil SessionIdentity.agent_process(ancestry: spare_only),
               "a spare-only ancestry must yield no anchor, never the warm spare"
  end

  # carl's PR-#639 catch: a spare pool ROOTED AT THE DAEMON (bg-spare → bg-pty-host → claude
  # daemon run → init) must ALSO yield no anchor. The daemon's `comm=` is a bare exec path with
  # no role token, so a comm-based marker missed it and anchored the 12h-lived daemon — the same
  # phantom, one level up. The full-argv `daemon` token refuses it.
  def test_unit_agent_process_refuses_a_daemon_rooted_pool
    daemon_rooted = [
      { pid: 7100, ppid: 7099, tty: "??", command: "ruby bin/devops-shift" },
      { pid: 7099, ppid: 7098, tty: "??", command: "claude bg-spare --bg-spare /tmp/x.sock" },
      { pid: 7098, ppid: 7097, tty: "??", command: "claude bg-pty-host --bg-pty-host /tmp/x.pty.sock" },
      { pid: 7097, ppid: 1,    tty: "??", command: "/Users/x/.local/bin/claude daemon run --origin transient --spawned-by {}" },
    ]
    assert_nil SessionIdentity.agent_process(ancestry: daemon_rooted),
               "a daemon-rooted pool must yield no anchor — the long-lived daemon is not an owner"
  end

  # Integration: agent_process end-to-end over an injected ancestry (the shape process_ancestry
  # produces), through the real proc_start shell-out. An interactive session in the chain IS the
  # anchor even when a helper AND the daemon also appear; both are skipped, the owner selected.
  def test_integration_agent_process_picks_the_real_session_over_background_claudes
    ancestry = [
      { pid: 5001, ppid: 5000, tty: "ttys003", command: "ruby bin/devops-shift" },
      { pid: 5000, ppid: 4999, tty: "ttys003", command: "claude bg-spare --bg-spare /tmp/x.sock" }, # skipped
      { pid: Process.pid, ppid: 1, tty: "ttys003", command: "claude --dangerously-skip-permissions" }, # real, live
    ]
    agent = SessionIdentity.agent_process(ancestry: ancestry)
    refute_nil agent
    assert_equal Process.pid, agent[:pid], "the owning claude session anchors the lease, not a background claude"
    refute_empty agent[:start], "the anchor carries the live process start time (proc_start shell-out)"
  end
end
