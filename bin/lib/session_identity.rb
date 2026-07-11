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

    chain = process_ancestry
    agent = chain.find { |p| AGENT_COMMANDS.include?(File.basename(p[:comm].to_s.split(/\s+/).first.to_s)) }
    return short_hash("pid:#{agent[:pid]}|start:#{proc_start(agent[:pid])}") if agent

    tty = chain.map { |p| p[:tty] }.find { |t| !t.to_s.empty? && t != "?" && t != "??" }
    return short_hash("tty:#{tty}") if tty

    "" # could not determine — degrade to a session-only lease
  rescue StandardError
    ""
  end

  # Walk the process tree from us up to init: [{pid:, ppid:, tty:, comm:}, ...].
  # One `ps` per level (≈5 deep) — cheap, and this isn't a hot path.
  def process_ancestry(max_depth: 12)
    chain = []
    pid = Process.pid
    max_depth.times do
      out = IO.popen(["ps", "-o", "ppid=,tty=,comm=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
      break if out.empty?

      ppid, tty, comm = out.split(/\s+/, 3)
      chain << { pid: pid.to_i, ppid: ppid.to_i, tty: tty.to_s, comm: comm.to_s }
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
