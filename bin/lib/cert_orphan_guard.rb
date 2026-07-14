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
#
# ------------------------------------------------------------------------------
# A GUARD EMITS KILLS ON TWO LAYERS — AND BOTH ARE THE SAME GUARD
# ------------------------------------------------------------------------------
# The second cut of this file hardened the CODE path and left the COPY path wide
# open (review, 2026-07-14). `unverifiable_message` rendered its remediation lines
# with no gate at all, so a runlock naming pgid 1 printed, verbatim, under the
# house's authoritative "here is how to clear it" framing:
#
#   If it IS a stranded suite:  kill -TERM -1
#
# — the exact POSIX catastrophe `MIN_SIGNALABLE_PGID` exists to prevent. pgid 0
# rendered `kill -TERM -0`: the reader's own process group. We had stopped the
# program from doing it and then told the human to do it by hand. The audience for
# that line is an agent, or a tired operator 35 minutes into a wedged cert; its
# whole job is to be copy-pasted. A command we would REFUSE TO FIRE is a command we
# must REFUSE TO PRINT.
#
# So the invariant is stated once, over BOTH layers, and it is what the tests assert:
#
#   EVERY kill command this guard emits — whether it FIRES it (`signal_group` /
#   `signal_pid`) or PRINTS it for a human to paste (`*_message`) — addresses a
#   number that `signalable?` admits.
#
# It holds BY CONSTRUCTION, not by two guards agreeing: `signalable?` is the single
# predicate, `kill_command` is the single place copy is rendered, and both kill sites
# call the same predicate. Two parallel guards drift — that drift is this whole bug.
module CertOrphanGuard
  LOCK_NAME = "cert-run.json"

  # Where the runlock lives when the root is NOT a git repo at all (the unit fixtures;
  # a tarball checkout). Safe by the same argument as the git-dir path below: with no
  # repo there is no `git status` to be dirt to.
  LOCK_REL = File.join("tmp", LOCK_NAME)

  # The lowest id we will ever aim a signal at — as a process GROUP or as a PID.
  #
  # `kill(sig, -1)` does not mean "process group 1". POSIX defines it as EVERY
  # process the caller is permitted to signal — the entire user session. The first
  # cut of this reaper guarded the kill with `pgid.positive?`, which happily admits
  # 1, so one truncated lock file was all that stood between a wedged cert and
  # `kill -TERM -1`. And `kill(sig, 0)` addresses our OWN group; `kill(sig, 1)` aims
  # at init. Groups and pids 0 and 1 are never ours; refuse to address them.
  MIN_SIGNALABLE_PGID = 2

  # `ps -o lstart=` renders 5 whitespace-separated tokens: "Tue Jul 14 11:05:12 2026"
  # (the day-of-month is space-padded, hence the normalize below).
  LSTART_TOKENS = 5

  # --- the runlock ---------------------------------------------------------------
  #
  # THE RUNLOCK MUST NEVER BE VISIBLE TO `git status`. It lives in the GIT DIR, not in
  # the working tree, and that is a correctness requirement — not tidiness.
  #
  # The lock's whole job is to SURVIVE a SIGKILLed cert: it is the only record of who
  # the orphan is, so a cert that dies without running a handler must leave it behind.
  # That makes it a durable file the cert itself creates. Put it in the tracked tree —
  # it was `tmp/cert-run.json` — and it becomes an UNTRACKED FILE in any repo that does
  # not happen to ignore `tmp/`. `git check-ignore` says studio-engine and turf-vault
  # do not. And a cert that REFUSES a dirty tree (bin/lib/cert_tree_guard.rb — LANDING IN
  # #546; not on this branch or on release yet, so this is the hazard it WOULD have hit,
  # not one it hits today) reads dirtiness with `git status --porcelain`, which sees
  # untracked-not-ignored files. So in those two repos the sequence would have been:
  #
  #   1. a SIGKILLed cert leaves the runlock — BY DESIGN
  #   2. the next cert sees `?? tmp/` and aborts "working tree is DIRTY"
  #   3. THE ORPHAN PREFLIGHT NEVER RUNS. The orphan is never reaped, the lock is never
  #      cleared, and every retry hits the same wall — with the cert telling the agent
  #      to `git add -A && git commit`, i.e. to COMMIT A RUNLOCK.
  #
  # That is precisely the deadlock this guard exists to end ("three attempts, 35
  # minutes, zero progress"), rebuilt out of the guard's own artefact. Reproduced by
  # execution against the auto-merged tree, not argued (test/lib/cert_runlock_test.rb).
  #
  # Merge order does NOT save it: the two guard blocks are DISJOINT hunks, git merges
  # them silently, and the dirty guard lands above the preflight. "The sweep will order
  # the hunks" is a convention, not an invariant — and drift between two things that
  # must agree is the exact bug class this file was reworked to eliminate for kills.
  #
  # So the property is made STRUCTURAL. The git dir is not part of the working tree, in
  # any repo, present or future, whatever its .gitignore says — `git status` cannot see
  # into it, and there is nothing for a later refactor to silently re-break. (Adding
  # `tmp/` to two .gitignore files fixes today's two repos and leaves the trap armed for
  # the next one.) In a git WORKTREE this resolves to `.git/worktrees/<name>/`, so the
  # lock stays per-desk exactly as before — the isolation comes free.
  def self.lock_path(root)
    dir = git_dir(root)
    return File.join(dir, LOCK_NAME) if dir

    root.to_s.empty? ? LOCK_REL : File.join(root.to_s, LOCK_REL)
  end

  # The repo's git dir for `root`, absolute, or nil when `root` is not in a repo.
  #
  # `--absolute-git-dir` over `--git-dir`: the latter answers RELATIVE to the cwd when
  # the cwd is the toplevel (a bare ".git"), and we resolve for an arbitrary `root` that
  # is usually not the cwd. Absolute is the only answer that is right from anywhere.
  # In a worktree it returns `<main>/.git/worktrees/<name>` — the per-desk dir we want.
  #
  # MEMOIZED per root: `lock_path` is on the read/write/clear path AND inside every message
  # renderer, so an un-memoized `git rev-parse` forked a subprocess on each call — several
  # per cert, in a module whose entire job is to run before the suite does. A root's git dir
  # cannot change inside one cert. Nil is cached too (`key?`, not `||=`): "not a repo" is an
  # answer, and re-forking git to re-learn it every time is the same waste.
  def self.git_dir(root)
    return nil if root.to_s.empty?

    key = root.to_s
    @git_dirs ||= {}
    return @git_dirs[key] if @git_dirs.key?(key)

    @git_dirs[key] = resolve_git_dir(key)
  end

  def self.resolve_git_dir(root)
    out = IO.popen(["git", "-C", root, "rev-parse", "--absolute-git-dir"],
                   err: File::NULL, &:read).to_s.strip
    return nil unless $?.success? && !out.empty?

    out
  rescue Errno::ENOENT, SystemCallError
    nil # no git on PATH → no `git status` either → nothing to be dirt to
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

  # NOTE — `any_alive?`/`reap_zombie`/`signal_ok?` USED to live here: a liveness probe
  # (`Process.kill(0, -id)` guarded by nothing but `id.positive?`). They were deleted in
  # review, and it is worth saying why rather than letting the next author reinvent them.
  # They had ZERO callers and ZERO coverage — dead code that nonetheless modelled, in this
  # file of all files, THE VERY PREDICATE THIS FILE CONDEMNS: `positive?` admits pgid 1,
  # and `kill(0, -1)` probes every process in the session. An unused footgun in a safety
  # module is still a footgun; the next person to need "is it alive?" would have found it
  # sitting right here, pre-blessed. If you need liveness, read it off `process_table` —
  # and remember that liveness is not identity, and never becomes it.

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

  # THE ONE PREDICATE. May we aim a signal at this number — as a process GROUP (`kill
  # sig, -id`) or as a PID (`kill sig, id`)?
  #
  # Never 0 (our own group), never 1 (== every process we own, and init), never the group
  # or pid this very cert is running in. It is deliberately ONE predicate for both kill
  # forms and for both emission layers: `signal_group` fires through it, `signal_pid`
  # fires through it, and `kill_command` PRINTS through it. Two separate guards — one for
  # the code, one for the copy — is exactly the drift that shipped `kill -TERM -1` in a
  # message while the code refused to fire it.
  #
  # Structural safety, checked at the KILL SITE and not merely at the decision: the last
  # line of defence belongs next to the trigger.
  # `coerce_pid` FIRST, and not because a caller needs it today: `pgid.to_i` on the `{}`
  # that a malformed lock can hold is a NoMethodError, so THE ONE PREDICATE could be made
  # to CRASH rather than refuse. Every in-tree caller happens to be guarded by coerce_pid
  # upstream — which is exactly the argument this file rejects two screens up: the last
  # line of defence belongs next to the trigger, "not one frame up in the caller that
  # happens to check today". A guard that dies on garbage has no opinion about garbage;
  # garbage is not signalable, so say so. Semantics-preserving for every valid input.
  def self.signalable?(pgid, self_pid: Process.pid, self_pgid: Process.getpgrp)
    pgid = coerce_pid(pgid)
    return false if pgid.nil?

    pgid >= MIN_SIGNALABLE_PGID && pgid != self_pgid.to_i && pgid != self_pid.to_i
  end

  # A pid/pgid out of a JSON lock is whatever was on disk — `{"pgid": {}}` is a Hash, and
  # `Hash#to_i` is a NoMethodError, which crashed `decide` (review, 2026-07-14) instead of
  # refusing cleanly. A guard that dies on malformed input has no opinion about malformed
  # input. Anything that is not plainly an integer is not a pid, and we never guess at one.
  def self.coerce_pid(value)
    case value
    when Integer then value
    when String then Integer(value.strip, exception: false)
    end # nil / Hash / Array / bool → nil, and nil means "this lock names nobody"
  end

  # --- the decision (PURE) ---------------------------------------------------------
  #
  # Takes the lock and a SNAPSHOT of the process table; returns [verdict, detail].
  # Reads no clock, no process table, no DB — so every vector below is testable
  # without spawning anything.
  #
  #   :none         — no lock; nothing ran here before
  #   :malformed    — the lock does not name an integer pid + pgid → it proves nothing
  #                   and names nobody we could verify. Discard it LOUDLY (there is no
  #                   process in it to kill), and let the DB backstop speak for any real
  #                   orphan. Refusing on it instead would wedge every cert in the tree
  #                   behind a corrupt file with zero evidence of a live suite — a gate
  #                   asserting rather than evidencing, which is this wave's whole disease.
  #   :concurrent   — the cert PROCESS is provably still alive → refuse (do not kill)
  #   :orphan       — the cert is dead and the group leader is PROVABLY ours → reap
  #   :recycled     — something is alive under that pgid but it is PROVABLY NOT ours
  #                   → never kill it; the lock is a corpse, clear it and proceed
  #   :unverifiable — something is alive and we CANNOT prove whose it is → refuse,
  #                   name it, let a human decide
  #   :stale        — nothing survived → clear the lock and proceed
  def self.decide(lock:, table:, self_pid: Process.pid, self_pgid: Process.getpgrp)
    return [:none, {}] if lock.nil? || lock.empty?

    cert_pid = coerce_pid(lock["cert_pid"])
    pgid = coerce_pid(lock["pgid"])
    detail = {
      cert_pid: cert_pid, pgid: pgid, lane: lock["lane"], db: lock["db"],
      started_at: lock["started_at"], cert_started_at: lock["cert_started_at"],
      pgid_started_at: lock["pgid_started_at"]
    }
    return [:malformed, detail] if cert_pid.nil? || pgid.nil?

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

  # THE ONE PREDICATE FOR "MAY WE REAP THIS GROUP?" — and therefore the one predicate for
  # "may we PRINT a kill at this group?". `reap_group` gates its trigger on it and
  # `reap_failed_message` gates its Clear: line on it: the SAME CALL, not two guards that
  # agree by convention.
  #
  # `signalable?` is only the WEAKER half. It says the NUMBER is safe to aim at (not 0,
  # not 1, not our own group) — it says NOTHING about whether what answers to that number
  # is OURS. Gating the code on `signalable? AND identity` while gating the copy on
  # `signalable?` ALONE is exactly the drift that printed `Clear: kill -KILL -4300` at a
  # group the reaper had just PROVEN was a stranger and refused to touch. Two predicates
  # that must agree WILL drift; one predicate cannot.
  #
  # Read at the TRIGGER, never trusted from `decide`: between the decision and the kill the
  # leader can exit and its pid be handed to someone else. The proof must be adjacent to
  # the act — and the act includes the act of TELLING AN OPERATOR TO KILL IT.
  def self.reapable?(pgid, started_at, ps: "ps",
                     self_pid: Process.pid, self_pgid: Process.getpgrp)
    return false unless signalable?(pgid, self_pid: self_pid, self_pgid: self_pgid)

    identity_of(live_process(process_table(ps: ps), pgid), started_at) == :ours
  end

  # Outcomes of a reap that CLEAR the runlock: the group is gone, and we know it.
  # `:survived` and `:refused` do NOT — see `reap_group`.
  REAP_CLEARED = %i[reaped absent].freeze

  def self.reap_cleared?(outcome)
    REAP_CLEARED.include?(outcome)
  end

  # Reap a process GROUP we can prove we created. `started_at` is the OS start time the
  # lock recorded for the group leader; without a match we do not signal. The group is
  # the unit that matters — the suite forks (spring, parallel workers, a `sh -c`
  # wrapper), and killing only the leader strands the rest on the DB.
  #
  # Returns a TRI-STATE, because the old boolean CONFLATED outcomes whose remediations are
  # opposites, and every caller then had to guess:
  #
  #   :reaped   — proved it was ours, signalled, and the group is gone.
  #   :absent   — nothing is alive under that pgid. Nothing to reap; not a refusal.
  #   :survived — proved it was ours, signalled TERM+KILL, and it OUTLIVED us.
  #   :refused  — we could not prove the group is ours (a stranger holds the recycled
  #               number, or `started_at` is nil so identity is :unprovable), or the pgid
  #               is not signalable at all. WE NEVER SIGNALLED.
  #
  # The distinction is load-bearing for the RUNLOCK. `false` used to mean both "already
  # gone, nothing to do" and "alive and I refused" — so a caller that cleared the lock on
  # false destroyed the only record naming a process it had just declined to kill, and a
  # caller that KEPT the lock on false left a stale lock behind every clean cert. Neither
  # is recoverable from a boolean. Clear the lock on `reap_cleared?`; keep it otherwise.
  def self.reap_group(pgid, started_at:, grace: 3.0, ps: "ps",
                      self_pid: Process.pid, self_pgid: Process.getpgrp)
    pgid = pgid.to_i
    return :refused unless signalable?(pgid, self_pid: self_pid, self_pgid: self_pgid)

    table = process_table(ps: ps)
    leader = live_process(table, pgid)
    unless identity_of(leader, started_at) == :ours
      # Nothing alive under the number at all → there is simply nothing to reap, and the
      # lock may go. Anything ELSE alive under it is a group we cannot prove is ours, and
      # an unprovable group is exactly the one we must not kill — and must not name in a
      # kill we hand to an operator either.
      return leader.nil? && group_members(table, pgid).empty? ? :absent : :refused
    end

    # Everything in the group at the instant we proved ownership. These, and only
    # these, are ours to kill.
    victims = group_members(table, pgid).map { |p| p.slice(:pid, :started_at, :command) }

    signal_group(pgid, "TERM", self_pid: self_pid, self_pgid: self_pgid)
    deadline = Time.now + grace
    sleep 0.1 while survivors(victims, ps: ps).any? && Time.now < deadline

    escalate(pgid, victims, started_at, ps: ps, self_pid: self_pid, self_pgid: self_pgid)
    survivors(victims, ps: ps).empty? ? :reaped : :survived
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

  # Signal a process GROUP. Note what we do NOT do on failure: fall back to killing the
  # bare pid.
  #
  # ESRCH here means "there is no process group with this id". When we have a LIVE pid
  # under that number and yet no group, that is not a puzzle to route around — it is the
  # strongest evidence available that our group is gone and the number has been handed
  # to somebody else. The old code escalated to `kill(signal, pgid)` at exactly the
  # point it should have refused, turning the best available proof of innocence into a
  # death sentence. Any member that genuinely survives is killed by `escalate`, by
  # identity, one pid at a time.
  def self.signal_group(pgid, signal, self_pid: Process.pid, self_pgid: Process.getpgrp)
    return unless signalable?(pgid, self_pid: self_pid, self_pgid: self_pgid)

    Process.kill(signal, -pgid)
  rescue Errno::ESRCH, Errno::EPERM
    nil # the group is gone (or was never ours). Escalation is by identity, not by guess.
  end

  # Signal ONE pid — the escalation path for a survivor we have already proven is ours.
  # It goes through the SAME predicate as the group kill: `kill(sig, 1)` aims at init and
  # `kill(sig, 0)` aims at our own process group, so a pid is no safer an integer than a
  # pgid is. This guard had none of its own until review (2026-07-14) — and the doctrine
  # of this file is that the last line of defence belongs next to the trigger, not one
  # frame up in the caller that happens to check today.
  def self.signal_pid(pid, signal, self_pid: Process.pid, self_pgid: Process.getpgrp)
    return false unless signalable?(pid, self_pid: self_pid, self_pgid: self_pgid)

    Process.kill(signal, pid.to_i)
    true
  rescue StandardError
    false
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
  #
  # A message here is not commentary — it is an INSTRUCTION to an agent or to a tired
  # operator, and every command in it will be pasted into a shell exactly as printed.
  # So the copy obeys the same law as the code: see `kill_command`.

  # THE ONLY PLACE THIS FILE RENDERS A KILL INTO COPY. Same predicate as the kill site,
  # so a command we would refuse to FIRE can never be one we PRINT. Returns nil when the
  # target is unsignalable, and callers OMIT the line rather than degrade it — there is
  # nothing safe to suggest about group 0 or 1, and a "careful, don't run this one"
  # caveat is not a safety mechanism. It is a `kill -TERM -1` with a footnote.
  #
  # `-pgid` addresses the GROUP; a bare pid addresses one process. Both go through here.
  def self.kill_command(signal, target, group: true)
    return nil unless signalable?(target)

    "kill -#{signal} #{group ? '-' : ''}#{target.to_i}"
  end

  # The `ps | grep` we hand over so a human can look before they leap. When the pgid is
  # garbage we must not offer it as a grep alternate either: `grep -E 'rails test|1'`
  # matches nearly every line of `ps` output (every pid, ppid or pgid containing a 1), so
  # the "inspect it yourself" step would hand back the whole process table as suspects —
  # noise dressed as evidence, one impatient paste away from the kill we just refused.
  def self.inspect_command(pgid)
    pattern = signalable?(pgid) ? "rails test|#{pgid.to_i}" : "rails test"
    "ps -eo pid,ppid,pgid,lstart,command | grep -E '#{pattern}'"
  end

  # The lock named a group that was alive when we DECIDED and gone by the time we reached
  # the trigger — it exited on its own. Clearing the lock is right; claiming we reaped it
  # is not. We killed nothing, so we take credit for nothing.
  def self.orphan_vanished_message(pgid:, lane: nil, db: nil)
    "ORPHAN GONE — this worktree's runlock named a suite (process group #{pgid}" \
      "#{lane ? ", lane: #{lane}" : ''}) that was still running when we read the process table, but it " \
      "EXITED on its own before we signalled it. We reaped NOTHING — there was nothing left to reap. " \
      "Discarded the stale runlock#{db ? " (test DB: #{db})" : ''} and continuing. " \
      "This is an ENV condition — NOT a regression in your diff."
  end

  def self.orphan_message(pgid:, lane: nil, db: nil, started_at: nil)
    "ORPHAN REAPED — a previous cert's test process was still running and holding the test DB. " \
      "It is an orphan: the cert that spawned it is gone (its harness timed out and killed the parent), " \
      "but its process group #{pgid} survived#{lane ? " (lane: #{lane})" : ''}" \
      "#{started_at ? ", started #{started_at}" : ''}#{db ? ", holding #{db}" : ''}. " \
      "Verified it is OURS (the group leader's start time matches the one this worktree's runlock " \
      "recorded when it spawned it) and reaped process group #{pgid}. " \
      "This is an ENV condition — NOT a regression in your diff. Continuing with a clean test DB."
  end

  def self.concurrent_message(cert_pid:, lane: nil, db: nil)
    # Even the "if you know it is dead" escape hatch is a kill we are PRINTING, so it is
    # rendered through the same gate as every other one.
    reap = kill_command("TERM", cert_pid, group: false)
    "REFUSING — another cert is already running in this worktree (pid #{cert_pid}" \
      "#{lane ? ", lane: #{lane}" : ''}). Two suites against one worktree test DB" \
      "#{db ? " (#{db})" : ''} corrupt each other's fixtures and SIGSEGV Ruby, so this cert will not " \
      "start beside it. Wait for it to finish and re-run" \
      "#{reap ? " — or, if you know it is dead, `#{reap}` and re-run" : ''}. " \
      "This is an ENV condition — NOT a regression in your diff."
  end

  # The lock is garbage: it does not name an integer pid and pgid at all (a truncated
  # write, a hand-edit, a half-flushed file from a SIGKILLed cert). It therefore names
  # NOBODY — there is no process in it to verify and nothing in it we could be entitled
  # to kill. So we say so out loud and move on, and the DB backstop below is what speaks
  # for a real orphan, on evidence, if one is actually holding the database.
  def self.malformed_message(root: nil, db: nil)
    lock = lock_path(root) # the path we actually READ — never a second guess at it
    "MALFORMED RUNLOCK — #{lock} does not name a process id and process group we can read. " \
      "It proves nothing: a lock that names nobody cannot authorize a kill, and this guard only " \
      "ever kills what it can prove it spawned. Discarding it and continuing" \
      "#{db ? " (test DB: #{db})" : ''} — if a real orphan IS holding the test DB, the backstop " \
      "below names it on the evidence. This is an ENV condition — NOT a regression in your diff."
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
  #
  # THE HANDED-OVER KILL IS ITSELF A KILL. This message is where the second bug lived:
  # it printed `kill -TERM -#{pgid}` unconditionally, so the :unsafe_pgid case — the case
  # that EXISTS because the pgid is 0 or 1 — printed `kill -TERM -1`. We refused to fire
  # it and then instructed a human to fire it, in a message whose entire purpose is to be
  # copy-pasted. Now the kill line is rendered by `kill_command`, which is the same gate
  # the trigger uses, so for an unsignalable group NO kill is offered at all: the only
  # remediation is `rm` the lock. That is not a degradation — a runlock naming group 0 or
  # 1 is garbage BY CONSTRUCTION (no cert ever ran in group 1), so there is no stranded
  # suite behind it to reap, and nothing a kill could correctly do.
  def self.unverifiable_message(pgid:, subject: :group, found: nil, members: [], db: nil, root: nil)
    return unsafe_pgid_message(pgid: pgid, root: root, db: db) if subject == :unsafe_pgid

    live = ([found].compact + members).uniq { |p| p[:pid] }
    named = live.map { |p| "pid #{p[:pid]} (#{p[:command].to_s[0, 50]}, started #{p[:started_at]})" }.join(", ")
    lock = lock_path(root)
    reap = kill_command("TERM", pgid)
    subject_line =
      if subject == :cert
        "the cert process named in the runlock (pid #{found ? found[:pid] : '?'}) is alive"
      else
        "process group #{pgid} from the runlock has live members"
      end

    "REFUSING — #{subject_line}, but this runlock does not carry the identity needed to prove those " \
      "processes are ours. (Locks written before this guard recorded process start times cannot be verified.) " \
      "A pgid is a recyclable integer: killing it on liveness alone is how a reaper murders an innocent " \
      "bystander, so this cert will NOT kill anything it cannot name as its own. A human decides.\n" \
      "  Alive now: #{named.empty? ? '(nothing nameable)' : named}\n" \
      "  Inspect:   #{inspect_command(pgid)}   # an orphan has PPID 1\n" \
      "#{reap ? "  If it IS a stranded suite:  #{reap}\n  If it is NOT yours at all:  " : '  Clear it:  '}" \
      "rm #{lock.to_s.shellescape}   # discard the runlock" \
      "#{reap ? '' : " — a lock naming group #{pgid.to_i} is garbage by construction; there is nothing to reap"}\n" \
      "Then re-run the cert. This is an ENV condition — NOT a regression in your diff." \
      "#{db ? " (test DB: #{db})" : ''}"
  end

  # A runlock naming group 0 or 1 is NOT an identity gap. It is a STRUCTURALLY INVALID
  # lock: no cert ever ran in group 0 (that is the reader's own group) or group 1 (init;
  # and `kill -TERM -1` is every process we own). So there is no suite behind it to reap,
  # nothing to verify, and exactly ONE remedy — which means there is no decision to hand
  # a human and no target to name.
  #
  # It used to borrow the :cert/:group prose and got all of that wrong. It blamed a
  # missing identity ("this runlock does not carry the identity needed to prove those
  # processes are ours… A pgid is a recyclable integer… A human decides") when the truth
  # is that the lock is corrupt; and it then printed "Alive now: pid 4321 (…)" — processes
  # that merely SHARE group 0/1 and are DEFINITIONALLY NOT OURS — naming them as targets
  # underneath a refusal which says there is nothing to reap. Copy asserting more than the
  # code can prove: the same drift class as the `kill -TERM -1` bug this file was written
  # to end, one message over. Say only what is true, and offer only what is safe.
  # NOTE the prose below names NO kill command, not even to explain why one would be
  # wrong. The first draft of this message read "...and `kill -TERM -1` signals every
  # process you own" — an explanation, but the KILL_IN_COPY invariant caught it, and the
  # invariant is right: this message exists to be COPY-PASTED, by an agent or by a tired
  # operator, and a refusal that contains the forbidden command as a literal string is
  # one careless paste away from being the bug. Describe the danger; never spell it.
  def self.unsafe_pgid_message(pgid:, root: nil, db: nil)
    pgid = coerce_pid(pgid).to_i
    "REFUSING — this worktree's runlock names process group #{pgid}, which is not a group any cert can " \
      "ever have run in: group 0 addresses this process's OWN group, and group 1 addresses init — " \
      "signalling it would hit every process you own. The lock is CORRUPT — a truncated write, a " \
      "hand-edit, a half-flushed file from a SIGKILLed cert — not merely unverifiable. It names NO " \
      "suite of ours: there is nothing to reap and nothing in it we could be entitled to kill, so no " \
      "kill is offered here, because none would be correct. Nor are any live processes named: whatever " \
      "shares group #{pgid} is, by definition, NOT ours.\n" \
      "  Clear it:  rm #{lock_path(root).to_s.shellescape}   # discard the corrupt runlock\n" \
      "  Inspect:   #{inspect_command(pgid)}   # if a suite IS stranded, it has PPID 1 — found by NAME, not by this lock\n" \
      "Then re-run the cert. If a real orphan IS holding the test DB, the backstop names it on the " \
      "evidence. This is an ENV condition — NOT a regression in your diff." \
      "#{db ? " (test DB: #{db})" : ''}"
  end

  # The reap did not clear the group. TWO CAUSES, and they get OPPOSITE remediations —
  # collapsing them is what printed a kill at a proven stranger for three rounds:
  #
  #   :survived — we PROVED it was ours, signalled TERM then KILL, and it outlived us.
  #               It is still running and still holding the DB. A kill is the honest
  #               remediation: we know whose it is, and we already tried to fire it.
  #   :refused  — we could NOT prove the group is ours. What answers to that pgid now is,
  #               by definition, NOT the suite we spawned (a recycled number, or an
  #               identity we cannot establish). There is NOTHING here we are entitled to
  #               kill, so NO kill is offered — the same shape as `unsafe_pgid_message`.
  #
  # The Clear: line is gated on `reapable?` — THE SAME CALL `reap_group` gates its trigger
  # on. It is not a second guard that agrees with the first by convention; it is the first
  # guard. A command we would refuse to FIRE is a command we must refuse to PRINT, and the
  # only way to guarantee that is to ask the one predicate both times.
  def self.reap_failed_message(pgid:, lane: nil, db: nil, root: nil, reason: :refused,
                               started_at: nil, ps: "ps")
    clear = kill_command("KILL", pgid) if reapable?(pgid, started_at, ps: ps)
    held = db ? "the test DB #{db}" : "the test DB"
    head = "REFUSING — this worktree's runlock names an orphaned suite (process group #{pgid}" \
           "#{lane ? ", lane: #{lane}" : ''}) that we could NOT reap. "

    if clear
      "#{head}It is still running, and while it holds #{held} every cert here dies in " \
        "test-prepare on PG::ObjectInUse. It is PROVABLY ours (the group leader's start time still " \
        "matches the one this worktree's runlock recorded), we signalled it TERM then KILL, and it " \
        "outlived both. The runlock is left in place on purpose: it names the process.\n" \
        "  Inspect: #{inspect_command(pgid)}\n" \
        "  Clear:   #{clear}\n" \
        "Then re-run the cert. This is an ENV condition — NOT a regression in your diff."
    else
      "#{head}We could NOT prove the group is OURS: the leader's start time does not match the one " \
        "this worktree's runlock recorded when it spawned the suite#{reason == :survived ? ' (its identity changed under us between the proof and the trigger)' : ''}. " \
        "Whatever answers to group #{pgid} now is, by definition, NOT our suite — the number was " \
        "recycled, or its identity cannot be established — so we did NOT signal it, and NO kill is " \
        "offered here, because none would be correct. Killing it would kill a stranger's process.\n" \
        "  Clear it:  rm #{lock_path(root).to_s.shellescape}   # the lock names nobody we can verify\n" \
        "  Inspect:   #{inspect_command(pgid)}   # if a suite IS stranded it has PPID 1 — found by NAME, not by this lock\n" \
        "Then re-run the cert. If a real orphan IS holding #{held}, the backstop names it on the " \
        "evidence. This is an ENV condition — NOT a regression in your diff."
    end
  end

  # The unwedge command must connect the way the PROBE connected. `foreign_backends` dials
  # the full TEST_DATABASE_URL; printing `psql <db-name>` told the operator to dial a bare
  # name, which resolves only where DATABASE_URL happens to be a default local socket with
  # a matching role — anywhere else (a non-default port, a host, a role, CI) the handed-over
  # fix fails on the operator with a confusing auth error, at the exact moment they are 35
  # minutes into a wedge and trusting us. Print the URL we actually used.
  def self.foreign_backend_message(db:, backends:, url: nil)
    named = backends.map { |b| "pid #{b[:pid]} (#{b[:application_name]})" }.join(", ")
    pids = backends.map { |b| b[:pid] }.join(", ")
    target, caveat = psql_target(url, db)
    "REFUSING — the test DB #{db} is held by #{backends.size} other session(s): #{named}. " \
      "A cert cannot prepare a database another process is holding (db:test:purge → PG::ObjectInUse), " \
      "and running beside it corrupts both suites. This is almost certainly an ORPHANED test process " \
      "from a cert that outran its timeout. It is an ENV condition — NOT a regression in your diff.\n" \
      "  Inspect: ps -eo pid,ppid,pgid,command | grep 'rails test'   # the orphan has PPID 1\n" \
      "  Clear:   psql #{target} -c 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
      "WHERE pid IN (#{pids})'\n#{caveat}" \
      "Then re-run the cert."
  end

  # The psql target, and a caveat line when we had to redact. A test DB URL CAN carry a
  # password (Heroku, a CI service container), and a cert log is a durable artefact that
  # gets pasted into PRs — so the password never goes in it. House rule, no exceptions:
  # never print a secret. Locally (the case that actually wedges an agent) the worktree URL
  # has no password, so the command is exactly copy-pasteable as printed.
  def self.psql_target(url, db)
    raw = url.to_s
    return [db.to_s.shellescape, ""] if raw.empty?

    uri = begin
      URI.parse(raw)
    rescue StandardError
      nil
    end
    return [raw.shellescape, ""] if uri.nil? || uri.password.to_s.empty?

    uri.password = "REDACTED"
    [uri.to_s.shellescape,
     "  (the password above is REDACTED — a cert log is not a place for secrets; " \
     "run it with the real TEST_DATABASE_URL from .env.test.local)\n"]
  end

  # --- the preflight both cert lanes run BEFORE any lane -----------------------------
  #
  # Returns [:ok, notices] or [:refuse, message]. The caller aborts on :refuse and
  # prints the notices otherwise — so bin/fast-check and bin/full-suite-check keep
  # their own voice while sharing one policy.
  def self.preflight(root:, env: ENV)
    notices = []
    ps = ps_bin(env)
    verdict, detail = decide(lock: read_lock(root), table: process_table(ps: ps))
    url = test_db_url(root, env: env)
    db = db_name(url) || detail[:db]
    reaped = false

    case verdict
    when :concurrent
      return [:refuse, concurrent_message(cert_pid: detail[:cert_pid], lane: detail[:lane], db: db)]
    when :unverifiable
      return [:refuse, unverifiable_message(pgid: detail[:pgid], subject: detail[:subject],
                                            found: detail[:found], members: detail[:members].to_a,
                                            db: db, root: root)]
    when :orphan
      # Gate the notice on what actually HAPPENED, not on what we set out to do. The
      # old code discarded this return and printed "ORPHAN REAPED ... Continuing with a
      # clean test DB" even when the reap had failed — then failed closed anyway on the
      # DB backstop, handing the operator a contradictory ORPHAN REAPED + REFUSING pair
      # and no idea which to believe. A cert that reports a kill it did not perform is
      # back to asserting rather than evidencing.
      #
      # `started_at:` and `ps:` are handed to the MESSAGE too, so it can ask the same
      # `reapable?` the reap asked. Without them the renderer could only see the pgid —
      # and a renderer that can only see the number can only gate on the number.
      outcome = reap_group(detail[:pgid], started_at: detail[:pgid_started_at], ps: ps)
      unless reap_cleared?(outcome)
        return [:refuse, reap_failed_message(pgid: detail[:pgid], lane: detail[:lane], db: db,
                                             root: root, reason: outcome,
                                             started_at: detail[:pgid_started_at], ps: ps)]
      end

      clear_lock(root)
      notices << if outcome == :absent
                   # It died between the decision and the trigger. The lock may go — but we
                   # reaped NOTHING, and we say so rather than take credit for the exit.
                   orphan_vanished_message(pgid: detail[:pgid], lane: detail[:lane], db: db)
                 else
                   orphan_message(pgid: detail[:pgid], lane: detail[:lane], db: db,
                                  started_at: detail[:started_at])
                 end
    when :recycled
      clear_lock(root)
      notices << recycled_message(pgid: detail[:pgid], found: detail[:found],
                                  recorded_start: detail[:pgid_started_at])
    when :malformed
      # It names nobody, so there is nobody to verify and nobody we may kill. Discard it
      # LOUDLY and fall through to the DB backstop, which refuses on EVIDENCE if a real
      # orphan is holding the database.
      clear_lock(root)
      notices << malformed_message(root: root, db: db)
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
    return [:refuse, foreign_backend_message(db: db, backends: backends, url: url)] if backends.any?

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
