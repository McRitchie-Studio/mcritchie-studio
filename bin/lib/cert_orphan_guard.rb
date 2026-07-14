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
#      NAME. We leave a runlock naming our process group; the next cert reads it.
#
# ------------------------------------------------------------------------------
# A PGID IS A RECYCLABLE INTEGER — THE WHOLE POINT OF THIS FILE
# ------------------------------------------------------------------------------
# The first cut of this guard graded a lock as an orphan on the predicate "some
# process with this pgid is alive". That is not an identity. The OS hands pgids
# out again once a group is gone, and this runlock is REPO-RELATIVE — it outlives
# reboots. So a nine-day-old lock whose pgid had since been recycled made the
# guard TERM/KILL an unrelated bystander process and report "ORPHAN REAPED".
# A reaper that guesses is worse than no reaper: it turns a stalled cert into a
# corrupted machine.
#
# So the rule here is absolute: KILL ONLY WHAT WE CAN PROVE IS OURS.
#
# The proof is IDENTITY, not liveness. A pid answers "does some process exist" —
# it can never answer "is this MY suite". So the lock records the OS's own record
# of WHEN the process started (`ps -o lstart=`), and the next cert re-reads it and
# demands an exact match. (pid, start-time) is the classic Unix process identity:
# a recycled pgid is a DIFFERENT process, and a different process cannot have
# started in the same wall-clock second as ours. It is also proof against reboots
# for free — every process on the far side of a reboot started AFTER the reboot,
# so it can never match a start time we recorded before it.
#
# The positive invariant, asserted (never a blacklist of the ways it might not be):
#
#   REAP the group at `pgid` if and only if a live process whose pid == pgid has
#   the exact start time this lock recorded for it.
#
# Everything else is a refusal, not a kill:
#
#   cert pid alive, start MATCHES     → :concurrent   a real sibling cert. REFUSE.
#                                                     Never kill a live cert, and
#                                                     never run two suites against
#                                                     one worktree test DB (that is
#                                                     the hazard that SIGSEGVs Ruby).
#   leader alive, start MATCHES       → :orphan       PROVABLY our abandoned suite.
#                                                     REAP it, loudly. (The bug this
#                                                     file exists for. Still reaped.)
#   leader alive, start MISMATCHES    → :recycled     PROVABLY *not* ours — the pgid
#                                                     was recycled onto a stranger.
#                                                     NEVER kill it. The lock is a
#                                                     corpse: clear it and proceed.
#   alive, but identity UNPROVABLE    → :unverifiable REFUSE and name it. A human
#                                                     decides. We do not guess.
#   nothing alive                     → :stale        a corpse. Clear it, carry on.
#
# Plus a backstop for orphans no lock covers (a pre-fix orphan, a stray manual
# `bin/rails test`, a `bin/release` gate suite): ask the test DB who is holding it
# and ABORT naming the backend — again, name it, never kill it. Never silently
# block, never silently kill.
#
# `decide` is PURE: it takes the lock plus a SNAPSHOT of the process table and
# returns what to do. Nothing in it reads the clock, the process table, or the DB.
module CertOrphanGuard
  LOCK_REL = File.join("tmp", "cert-run.json")

  # --- who is speaking ---------------------------------------------------------------
  #
  # One mechanism, two callers, and the CLOSING LINE of a refusal is load-bearing in
  # both — it tells the reader where the fault is NOT:
  #
  #   a cert refusing → "NOT a regression in your diff"  (don't go re-read your code)
  #   a GATE refusing → "NOT a release regression — nothing to eject or revert"
  #
  # The gate's line is the one with teeth. An abort on the G3/G4 path that does not say
  # it reads as a RED SUITE, and a red suite gets a task EJECTED from the release — so a
  # leftover process would evict good code. That is the precise failure the isolated-gate
  # program exists to end, and it must not be reintroduced by the reaper meant to help.
  #
  # So the voice is a PARAMETER, not a string baked into each message. It defaults to
  # the cert's (every existing caller keeps its exact wording) and bin/release passes
  # GATE explicitly.
  Voice = Struct.new(:actor, :env_line, keyword_init: true)

  CERT = Voice.new(
    actor: "cert",
    env_line: "This is an ENV condition — NOT a regression in your diff."
  ).freeze

  GATE = Voice.new(
    actor: "gate",
    env_line: "This is an ENV issue, NOT a release regression — nothing to eject or revert."
  ).freeze

  # The lowest pgid we will ever aim a signal at.
  #
  # `kill(sig, -1)` does not mean "process group 1". POSIX defines it as EVERY
  # process the caller is permitted to signal — the entire user session. The first
  # cut of this reaper guarded the kill with `pgid.positive?`, which happily admits
  # 1, so one truncated lock file was all that stood between a wedged cert and
  # `kill -TERM -1`. Groups 0 and 1 are never ours; refuse to address them.
  MIN_SIGNALABLE_PGID = 2

  # `ps -o lstart=` renders 5 whitespace-separated tokens: "Tue Jul 14 11:05:12 2026"
  # (the day-of-month is space-padded, hence the normalize below).
  LSTART_TOKENS = 5

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

  # The lock carries IDENTITY, not just numbers. `cert_started_at` / `pgid_started_at`
  # are the OS's own start-time records for those two pids, and they are what makes a
  # later cert able to prove — not assume — that the pid it is looking at is the same
  # process this lock created. A lock without them can prove nothing, and a guard that
  # can prove nothing must not kill (see `decide`: it grades :unverifiable and refuses).
  def self.write_lock(root, cert_pid:, pgid:, cert_started_at: nil, pgid_started_at: nil,
                      lane: nil, db: nil, now: Time.now)
    path = lock_path(root)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
                       "cert_pid" => cert_pid, "cert_started_at" => cert_started_at,
                       "pgid" => pgid, "pgid_started_at" => pgid_started_at,
                       "lane" => lane, "db" => db, "started_at" => now.utc.iso8601
                     ))
  rescue SystemCallError
    nil # a cert must never die because it could not write its own lock
  end

  def self.clear_lock(root)
    File.delete(lock_path(root))
  rescue SystemCallError
    nil
  end

  # --- the process table: the OS's own answer -------------------------------------

  def self.ps_bin(env = ENV)
    env.fetch("CERT_GUARD_PS", "ps")
  end

  # One snapshot of every process on the box: [{pid:, pgid:, state:, started_at:,
  # command:}, ...]. ONE `ps` call, so the leader check and the group membership
  # check see a consistent world (two calls could straddle an exit).
  #
  # `started_at` is the OS's record of when the process started — the half of the
  # identity a pid cannot give us. Empty on any failure, and an empty table proves
  # nothing is ours, so every downstream decision fails SAFE (refuse, never kill).
  def self.process_table(ps: "ps")
    out = IO.popen([ps, "-Ao", "pid=,pgid=,state=,lstart=,command="], err: File::NULL, &:read).to_s
    return [] unless $?.success?

    out.lines.filter_map { |line| parse_ps_line(line) }
  rescue Errno::ENOENT, SystemCallError
    []
  end

  def self.parse_ps_line(line)
    fields = line.strip.split(/\s+/)
    return nil if fields.size < 3 + LSTART_TOKENS + 1

    pid   = Integer(fields.shift, exception: false)
    pgid  = Integer(fields.shift, exception: false)
    state = fields.shift
    return nil if pid.nil? || pgid.nil?

    started = normalize_start(fields.shift(LSTART_TOKENS).join(" "))
    { pid: pid, pgid: pgid, state: state.to_s, started_at: started, command: fields.join(" ") }
  end

  # A start time is only ever compared to another start time we read the same way,
  # so we compare the OS's own rendering — no clock, no parsing, no timezone, no DST
  # fold to get wrong. We only squeeze the space padding ("Jul  8" / "Jul 8").
  def self.normalize_start(value)
    text = value.to_s.strip.squeeze(" ")
    text.empty? ? nil : text
  end

  # The OS's start-time record for one pid, or nil when the pid names nothing.
  # This is what a cert records at spawn so a LATER cert can prove identity.
  def self.process_started_at(pid, ps: "ps")
    pid = pid.to_i
    return nil unless pid.positive?

    out = IO.popen([ps, "-p", pid.to_s, "-o", "lstart="], err: File::NULL, &:read).to_s
    return nil unless $?.success?

    normalize_start(out)
  rescue Errno::ENOENT, SystemCallError
    nil
  end

  # --- liveness (a WEAK signal — never sufficient to authorize a kill) --------------

  # A zombie is not alive in any sense that matters: it holds no DB connection and
  # cannot be killed (it is already dead, just unreaped). Treating one as "alive" is
  # how a reaper spins forever on a corpse.
  def self.zombie?(process)
    process[:state].to_s.start_with?("Z")
  end

  def self.live_process(table, pid)
    pid = pid.to_i
    return nil unless pid.positive?

    table.find { |p| p[:pid] == pid && !zombie?(p) }
  end

  def self.group_members(table, pgid)
    pgid = pgid.to_i
    return [] unless pgid.positive?

    table.select { |p| p[:pgid] == pgid && !zombie?(p) }
  end

  # True when `id` still names something running — as a PROCESS (pid) or as a PROCESS
  # GROUP (pgid). Signal 0 tests for existence without delivering anything; a negative
  # target addresses the group. EPERM means "alive, but not ours".
  #
  # LIVENESS IS NOT IDENTITY. This answers "does something exist under this number",
  # which is exactly the predicate that got an innocent process killed. It is used to
  # WAIT on a group we have already proven is ours — never to decide to kill one.
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

  # --- identity ---------------------------------------------------------------------

  # Is this live process the one the lock created? Three answers, and only ONE of them
  # is a licence to kill:
  #
  #   :ours       — the OS says it started in the exact second the lock recorded.
  #   :not_ours   — it started at some other time. The number was recycled. PROVEN
  #                 innocent; never touch it.
  #   :unprovable — we have no recorded start time (a lock from before this guard), or
  #                 `ps` told us nothing. We cannot prove either way, so we must not act.
  # BOTH sides are normalized here. An identity comparator that trusts its caller to
  # have normalized the input is one refactor away from comparing "Jul  9" to "Jul 9"
  # and concluding, with total confidence, that a process is not itself.
  def self.identity_of(process, recorded_start)
    recorded = normalize_start(recorded_start)
    observed = normalize_start(process && process[:started_at])
    return :unprovable if process.nil? || recorded.nil? || observed.nil?

    observed == recorded ? :ours : :not_ours
  end

  # Never aim a signal at group 0 (our own), group 1 (== every process we own), or the
  # group this very cert is running in. Structural safety, checked at the KILL SITE and
  # not merely at the decision — the last line of defence belongs next to the trigger.
  def self.signalable?(pgid, self_pid: Process.pid, self_pgid: Process.getpgrp)
    pgid = pgid.to_i
    pgid >= MIN_SIGNALABLE_PGID && pgid != self_pgid.to_i && pgid != self_pid.to_i
  end

  # --- the decision (PURE) ---------------------------------------------------------
  #
  # Takes the lock and a SNAPSHOT of the process table; returns [verdict, detail].
  # Reads no clock, no process table, no DB — so every vector below is testable
  # without spawning anything.
  #
  #   :none         — no lock; nothing ran here before
  #   :concurrent   — the cert PROCESS is provably still alive → refuse (do not kill)
  #   :orphan       — the cert is dead and the group leader is PROVABLY ours → reap
  #   :recycled     — something is alive under that pgid but it is PROVABLY NOT ours
  #                   → never kill it; the lock is a corpse, clear it and proceed
  #   :unverifiable — something is alive and we CANNOT prove whose it is → refuse,
  #                   name it, let a human decide
  #   :stale        — nothing survived → clear the lock and proceed
  def self.decide(lock:, table:, self_pid: Process.pid, self_pgid: Process.getpgrp)
    return [:none, {}] if lock.nil? || lock.empty?

    cert_pid = lock["cert_pid"].to_i
    pgid = lock["pgid"].to_i
    detail = {
      cert_pid: cert_pid, pgid: pgid, lane: lock["lane"], db: lock["db"],
      started_at: lock["started_at"], cert_started_at: lock["cert_started_at"],
      pgid_started_at: lock["pgid_started_at"]
    }

    # 1. Is the cert that wrote this lock still running? Identity, not a bare pid: a
    #    recycled cert_pid graded :concurrent forever, wedging every cert in the tree
    #    behind a stranger's process. A mismatch here means our cert is DEAD — fall
    #    through to the group and let the suite be judged on its own identity.
    cert = live_process(table, cert_pid)
    case identity_of(cert, lock["cert_started_at"])
    when :ours
      return [:concurrent, detail.merge(found: cert)]
    when :unprovable
      return [:unverifiable, detail.merge(found: cert, subject: :cert)] if cert
    end

    # 2. The cert is gone. Is the suite it stranded still OURS?
    leader = live_process(table, pgid)
    members = group_members(table, pgid)
    detail[:members] = members

    # A group we must never address, holding something alive: refuse rather than
    # reason about it. (`decide` grading it is belt; `signalable?` at the kill site
    # is braces.)
    if (leader || members.any?) && !signalable?(pgid, self_pid: self_pid, self_pgid: self_pgid)
      return [:unverifiable, detail.merge(found: leader, subject: :unsafe_pgid)]
    end

    case identity_of(leader, lock["pgid_started_at"])
    when :ours     then return [:orphan, detail.merge(found: leader)]
    when :not_ours then return [:recycled, detail.merge(found: leader)]
    when :unprovable
      # The leader is alive but unprovable (a lock from before this guard recorded
      # identity), OR the leader is gone while members of that group live on. Either
      # way we cannot prove the group is ours — and an unprovable group is exactly the
      # one we must not kill.
      return [:unverifiable, detail.merge(found: leader, subject: :group)] if leader || members.any?
    end

    [:stale, detail]
  end

  # --- reaping: only ever what we have PROVEN is ours --------------------------------

  # Reap a process GROUP we can prove we created. `started_at` is the OS start time the
  # lock recorded for the group leader; without a match we do not signal. The group is
  # the unit that matters — the suite forks (spring, parallel workers, a `sh -c`
  # wrapper), and killing only the leader strands the rest on the DB.
  #
  # Identity is re-verified HERE, not trusted from `decide`: between the decision and
  # the trigger the leader can exit and its number be handed to someone else. The
  # proof must be adjacent to the kill.
  #
  # Returns true when the group we proved was ours is gone; false when we refused to
  # signal (which is a success of a different kind).
  def self.reap_group(pgid, started_at:, grace: 3.0, ps: "ps",
                      self_pid: Process.pid, self_pgid: Process.getpgrp)
    pgid = pgid.to_i
    return false unless signalable?(pgid, self_pid: self_pid, self_pgid: self_pgid)

    table = process_table(ps: ps)
    leader = live_process(table, pgid)
    return false unless identity_of(leader, started_at) == :ours

    # Everything in the group at the instant we proved ownership. These, and only
    # these, are ours to kill.
    victims = group_members(table, pgid).map { |p| p.slice(:pid, :started_at, :command) }

    signal_group(pgid, "TERM", self_pid: self_pid, self_pgid: self_pgid)
    deadline = Time.now + grace
    sleep 0.1 while survivors(victims, ps: ps).any? && Time.now < deadline

    escalate(pgid, victims, started_at, ps: ps, self_pid: self_pid, self_pgid: self_pgid)
    survivors(victims, ps: ps).empty?
  end

  # TERM did not do it. Escalate — but re-prove first. If the leader is still provably
  # ours, KILL the group (that also catches workers forked since our snapshot). If the
  # leader has since died, the pgid is no longer a safe address, so fall back to killing
  # the individual survivors we already proved were ours, by identity.
  def self.escalate(pgid, victims, started_at, ps:, self_pid:, self_pgid:)
    left = survivors(victims, ps: ps)
    return if left.empty?

    leader = live_process(process_table(ps: ps), pgid)
    if identity_of(leader, started_at) == :ours
      signal_group(pgid, "KILL", self_pid: self_pid, self_pgid: self_pgid)
    else
      left.each { |v| signal_pid(v[:pid], "KILL") }
    end
    sleep 0.2
  end

  # Which of our proven victims are still running? Matched on (pid, start time), so a
  # pid recycled between our snapshot and now is NOT counted as a survivor — and so is
  # never escalated onto.
  def self.survivors(victims, ps: "ps")
    return [] if victims.empty?

    table = process_table(ps: ps)
    victims.select do |v|
      live = live_process(table, v[:pid])
      live && live[:started_at] == v[:started_at]
    end
  end

  def self.signal_group(pgid, signal, self_pid: Process.pid, self_pgid: Process.getpgrp)
    return unless signalable?(pgid, self_pid: self_pid, self_pgid: self_pgid)

    Process.kill(signal, -pgid)
  rescue Errno::ESRCH, Errno::EPERM
    # Not a group leader (or not ours) — fall back to the bare pid, which we have
    # already proven by start time is the process we spawned.
    signal_pid(pgid, signal)
  end

  def self.signal_pid(pid, signal)
    Process.kill(signal, pid.to_i)
  rescue StandardError
    nil
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
  # ENV gap" and lets you retry into the same wall is the bug. And a cert that KILLS a
  # process it cannot name is worse than either.

  def self.orphan_message(pgid:, lane: nil, db: nil, started_at: nil, voice: CERT)
    "ORPHAN REAPED — a previous #{voice.actor}'s test process was still running and holding the test DB. " \
      "It is an orphan: the #{voice.actor} that spawned it is gone (its harness timed out and killed the parent), " \
      "but its process group #{pgid} survived#{lane ? " (lane: #{lane})" : ''}" \
      "#{started_at ? ", started #{started_at}" : ''}#{db ? ", holding #{db}" : ''}. " \
      "Verified it is OURS (the group leader's start time matches the one this runlock " \
      "recorded when it spawned it) and reaped process group #{pgid}. " \
      "#{voice.env_line} Continuing with a clean test DB."
  end

  def self.concurrent_message(cert_pid:, lane: nil, db: nil, voice: CERT)
    "REFUSING — another #{voice.actor} is already running here (pid #{cert_pid}" \
      "#{lane ? ", lane: #{lane}" : ''}). Two suites against one test DB" \
      "#{db ? " (#{db})" : ''} corrupt each other's fixtures and SIGSEGV Ruby, so this #{voice.actor} will not " \
      "start beside it. Wait for it to finish and re-run — or, if you know it is dead, kill pid " \
      "#{cert_pid} and re-run. #{voice.env_line}"
  end

  # The lock is stale AND its pgid now belongs to somebody else. We say so out loud
  # rather than quietly moving on: this is the exact condition that used to kill an
  # innocent process, and an operator seeing it should know the guard looked, proved
  # the process was not ours, and left it alone.
  def self.recycled_message(pgid:, found: nil, recorded_start: nil)
    live = found ? " It is now #{found[:command].to_s[0, 60].inspect} (pid #{found[:pid]}, started #{found[:started_at]})." : ""
    "STALE RUNLOCK — this worktree's runlock names process group #{pgid}, but that group is NOT ours. " \
      "The lock recorded it as starting #{recorded_start.inspect}, and the process alive under that number " \
      "today started at a different time — the OS recycled the number after our suite died.#{live} " \
      "NOT killing it: a pgid is a recyclable integer, and this guard only ever kills what it can prove it " \
      "spawned. Discarding the stale runlock and continuing."
  end

  # We could not prove ownership either way. This is the one case where we hand the
  # decision to a human: we will not kill on a guess, and we will not walk blindly into
  # PG::ObjectInUse either.
  def self.unverifiable_message(pgid:, subject: :group, found: nil, members: [], db: nil, root: nil, voice: CERT)
    live = ([found].compact + members).uniq { |p| p[:pid] }
    named = live.map { |p| "pid #{p[:pid]} (#{p[:command].to_s[0, 50]}, started #{p[:started_at]})" }.join(", ")
    lock = root ? File.join(root.to_s, LOCK_REL) : LOCK_REL
    subject_line =
      case subject
      when :cert then "the #{voice.actor} process named in the runlock (pid #{found ? found[:pid] : '?'}) is alive"
      when :unsafe_pgid then "the runlock names process group #{pgid}, which is not a group any #{voice.actor} may signal"
      else "process group #{pgid} from the runlock has live members"
      end

    "REFUSING — #{subject_line}, but this runlock does not carry the identity needed to prove those " \
      "processes are ours. (Locks written before this guard recorded process start times cannot be verified.) " \
      "A pgid is a recyclable integer: killing it on liveness alone is how a reaper murders an innocent " \
      "bystander, so this #{voice.actor} will NOT kill anything it cannot name as its own. A human decides.\n" \
      "  Alive now: #{named.empty? ? '(nothing nameable)' : named}\n" \
      "  Inspect:   ps -eo pid,ppid,pgid,lstart,command | grep -E 'rails test|#{pgid}'   # an orphan has PPID 1\n" \
      "  If it IS a stranded suite:  kill -TERM -#{pgid}\n" \
      "  If it is NOT yours at all:  rm #{lock.to_s.shellescape}   # discard the stale runlock\n" \
      "Then re-run the #{voice.actor}. #{voice.env_line}" \
      "#{db ? " (test DB: #{db})" : ''}"
  end

  def self.foreign_backend_message(db:, backends:, voice: CERT)
    named = backends.map { |b| "pid #{b[:pid]} (#{b[:application_name]})" }.join(", ")
    pids = backends.map { |b| b[:pid] }.join(", ")
    "REFUSING — the test DB #{db} is held by #{backends.size} other session(s): #{named}. " \
      "A #{voice.actor} cannot prepare a database another process is holding (db:test:purge → PG::ObjectInUse), " \
      "and running beside it corrupts both suites. This is almost certainly an ORPHANED test process " \
      "from a #{voice.actor} that outran its timeout. #{voice.env_line}\n" \
      "  Inspect: ps -eo pid,ppid,pgid,command | grep 'rails test'   # the orphan has PPID 1\n" \
      "  Clear:   psql #{db.to_s.shellescape} -c 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
      "WHERE pid IN (#{pids})'\n" \
      "Then re-run the #{voice.actor}."
  end

  # --- the preflight both cert lanes run BEFORE any lane -----------------------------
  #
  # Returns [:ok, notices] or [:refuse, message]. The caller aborts on :refuse and
  # prints the notices otherwise — so bin/fast-check and bin/full-suite-check keep
  # their own voice while sharing one policy.
  def self.preflight(root:, env: ENV, voice: CERT)
    notices = []
    ps = ps_bin(env)
    verdict, detail = decide(lock: read_lock(root), table: process_table(ps: ps))
    url = test_db_url(root, env: env)
    db = db_name(url) || detail[:db]
    reaped = false

    case verdict
    when :concurrent
      return [:refuse, concurrent_message(cert_pid: detail[:cert_pid], lane: detail[:lane], db: db, voice: voice)]
    when :unverifiable
      return [:refuse, unverifiable_message(pgid: detail[:pgid], subject: detail[:subject],
                                            found: detail[:found], members: detail[:members].to_a,
                                            db: db, root: root, voice: voice)]
    when :orphan
      reaped = reap_group(detail[:pgid], started_at: detail[:pgid_started_at], ps: ps)
      clear_lock(root)
      notices << orphan_message(pgid: detail[:pgid], lane: detail[:lane], db: db,
                                started_at: detail[:started_at], voice: voice)
    when :recycled
      clear_lock(root)
      notices << recycled_message(pgid: detail[:pgid], found: detail[:found],
                                  recorded_start: detail[:pgid_started_at])
    when :stale
      clear_lock(root)
    end

    # The backstop: an orphan no lock of ours covers (one from before this guard
    # shipped, a stray manual `bin/rails test`, a `bin/release` gate suite). We did
    # not spawn it and cannot prove it is garbage — so we REFUSE and name it rather
    # than kill it, and never let the cert walk into PG::ObjectInUse blind.
    #
    # After a reap, give the backends we just orphaned a moment to close: a suite we
    # PROVED was ours and killed must not then be reported back to us as a stranger.
    backends = settle_backends(url, psql: env.fetch("CERT_GUARD_PSQL", "psql"), settle: reaped)
    return [:refuse, foreign_backend_message(db: db, backends: backends, voice: voice)] if backends.any?

    [:ok, notices]
  end

  def self.settle_backends(url, psql:, settle: false, grace: 2.0)
    backends = foreign_backends(url, psql: psql)
    return backends unless settle && backends.any?

    deadline = Time.now + grace
    while backends.any? && Time.now < deadline
      sleep 0.2
      backends = foreign_backends(url, psql: psql)
    end
    backends
  end
end
