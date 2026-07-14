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
  def self.run(env, cmd, chdir:, root: nil, lane: nil, db: nil)
    pid = Process.spawn(env, cmd, chdir: chdir, pgroup: true)
    pgid = begin
      Process.getpgid(pid)
    rescue Errno::ESRCH
      pid # it already exited; its own pid is the best group id we have
    end
    started_at = CertOrphanGuard.process_started_at(pid)

    if root
      CertOrphanGuard.write_lock(root, cert_pid: Process.pid, pgid: pgid,
                                 cert_started_at: CertOrphanGuard.process_started_at(Process.pid),
                                 pgid_started_at: started_at, lane: lane, db: db)
    end

    with_traps(pgid, started_at, root) do
      _, status = Process.waitpid2(pid)
      status.success?
    end
  ensure
    # Any abnormal exit (exception, `abort`, a trap that re-raises): never leave the
    # group behind. `reap_group` re-proves ownership before it signals, so this is a
    # no-op when the lane already exited (the group is gone) and refuses outright if
    # the number has been handed to somebody else in the meantime.
    CertOrphanGuard.reap_group(pgid, started_at: started_at) if pgid
    CertOrphanGuard.clear_lock(root) if root
  end

  # Install group-reaping handlers for the duration of the block, then restore the
  # previous ones. The handler does its own cleanup and exit!s: an `exit` inside a
  # trap would unwind through ensure blocks while signals are still in flight, and
  # we want the reap to be the last thing that happens, deterministically.
  def self.with_traps(pgid, started_at, root)
    previous = SIGNALS.to_h do |sig|
      [sig, Signal.trap(sig) do
        CertOrphanGuard.reap_group(pgid, started_at: started_at)
        CertOrphanGuard.clear_lock(root) if root
        warn "cert: signal SIG#{sig} — reaped the suite's process group #{pgid} (no orphan left behind)."
        exit!(128 + Signal.list.fetch(sig, 15))
      end]
    end
    yield
  ensure
    previous&.each { |sig, handler| Signal.trap(sig, handler || "DEFAULT") }
  end
end
