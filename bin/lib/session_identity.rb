# frozen_string_literal: true

require "digest"

# SessionIdentity — the ONE Claude-then-Codex session-id chain the bin/ stack
# repeats: Claude Code exposes CLAUDE_CODE_SESSION_ID, Codex exposes
# CODEX_THREAD_ID, and a plain shell / CI run exposes neither.
#
# The chain is shared; the MISSING-session fallback is not — callers keep their
# own ([nil, nil] in bin/task, ["", "claude"] in bin/reviewer-select,
# [nil, "claude"] in bin/release.rb), so `identity` returns [nil, nil] and each
# caller maps that to its posture. bin/atomic-capture-hook is NOT a consumer:
# its event-payload resolution checks CODEX first by design.
module SessionIdentity
  module_function

  # [session_id, provider] — ["<id>", "claude"] / ["<id>", "codex"], or
  # [nil, nil] when the environment names no session.
  def identity(env = ENV)
    claude = env["CLAUDE_CODE_SESSION_ID"].to_s.strip
    return [claude, "claude"] unless claude.empty?

    codex = env["CODEX_THREAD_ID"].to_s.strip
    return [codex, "codex"] unless codex.empty?

    [nil, nil]
  end

  # The bare session id, "" when the environment names none.
  def id(env = ENV)
    identity(env).first.to_s
  end

  # The per-PROCESS-INSTANCE nonce that, with the session id, identifies the LIVE
  # INSTANCE holding a lease — a build claim (bin/task) OR a devops shift
  # (bin/devops-shift). See lib/claim_lease.rb. It MUST be stable across the many
  # short-lived bin/ invocations within ONE terminal, yet DIFFER between terminal-A
  # and a `claude --resume` in terminal-B (both share CLAUDE_CODE_SESSION_ID). So it
  # can't be per-invocation — it's anchored to the long-lived AGENT process (the
  # `claude`/`codex` CLI), the common ancestor of every bin/ call in a terminal and a
  # distinct OS process per terminal. Resolution, most-robust first:
  #   1. TASK_CLAIM_NONCE — explicit injection (tests; a future agent-exported token).
  #   2. The agent process found by walking the ancestry: a short hash of its
  #      PID + start time (PID alone is reused after exit; the start time makes it
  #      collision-resistant). Two `claude --resume` processes ⇒ different nonce.
  #   3. Degrade: the controlling TTY of the nearest ancestor that has one; then ""
  #      (a session-only lease that still catches a DIFFERENT session, just not two
  #      terminals of the same one). Memoized-friendly for the caller; never raises.
  AGENT_COMMANDS = %w[claude codex].freeze

  def nonce(env = ENV)
    override = env["TASK_CLAIM_NONCE"].to_s.strip
    return override unless override.empty?

    # Delegates to the (now spare-refusing) agent_process, so the lease IDENTITY answers to
    # the same owning-session fact as its LIFETIME — a warm bg-spare anchors neither.
    agent = agent_process
    return short_hash("pid:#{agent[:pid]}|start:#{agent[:start]}") if agent

    tty = process_ancestry.map { |p| p[:tty] }.find { |t| !t.to_s.empty? && t != "?" && t != "??" }
    return short_hash("tty:#{tty}") if tty

    "" # could not determine — degrade to a session-only lease
  rescue StandardError
    ""
  end

  # The long-lived AGENT process this bin/ invocation descends from — the `claude` or
  # `codex` CLI — as `{ pid:, start: }`, or nil when none is in our ancestry (a plain
  # shell, CI). It is the anchor for TWO things that must not drift apart: the lease
  # IDENTITY above (its pid+start hash IS the nonce) and the lease LIFETIME
  # (bin/lib/shift_renewer.rb renews only while this process lives). One fact, one
  # source. The start time is carried alongside the pid because a bare pid is reused
  # after exit, and "the pid is alive" would then be a false positive for a holder
  # that died an hour ago.
  #
  # A BACKGROUND claude IS NEVER THE ANCHOR. claude runs long-lived processes that OUTLIVE the
  # session that used them: the pooled helpers "claude bg-spare" / "claude bg-pty-host", AND the
  # "claude daemon run" that roots the pool (reparented to init, up to 12h old). Anchoring a
  # lease to any of them renews it FOREVER after the real run ended (2026-07-21: a phantom pinned
  # the avi/steffon lane — held by a lane whose heartbeat was seconds-fresh with no review in
  # flight, unclearable). They all share the `claude` command; the distinguisher is a subcommand
  # token in the FULL argv — `bg-spare`/`bg-pty-host` (the helpers rewrite their title) and
  # `daemon` (the daemon keeps its exec-path title, so only the argv shows `daemon run`).
  # owning_agent? refuses them, so agent_process finds the real session BEHIND them or returns
  # nil: no renewer, and the lease lapses on the ordinary TTL (the recoverable direction, never a
  # phantom). `ancestry` is injectable so the selection is tested as data, not by walking a live tree.
  BACKGROUND_ROLE_MARKER = /\bbg-(?:spare|pty-host)\b|\bdaemon\b/

  def agent_process(ancestry: process_ancestry)
    ancestry.find { |p| owning_agent?(p[:command]) }
            &.then { |p| { pid: p[:pid], start: proc_start(p[:pid]) } }
  rescue StandardError
    nil
  end

  # Is this ancestry entry an OWNING agent — a `claude`/`codex` CLI that is NOT a background
  # helper or daemon? The role token rides in the full argv after the command name, so a bare
  # `claude` (or `claude --flags`, or a full path to it) is the owner while a `claude bg-spare`,
  # `claude bg-pty-host`, or `…/claude daemon run …` is refused. `command` is the full command line.
  def owning_agent?(command)
    text = command.to_s
    return false if text.match?(BACKGROUND_ROLE_MARKER)

    AGENT_COMMANDS.include?(File.basename(text.split(/\s+/).first.to_s))
  end

  # Is the process at +pid+ still the SAME process that was running at +start+?
  #
  # Fails toward "no" on every uncertainty — a blank/garbled start signature, a pid we
  # cannot read, ps unavailable. The only consumer is the shift renewer, and there the
  # safe direction is to STOP renewing: a lease that lapses early is recoverable
  # (the lane frees, the next acquire takes it), while a renewer that keeps a lane
  # alive on an unverifiable anchor is a phantom holder nobody can clear.
  def process_alive?(pid, start)
    return false if pid.to_i <= 0

    signature = start.to_s.strip
    return false if signature.empty?

    proc_start(pid) == signature
  rescue StandardError
    false
  end

  # Walk the process tree from us up to init: [{pid:, ppid:, tty:, comm:}, ...].
  # One `ps` per level (≈5 deep) — cheap, and this isn't a hot path.
  def process_ancestry(max_depth: 12)
    chain = []
    pid = Process.pid
    max_depth.times do
      # `command=` (the FULL argv), not `comm=`: the claude DAEMON keeps its exec-path title
      # ("…/claude") while the bg-spare/bg-pty-host helpers rewrite theirs, so ONLY the full
      # command line exposes the `daemon run` subcommand that marks the pool's long-lived root
      # as non-owning. owning_agent? reads this field; the first token still yields the command.
      out = IO.popen(["ps", "-o", "ppid=,tty=,command=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
      break if out.empty?

      ppid, tty, command = out.split(/\s+/, 3)
      chain << { pid: pid.to_i, ppid: ppid.to_i, tty: tty.to_s, command: command.to_s }
      pid = ppid.to_i
      break if pid <= 1
    end
    chain
  rescue StandardError
    []
  end

  # The wall-clock start time of a pid (`ps -o lstart=`) — the disambiguator that
  # survives PID reuse after the process exits.
  def proc_start(pid)
    IO.popen(["ps", "-o", "lstart=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
  rescue StandardError
    ""
  end

  def short_hash(text)
    Digest::SHA256.hexdigest(text)[0, 12]
  end
end
