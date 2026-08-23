# frozen_string_literal: true

require_relative "cert_orphan_guard"

# CertProcess — run a cert lane so that it CANNOT outlive the cert.
#
# The lanes used to run through a bare `system(env, cmd, chdir: root)`. That puts
# the suite in the cert's OWN process group and installs no handler, so a signal
# aimed at the cert never reaches the suite: the harness's 120s Bash timeout killed
# `ruby bin/fast-check` and left `ruby bin/rails test` running with PPID 1, holding
# an open PG connection to the worktree test DB. Retries then died on
# PG::ObjectInUse — blamed on "an ENV gap" — for as long as the orphan lived.
#
# So a lane now runs in its OWN process group (`pgroup: true`), and the cert reaps
# that GROUP — not just the leader — on every death it can catch:
#
#   SIGTERM / SIGINT / SIGHUP  → trap: reap the group, clear the lock, exit
#   an exception / early abort → ensure: same
#   SIGKILL                    → no handler can run. THIS is why the runlock exists:
#                                the group we could not reap is named in the lock,
#                                and the NEXT cert reaps it (CertOrphanGuard).
#
# The GROUP is the unit that matters: the suite forks (a `sh -c` wrapper, Rails'
# own children), and killing only the leader strands the rest on the DB.
#
# A lane also cannot run FOREVER. `run` used to block in `waitpid2` with no ceiling, so
# a runner that deadlocked took the cert down with it: measured 2026-08-21, a turf-monster
# mapped-tests lane sat 41 minutes at 0.0% CPU and the cert then reported "lane(s) RED:
# mapped-tests" — a verdict about tests, when no test had run. Every agent that hit it
# burned its whole harness budget and retried into the same wall. So a lane may be given a
# `timeout:`; past it the wait gives up, reads the process table BEFORE the reap, and
# returns `:timeout` with a signature naming what the runner was doing. FAIL LOUD AND
# ACCURATE BEATS FAIL SLOW AND WRONG — and a ceiling is worth having even when today's
# deadlock is environmental, because the next one will not announce itself either.
module CertProcess
  SIGNALS = %w[TERM INT HUP].freeze

  # How often a bounded wait re-checks a running lane. Invisible against a lane measured
  # in minutes, and it keeps the ceiling's resolution well under a second.
  POLL_INTERVAL = 0.25

  # What the lane DID, as distinct from what it returned:
  #   :completed — the runner produced a verdict; `ok` carries it
  #   :timeout   — the runner produced NO verdict inside its ceiling; `detail` says what
  #                the process table showed at the moment we gave up
  #
  # `ok` is FALSE for :timeout, which is the load-bearing property: `run` still returns a
  # plain boolean, so a caller that never learns about outcomes still fails CLOSED. The one
  # thing a hung runner must never do is certify. (This is why `run_bounded` returns a
  # Struct and `run` returns `.ok` — a truthy `:timeout` symbol handed back from `run`
  # would have read as PASS at every existing call site.)
  Result = Struct.new(:ok, :outcome, :detail, keyword_init: true) do
    def timeout?
      outcome == :timeout
    end
  end

  # Run `cmd` in its own process group; return true when it exits 0.
  #
  # This is the boolean face of `run_bounded` and the API every existing caller uses. A
  # timed-out lane returns false here, with the diagnosis discarded — pass `timeout:` and
  # call `run_bounded` when you want to TELL a hang apart from a red suite.
  #
  # root/lane/db: when a root is given the runlock is written for the lifetime of
  # the lane, so a SIGKILLed cert leaves behind a record of the group it stranded.
  #
  # We record the OS's start time for BOTH pids the lock names — this cert, and the
  # group leader we just spawned. A pgid is a recyclable integer, so a later cert
  # reading this lock cannot tell "our stranded suite" from "a stranger who inherited
  # the number" unless we leave it something that identifies the process rather than
  # merely addresses it. The start time is that identity, and CertOrphanGuard refuses
  # to kill anything it cannot match against it.
  # `ps:` is the guard's own injection seam (CERT_GUARD_PS). It threads through every
  # process-table read this file makes — including the two `process_started_at` calls that
  # RECORD the identity. They used to hardcode the default `ps`, which meant the identity
  # half of the lock could not be driven from a fixture, which is precisely why `with_traps`
  # had NO test: you cannot test a reap you cannot make fail.
  def self.run(env, cmd, chdir:, root: nil, lane: nil, db: nil, ps: CertOrphanGuard.ps_bin, timeout: nil)
    run_bounded(env, cmd, chdir: chdir, root: root, lane: lane, db: db, ps: ps, timeout: timeout).ok
  end

  # The same run, reporting the OUTCOME as well as the verdict. `timeout` is in seconds;
  # nil (or non-positive) means no ceiling and an ordinary blocking wait, exactly as before.
  def self.run_bounded(env, cmd, chdir:, root: nil, lane: nil, db: nil, ps: CertOrphanGuard.ps_bin,
                       timeout: nil)
    pid = Process.spawn(env, cmd, chdir: chdir, pgroup: true)
    pgid = begin
      Process.getpgid(pid)
    rescue Errno::ESRCH
      pid # it already exited; its own pid is the best group id we have
    end
    started_at = CertOrphanGuard.process_started_at(pid, ps: ps)

    if root
      CertOrphanGuard.write_lock(root, cert_pid: Process.pid, pgid: pgid,
                                 cert_started_at: CertOrphanGuard.process_started_at(Process.pid, ps: ps),
                                 pgid_started_at: started_at, lane: lane, db: db)
    end

    with_traps(pgid, started_at, root, ps: ps) do
      wait_bounded(pid, pgid, timeout: timeout, ps: ps)
    end
  ensure
    # Any abnormal exit (exception, `abort`, a trap that re-raises): never leave the
    # group behind. `settle` re-proves ownership before it signals, so this is a no-op
    # when the lane already exited and refuses outright if the number has been handed to
    # somebody else in the meantime.
    settle(pgid, started_at, root, ps: ps) if pgid
    # And CLAIM THE CORPSE. On the normal path `waitpid2` already reaped the lane; on the
    # TIMEOUT path nothing has, so the killed child lingers as a ZOMBIE of this cert for as
    # long as the cert lives. A zombie holds no DB connection, but it still answers
    # `kill(0)` — so every "is the lane gone?" probe, ours and the operator's alike, reads
    # a corpse as a live orphan. Reap it here and the question has an honest answer.
    reap_child(pid) if pid
  end

  def self.reap_child(pid)
    Process.waitpid(pid, Process::WNOHANG)
  rescue Errno::ECHILD, Errno::ESRCH
    nil # already reaped by the normal path, or never ours
  end

  # Wait for the lane, with or without a ceiling.
  #
  # No ceiling → the original blocking `waitpid2`, byte for byte. With one → poll with
  # WNOHANG until the deadline. Polling (rather than a timer thread) keeps the whole wait
  # on the main thread, where `with_traps`' handlers already live: a signal arriving mid-
  # wait must reap the group and `exit!`, and that is far easier to reason about when
  # there is no second thread holding a half-finished waitpid.
  def self.wait_bounded(pid, pgid, timeout: nil, ps: "ps")
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

    # READ THE TABLE BEFORE THE REAP. `run_bounded`'s ensure kills this group on the way
    # out; after that there is nothing left to diagnose, and the verdict would be reduced
    # to "it took too long" — which is the uninformative half of the bug we are fixing.
    Result.new(ok: false, outcome: :timeout,
               detail: hang_signature(pgid, timeout: timeout, ps: ps))
  end

  # What the process table says a hung lane was DOING — the sentence that tells a DEADLOCK
  # apart from slow work, written for whoever reads the cert's last screen.
  #
  # The strongest signature we can read is the one measured on 2026-08-21: the runner alive
  # and every one of its children a ZOMBIE. Rails' `parallelize` forks workers and hands
  # them work over a DRb channel; when the workers die AT the fork (locally, the pg
  # fork-safety SIGSEGV in `pg/connection.rb`, `connect_start`, before any test runs) the
  # parent waits for results that can never arrive. Fourteen corpses and a parked parent is
  # not a slow suite, and the cert should say so instead of guessing.
  def self.hang_signature(pgid, timeout:, ps: "ps")
    table = CertOrphanGuard.process_table(ps: ps)
    members = table.select { |p| p[:pgid] == pgid.to_i }
    zombies, live = members.partition { |p| CertOrphanGuard.zombie?(p) }
    leader = live.find { |p| p[:pid] == pgid.to_i } || live.first
    cpu = leader && cpu_seconds(leader[:pid], ps: ps)

    facts = ["process group #{pgid}: #{live.size} live, #{zombies.size} zombie"]
    facts << "runner burned #{format('%.1fs', cpu)} of CPU across #{format('%.0fs', timeout)} of wall clock" if cpu

    "#{facts.join('; ')}. #{diagnosis(zombies: zombies.size, live: live.size, cpu: cpu, timeout: timeout)}"
  end

  # The named signatures, most specific first. Anything we cannot recognise gets an honest
  # "we do not know" rather than a confident wrong answer — a diagnosis this file invents
  # is the same failure as the "lane(s) RED" it replaces.
  def self.diagnosis(zombies:, live:, cpu:, timeout:)
    if zombies.positive? && live <= 1
      "SIGNATURE: the forked test workers are DEAD (#{zombies} zombie(s)) and the runner is still " \
        "waiting on them over its DRb channel — results that can never arrive. Locally this is the pg " \
        "fork-safety SIGSEGV at the fork (pg/connection.rb, connect_start), before any test runs. " \
        "Re-run the lane with PARALLEL_WORKERS=1."
    elsif cpu && cpu < [timeout * 0.02, 5.0].max
      "SIGNATURE: the runner is PARKED, not working — near-zero CPU across the entire window. It is " \
        "blocked on something (a channel, a lock, a database connection), not grinding through tests."
    else
      "No known deadlock signature: the runner may simply be slower than this ceiling allows. Raise " \
        "the ceiling deliberately if so, and record what you measured."
    end
  end

  # CPU seconds consumed by one pid, or nil when we cannot read it honestly.
  #
  # `ps -o time=` renders as [[DD-]HH:]MM:SS[.ss]. The format is matched STRICTLY before it
  # is parsed: a fixture `ps` (the CERT_GUARD_PS seam) answers a shape it was not written
  # for with arbitrary text, and `"Jul 8 09".split(":").map(&:to_f)` yields a perfectly
  # confident 0.0. A diagnostic that fabricates its evidence is worse than no diagnostic.
  def self.cpu_seconds(pid, ps: "ps")
    out = IO.popen([ps, "-p", pid.to_s, "-o", "time="], err: File::NULL, &:read).to_s.strip
    return nil unless $?.success?

    parse_cpu_time(out)
  rescue Errno::ENOENT, SystemCallError
    nil
  end

  def self.parse_cpu_time(text)
    match = /\A(?:(\d+)-)?(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)\z/.match(text.to_s.strip)
    return nil unless match

    days, hours, minutes, seconds = match.captures
    (days.to_i * 86_400) + (hours.to_i * 3600) + (minutes.to_i * 60) + seconds.to_f
  end

  # The last screen an agent reads when a lane never returned, as an array of lines.
  #
  # It has exactly ONE job: TO NOT BE MISTAKEN FOR A TEST FAILURE. The bug this whole
  # ceiling exists for was not the deadlock — it was that the deadlock was REPORTED as
  # "lane(s) RED", which every agent reads as "your tests failed", so the next move is
  # always a re-run into the same wall. So: name the RUNNER, say plainly that no verdict
  # was produced, print the ceiling, and hand over the process table's signature.
  #
  # Shared by both certs rather than written twice: two copies of a message drift, and
  # the half that drifts is always the one nobody is currently reading.
  def self.timeout_report(hung, ceiling:, tool:, env_var:)
    lines = ["", "#{tool}: lane(s) TIMED OUT: #{hung.keys.join(', ')} — THE RUNNER HUNG.",
             "  This is NOT a test failure and NOT a verdict on your diff: the runner never produced a",
             "  result at all. It was given #{ceiling}s of wall clock and did not return."]
    hung.each { |label, result| lines << "  #{label}: #{result.detail}" if result.detail }
    lines << "  Nothing certified. Diagnose the RUNNER — re-running will not produce a different suite result."
    lines << "  Raise the ceiling with #{env_var}=<seconds>, but only once you have MEASURED that the lane"
    lines << "  is genuinely that slow; record the measurement where the default is set."
    lines << ""
  end

  # Reap the group, then decide — ON THE OUTCOME — whether the runlock may be cleared.
  #
  # THE LOCK IS THE ONLY RECORD NAMING A PROCESS WE COULD NOT KILL. This code used to
  # DISCARD the reap's return, clear the lock unconditionally, and announce "no orphan left
  # behind" — a reap it may never have performed. `reap_group` does not signal at all when
  # it cannot prove the group is ours (a recycled pgid, or a nil `started_at` because the
  # `ps` at spawn returned nothing). So the cert destroyed the only evidence naming the
  # orphan and declared it gone; the next cert's preflight then graded `:none`, and the
  # entire DETECT half never ran. A detectable orphan became an UNNAMEABLE one — strictly
  # worse than the orphan bug this file exists to fix.
  #
  # The lock now survives exactly when the group does. `reap_cleared?` is the tri-state
  # gate: `:reaped` and `:absent` mean the group is gone and we know it — clear the lock.
  # `:survived` and `:refused` mean something is still out there — KEEP it. (A naive
  # `if reaped` gate would strand a stale lock behind every CLEAN cert, because a clean
  # lane's group is already gone: that is `:absent`, not a refusal. The tri-state exists
  # to keep those two apart.)
  def self.settle(pgid, started_at, root, ps: "ps")
    outcome = CertOrphanGuard.reap_group(pgid, started_at: started_at, ps: ps)
    CertOrphanGuard.clear_lock(root) if root && CertOrphanGuard.reap_cleared?(outcome)
    outcome
  end

  # Install group-reaping handlers for the duration of the block, then restore the
  # previous ones. The handler does its own cleanup and exit!s: an `exit` inside a
  # trap would unwind through ensure blocks while signals are still in flight, and
  # we want the reap to be the last thing that happens, deterministically.
  def self.with_traps(pgid, started_at, root, ps: "ps")
    previous = SIGNALS.to_h do |sig|
      [sig, Signal.trap(sig) do
        outcome = settle(pgid, started_at, root, ps: ps)
        warn "cert: signal SIG#{sig} — #{reap_report(pgid, outcome, root)}"
        exit!(128 + Signal.list.fetch(sig, 15))
      end]
    end
    yield
  ensure
    previous&.each { |sig, handler| Signal.trap(sig, handler || "DEFAULT") }
  end

  # Report what ACTUALLY happened. A cert that announces a kill it did not perform is back
  # to asserting rather than evidencing — the exact disease this guard exists to cure, and
  # the loudest possible place to relapse into it is the line an operator reads while their
  # cert is dying under them.
  def self.reap_report(pgid, outcome, root)
    case outcome
    when :reaped
      "reaped the suite's process group #{pgid} (no orphan left behind)."
    when :absent
      "the suite's process group #{pgid} was already gone — nothing to reap."
    else
      lock = root ? CertOrphanGuard.lock_path(root) : nil
      "could NOT reap the suite's process group #{pgid} (#{outcome}). An orphan MAY still be " \
        "holding the test DB. The runlock is LEFT IN PLACE ON PURPOSE#{lock ? " (#{lock})" : ''} — " \
        "it NAMES the process, and the next cert will find it and say so. " \
        "Inspect: #{CertOrphanGuard.inspect_command(pgid)}"
    end
  end
end
