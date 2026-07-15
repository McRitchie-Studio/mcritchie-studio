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
module CertProcess
  SIGNALS = %w[TERM INT HUP].freeze

  # Run `cmd` in its own process group; return true when it exits 0.
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
  def self.run(env, cmd, chdir:, root: nil, lane: nil, db: nil, ps: CertOrphanGuard.ps_bin)
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
      _, status = Process.waitpid2(pid)
      status.success?
    end
  ensure
    # Any abnormal exit (exception, `abort`, a trap that re-raises): never leave the
    # group behind. `settle` re-proves ownership before it signals, so this is a no-op
    # when the lane already exited and refuses outright if the number has been handed to
    # somebody else in the meantime.
    settle(pgid, started_at, root, ps: ps) if pgid
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
