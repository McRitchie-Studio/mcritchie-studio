# frozen_string_literal: true

# LaneRunner — run one pre-flight lane in its OWN process group, bounded by a
# ceiling, and never leave the suite behind.
#
# A bare `system` left `bin/rails test` running with PPID 1 when a harness
# timeout killed the caller — holding the desk's test DB and failing every retry
# with PG::ObjectInUse. So the lane is spawned as a process-group leader, a signal
# aimed at the caller reaps the whole group, and a lane that outruns its ceiling
# is killed and reported as a HUNG RUNNER rather than a red suite.
#
# Three outcomes, kept distinct because they want different actions:
#   :completed    — the lane ran; `ok` is its exit status
#   :timeout      — it never produced a verdict inside the ceiling; the group was killed
#   :unlaunchable — the command does not exist here; nothing ran
module LaneRunner
  POLL_INTERVAL = 0.25
  SIGNALS = %w[TERM INT HUP].freeze

  Result = Struct.new(:ok, :outcome, :detail, keyword_init: true) do
    def timeout? = outcome == :timeout
    def unlaunchable? = outcome == :unlaunchable
    def skipped? = outcome == :skipped
  end

  # `timeout` is in seconds; nil (or non-positive) means no ceiling.
  def self.run(env, cmd, chdir:, timeout: nil)
    pid = begin
      Process.spawn(env, cmd, chdir: chdir, pgroup: true)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
      return Result.new(ok: false, outcome: :unlaunchable, detail: "#{cmd}: #{e.message}")
    end
    pgid = begin
      Process.getpgid(pid)
    rescue Errno::ESRCH
      pid
    end

    with_traps(pgid) { wait_bounded(pid, pgid, timeout: timeout) }
  ensure
    signal_group(pgid, "KILL") if pgid
    reap_child(pid) if pid
  end

  def self.wait_bounded(pid, pgid, timeout: nil)
    unless timeout.is_a?(Numeric) && timeout.positive?
      _, status = Process.waitpid2(pid)
      return Result.new(ok: status.success?, outcome: :completed)
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      reaped = Process.waitpid2(pid, Process::WNOHANG)
      return Result.new(ok: reaped[1].success?, outcome: :completed) if reaped
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep POLL_INTERVAL
    end

    signal_group(pgid, "TERM")
    sleep 1
    signal_group(pgid, "KILL")
    Result.new(ok: false, outcome: :timeout, detail: "no verdict after #{timeout}s; process group #{pgid} killed")
  end

  # While the lane runs, a catchable signal aimed at us reaps the lane's whole
  # group first and then exits with the conventional 128+signal status. The prior
  # handlers are restored afterwards so a caller's own traps are not clobbered.
  def self.with_traps(pgid)
    previous = SIGNALS.to_h do |sig|
      [sig, trap(sig) do
        signal_group(pgid, "TERM")
        signal_group(pgid, "KILL")
        exit!(128 + Signal.list.fetch(sig))
      end]
    end
    yield
  ensure
    previous&.each { |sig, handler| trap(sig, handler || "DEFAULT") }
  end

  # Never group 0 (our own), never 1 (init — and every process we own), never the
  # group this very process runs in.
  def self.signal_group(pgid, signal)
    pgid = pgid.to_i
    return false if pgid < 2 || pgid == Process.getpgrp || pgid == Process.pid

    Process.kill(signal, -pgid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def self.reap_child(pid)
    Process.waitpid(pid, Process::WNOHANG)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  # The sentence a hung lane owes the reader: not "your tests failed", because no
  # test produced a verdict.
  def self.timeout_report(hung, ceiling:, tool:, env_var:)
    lines = hung.map do |label, result|
      "#{tool}: lane HUNG: #{label} — #{result.detail}. The RUNNER never produced a verdict, so this is " \
        "NOT a red suite: nothing here says your tests failed."
    end
    lines << "#{tool}: the per-lane ceiling is #{ceiling}s (#{env_var}). A lane that reaches it is stuck, not " \
             "slow — look for a wedged runner (forked workers dead at the fork, a DRb wait) before re-running."
    lines
  end
end
