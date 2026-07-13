# frozen_string_literal: true

require "json"
require "time"
require "uri"
require "shellwords"
require "fileutils"

# CertOrphanGuard — the cert's answer to the process it could not kill.
#
# THE BUG (live, 2026-07-13). bin/fast-check outran the harness's 120s Bash timeout
# — a diff that maps to ~120 test files runs 7+ minutes, so this is ordinary, not
# exotic. The timeout killed the cert PARENT, and the `bin/rails test` grandchild
# SURVIVED it, reparented to launchd, still holding the worktree's test DB:
#
#   PID   PPID  PGID  STAT  COMMAND
#   41578    1  41538  R    ruby bin/rails test test/models/task_test.rb ...
#   pg_stat_activity: pid 41763 | idle in transaction | bin/rails
#
# Every retry then died in test-prepare with `PG::ObjectInUse: database "..." is
# being accessed by other users` (db:test:purge cannot DROP a database another
# session holds) — which the cert reported as "USUALLY an ENV gap ... NOT a
# regression in your diff", never NAMING the orphan. So the agent retried blindly:
# three attempts, 35 minutes, zero board progress.
#
# TWO DEFENCES, because neither alone is enough:
#
#   1. PREVENT (bin/lib/cert_process.rb) — run each lane in its OWN process group
#      and reap that GROUP on any signal we can catch. This closes every graceful
#      death: SIGTERM/SIGINT/SIGHUP, and the plain-exception path.
#
#   2. DETECT (this file) — a SIGKILLed cert runs no handler, so prevention can
#      never be complete. Whatever the cert could not prevent, the NEXT cert must
#      NAME. We leave a runlock naming our process group; the next cert reads it:
#
#        cert pid ALIVE          → a real concurrent cert is running in this tree.
#                                  REFUSE. Never kill a live sibling, and never run
#                                  two suites against one worktree test DB (that is
#                                  the known hazard that also SIGSEGVs Ruby).
#        cert pid DEAD, group up → provably OUR OWN abandoned suite. REAP it, loudly.
#        nothing alive           → a corpse. Clear it and carry on.
#
#      Plus a backstop for orphans no lock covers (a pre-fix orphan, a stray manual
#      `bin/rails test`, a `bin/release` gate suite): ask the test DB who is holding
#      it and ABORT naming the backend. We only ever auto-kill what we can PROVE is
#      our own; anything else we refuse and name. Never silently block, never
#      silently kill.
#
# The decision table is PURE — inject the liveness probe. Nothing in `decide` reads
# the clock, the process table, or the DB.
module CertOrphanGuard
  LOCK_REL = File.join("tmp", "cert-run.json")

  # --- the runlock ---------------------------------------------------------------

  def self.lock_path(root)
    File.join(root.to_s, LOCK_REL)
  end

  def self.read_lock(root)
    path = lock_path(root)
    return nil unless File.exist?(path)

    lock = JSON.parse(File.read(path))
    lock.is_a?(Hash) && !lock.empty? ? lock : nil
  rescue JSON::ParserError, SystemCallError
    nil # an unreadable lock proves nothing — the DB probe is the backstop
  end

  def self.write_lock(root, cert_pid:, pgid:, lane: nil, db: nil, now: Time.now)
    path = lock_path(root)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
                       "cert_pid" => cert_pid, "pgid" => pgid, "lane" => lane,
                       "db" => db, "started_at" => now.utc.iso8601
                     ))
  rescue SystemCallError
    nil # a cert must never die because it could not write its own lock
  end

  def self.clear_lock(root)
    File.delete(lock_path(root))
  rescue SystemCallError
    nil
  end

  # --- liveness -------------------------------------------------------------------

  # True when `id` still names something running — as a PROCESS (pid) or as a
  # PROCESS GROUP (pgid). Signal 0 tests for existence without delivering anything;
  # a negative target addresses the group. EPERM means "alive, but not ours".
  #
  # A ZOMBIE still answers signal 0 (the pid exists until someone reaps it), so we
  # first clear any zombie of OUR OWN — otherwise a lane we just killed would read as
  # eternally alive. A real orphan is reparented to launchd, which reaps it for us.
  def self.any_alive?(id)
    id = id.to_i
    return false unless id.positive?

    reap_zombie(id)
    signal_ok?(id) || signal_ok?(-id)
  end

  # Clear an exited child we still own. ECHILD (not our child) / ESRCH: nothing to do.
  def self.reap_zombie(pid)
    Process.waitpid(pid, Process::WNOHANG)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def self.signal_ok?(target)
    Process.kill(0, target)
    true
  rescue Errno::EPERM
    true
  rescue Errno::ESRCH, RangeError, ArgumentError
    false
  end

  # --- the decision (PURE) ---------------------------------------------------------
  #
  # Returns [verdict, detail]:
  #   :none       — no lock; nothing ran here before
  #   :concurrent — the cert PROCESS is still alive → refuse (do not kill it)
  #   :orphan     — the cert is dead but its process GROUP lives → reap it (ours)
  #   :stale      — nothing survived → clear the lock and proceed
  #
  # A lock with no pgid can prove nothing is ours, so it grades :stale — we must
  # never kill on a guess. The DB probe covers what the lock cannot.
  def self.decide(lock:, alive: method(:any_alive?))
    return [:none, {}] if lock.nil? || lock.empty?

    cert_pid = lock["cert_pid"].to_i
    pgid = lock["pgid"].to_i
    detail = {
      cert_pid: cert_pid, pgid: pgid, lane: lock["lane"],
      db: lock["db"], started_at: lock["started_at"]
    }

    return [:concurrent, detail] if cert_pid.positive? && alive.call(cert_pid)
    return [:orphan, detail] if pgid.positive? && alive.call(pgid)

    [:stale, detail]
  end

  # --- reaping ----------------------------------------------------------------------

  # Reap a process GROUP: TERM the group, give it a moment, then KILL what remains.
  # The group is the unit that matters — the suite forks (spring, parallel workers,
  # a `sh -c` wrapper), and killing only the leader strands the rest on the DB.
  def self.reap_group(pgid, grace: 3.0)
    pgid = pgid.to_i
    return false unless pgid.positive?

    signal_group(pgid, "TERM")
    deadline = Time.now + grace
    sleep 0.1 while any_alive?(pgid) && Time.now < deadline
    signal_group(pgid, "KILL") if any_alive?(pgid)
    sleep 0.2
    !any_alive?(pgid)
  end

  def self.signal_group(pgid, signal)
    Process.kill(signal, -pgid)
  rescue Errno::ESRCH, Errno::EPERM
    # Not a group leader (or not ours) — fall back to the bare pid.
    begin
      Process.kill(signal, pgid)
    rescue StandardError
      nil
    end
  end

  # --- the test-DB backstop ----------------------------------------------------------

  # The worktree's test DB URL. bin/agent-worktree writes TEST_DATABASE_URL into
  # .env.test.local (dotenv loads it for RAILS_ENV=test; config/database.yml's
  # test.url reads it), so a cert can resolve the DB it is about to contend for
  # WITHOUT booting Rails. nil when we cannot tell — and then we do not guess.
  def self.test_db_url(root, env: ENV)
    from_env = env["TEST_DATABASE_URL"].to_s.strip
    return from_env unless from_env.empty?

    dotenv = File.join(root.to_s, ".env.test.local")
    return nil unless File.exist?(dotenv)

    line = File.readlines(dotenv).find { |l| l =~ /\ATEST_DATABASE_URL\s*=/ }
    return nil unless line

    value = line.split("=", 2).last.to_s.strip.delete_prefix('"').delete_suffix('"')
    value.empty? ? nil : value
  rescue SystemCallError
    nil
  end

  def self.db_name(url)
    return nil if url.nil?

    URI.parse(url).path.to_s.delete_prefix("/")
  rescue StandardError
    nil
  end

  # Who else is connected to the test DB? Returns [{pid:, application_name:}, ...].
  # Best-effort: no psql, no DB, no connection → [] (we report what we can prove,
  # and the runlock covers our own orphans regardless).
  def self.foreign_backends(url, psql: "psql")
    return [] if url.nil? || url.to_s.empty?

    sql = "SELECT pid, coalesce(application_name, '?') FROM pg_stat_activity " \
          "WHERE datname = current_database() AND pid <> pg_backend_pid();"
    out = IO.popen([psql, url.to_s, "-Atc", sql, "-v", "ON_ERROR_STOP=1"],
                   err: File::NULL, &:read).to_s
    return [] unless $?.success?

    out.lines.filter_map do |line|
      pid, name = line.strip.split("|", 2)
      next if pid.to_s.empty?

      { pid: pid.to_i, application_name: name.to_s }
    end
  rescue Errno::ENOENT, SystemCallError
    [] # no psql on this box — the lock still covers our own orphans
  end

  # --- the loud messages -------------------------------------------------------------
  # A cert that refuses and NAMES the orphan is a good cert. A cert that blames "an
  # ENV gap" and lets you retry into the same wall is the bug.

  def self.orphan_message(pgid:, lane: nil, db: nil, started_at: nil)
    "ORPHAN REAPED — a previous cert's test process was still running and holding the test DB. " \
      "It is an orphan: the cert that spawned it is gone (its harness timed out and killed the parent), " \
      "but its process group #{pgid} survived#{lane ? " (lane: #{lane})" : ''}" \
      "#{started_at ? ", started #{started_at}" : ''}#{db ? ", holding #{db}" : ''}. " \
      "Reaped process group #{pgid}. This is an ENV condition — NOT a regression in your diff. " \
      "Continuing with a clean test DB."
  end

  def self.concurrent_message(cert_pid:, lane: nil, db: nil)
    "REFUSING — another cert is already running in this worktree (pid #{cert_pid}" \
      "#{lane ? ", lane: #{lane}" : ''}). Two suites against one worktree test DB" \
      "#{db ? " (#{db})" : ''} corrupt each other's fixtures and SIGSEGV Ruby, so this cert will not " \
      "start beside it. Wait for it to finish and re-run — or, if you know it is dead, kill pid " \
      "#{cert_pid} and re-run. This is an ENV condition — NOT a regression in your diff."
  end

  # --- the preflight both cert lanes run BEFORE any lane -----------------------------
  #
  # Returns [:ok, notices] or [:refuse, message]. The caller aborts on :refuse and
  # prints the notices otherwise — so bin/fast-check and bin/full-suite-check keep
  # their own voice while sharing one policy.
  def self.preflight(root:, env: ENV)
    notices = []
    verdict, detail = decide(lock: read_lock(root))
    url = test_db_url(root, env: env)
    db = db_name(url) || detail[:db]

    case verdict
    when :concurrent
      return [:refuse, concurrent_message(cert_pid: detail[:cert_pid], lane: detail[:lane], db: db)]
    when :orphan
      reap_group(detail[:pgid])
      clear_lock(root)
      notices << orphan_message(pgid: detail[:pgid], lane: detail[:lane], db: db,
                                started_at: detail[:started_at])
    when :stale
      clear_lock(root)
    end

    # The backstop: an orphan no lock of ours covers (one from before this guard
    # shipped, a stray manual `bin/rails test`, a `bin/release` gate suite). We did
    # not spawn it and cannot prove it is garbage — so we REFUSE and name it rather
    # than kill it, and never let the cert walk into PG::ObjectInUse blind.
    backends = foreign_backends(url, psql: env.fetch("CERT_GUARD_PSQL", "psql"))
    return [:refuse, foreign_backend_message(db: db, backends: backends)] if backends.any?

    [:ok, notices]
  end

  def self.foreign_backend_message(db:, backends:)
    named = backends.map { |b| "pid #{b[:pid]} (#{b[:application_name]})" }.join(", ")
    pids = backends.map { |b| b[:pid] }.join(", ")
    "REFUSING — the test DB #{db} is held by #{backends.size} other session(s): #{named}. " \
      "A cert cannot prepare a database another process is holding (db:test:purge → PG::ObjectInUse), " \
      "and running beside it corrupts both suites. This is almost certainly an ORPHANED test process " \
      "from a cert that outran its timeout. It is an ENV condition — NOT a regression in your diff.\n" \
      "  Inspect: ps -eo pid,ppid,pgid,command | grep 'rails test'   # the orphan has PPID 1\n" \
      "  Clear:   psql #{db.to_s.shellescape} -c 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
      "WHERE pid IN (#{pids})'\n" \
      "Then re-run the cert."
  end
end
