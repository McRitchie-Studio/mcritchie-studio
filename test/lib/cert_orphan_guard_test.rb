# frozen_string_literal: true

# Unit tests for bin/lib/cert_orphan_guard.rb — the cert's orphan detector.
#
# The bug it exists for (live, 2026-07-13): bin/fast-check ran past the harness's
# 120s Bash timeout, the timeout killed the cert PARENT, and the `bin/rails test`
# grandchild SURVIVED (reparented to launchd, PPID 1) still holding an open
# connection to the worktree's test DB. Every retry then died in test-prepare with
#
#   PG::ObjectInUse: database "..._test_..." is being accessed by other users
#   Tasks: TOP => db:test:load_schema => db:test:purge
#
# reported as "USUALLY an ENV gap ... NOT a regression in your diff" — which never
# NAMES the orphan, so the agent retries blindly. Three attempts, 35 minutes, zero
# board progress.
#
# ------------------------------------------------------------------------------
# AND THE BUG THIS FILE ITSELF SHIPPED (review, 2026-07-14)
# ------------------------------------------------------------------------------
# The first cut of the guard graded a lock :orphan on the predicate "some process
# with this pgid is alive", and the test that covered it REASONED ITS WAY PAST the
# hole. It is worth quoting, because it is a whole genre of bad test:
#
#   def test_orphan_verdict_never_depends_on_the_dead_parent_being_reused
#     # A pgid that is alive while the cert pid is dead is an orphan even if some
#     # unrelated process later recycles the parent's pid number — we key the reap
#     # on the GROUP, and the group is what holds the DB.
#
# It thought about pid reuse. It then dismissed it, because we key on the GROUP —
# never noticing that A GROUP ID IS ITSELF A RECYCLABLE INTEGER. The runlock is
# repo-relative and outlives reboots, so a nine-day-old lock whose pgid the OS has
# since handed to somebody else is not a hypothetical: the reviewer reproduced it
# live, and the guard TERM/KILLed an unrelated bystander and printed "ORPHAN REAPED".
#
# So the tests below assert the POSITIVE invariant — "the group we kill is the one
# this lock created, proven by the OS's own start-time record" — rather than
# blacklisting the ways a group might not be ours. Liveness is not identity, and no
# amount of liveness ever becomes identity.
#
# `decide` is PURE: lock + a SNAPSHOT of the process table in, verdict out. So every
# vector here — a recycled pgid, a previous boot, the reaper's own group — is
# expressible as a table, with nothing spawned. The vectors that need REAL processes
# (does it actually refuse to kill the bystander? does it still actually reap a real
# orphan?) live in test/lib/cert_orphan_guard_reaper_test.rb.
#
# Run directly:  ruby -Itest test/lib/cert_orphan_guard_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "shellwords"
require_relative "../../bin/lib/cert_orphan_guard"

class CertOrphanGuardTest < Minitest::Test
  OURS  = "Mon Jul 13 05:00:00 2026"   # when the lock says our suite started
  OTHER = "Wed Jul  9 22:14:03 2026"   # when the process alive under that number ACTUALLY started
  DB    = "studio_test_x"
  ROOT  = "/tmp/wt"

  # One row of `ps -Ao pid=,pgid=,state=,lstart=,command=`.
  def process(pid:, pgid: nil, state: "S", started_at: OURS, command: "ruby bin/rails test")
    { pid: pid, pgid: pgid || pid, state: state, started_at: started_at, command: command }
  end

  # decide() is pure: hand it a lock and a process table, get a verdict.
  def decide(lock, table: [], self_pid: 100, self_pgid: 100)
    CertOrphanGuard.decide(lock: lock, table: table, self_pid: self_pid, self_pgid: self_pgid)
  end

  # A lock as CertProcess writes it: it records WHO, and — crucially — WHEN.
  def lock(cert_pid: 4242, pgid: 4300, cert_started_at: OURS, pgid_started_at: OURS, **extra)
    {
      "cert_pid" => cert_pid, "cert_started_at" => cert_started_at,
      "pgid" => pgid, "pgid_started_at" => pgid_started_at,
      "lane" => "spine", "db" => "studio_test_x", "started_at" => "2026-07-13T05:00:00Z"
    }.merge(extra)
  end

  # --- [unit] no lock at all ---------------------------------------------------

  def test_no_lock_is_a_clean_tree
    verdict, = decide(nil)
    assert_equal :none, verdict, "no prior cert ran here — nothing to reap or refuse"
  end

  # --- [unit] THE REGRESSION: a recycled pgid must NEVER be reaped --------------

  def test_a_recycled_pgid_is_never_graded_an_orphan
    # THE BUG, as the reviewer reproduced it. The lock is nine days old. Its cert is
    # long dead. The OS has since handed pgid 4300 to an unrelated process — a Chrome
    # helper, a language server, the operator's editor. It is ALIVE, so the old
    # predicate ("some process with this pgid is alive") graded it :orphan and killed
    # it.
    #
    # The start time is the tell, and the lock recorded it all along: our suite
    # started Mon Jul 13, this process started Wed Jul 9. Different process. Not ours.
    bystander = process(pid: 4300, started_at: OTHER, command: "/Applications/Chrome Helper")
    verdict, detail = decide(lock(cert_pid: 999_999), table: [bystander])

    refute_equal :orphan, verdict, "NEVER kill on liveness alone — a pgid is a recyclable integer"
    assert_equal :recycled, verdict, "proven NOT ours: the live process started at a different time"
    assert_equal 4300, detail[:pgid]
  end

  def test_the_recycled_verdict_clears_the_lock_rather_than_wedging_the_tree
    # Proven-not-ours is proof the suite is DEAD, so the lock is a corpse. Clear it and
    # let the cert run. Refusing here would wedge every cert in the worktree behind a
    # stranger's process — a safe kill is not enough, it must also not deadlock us.
    verdict, = decide(lock(cert_pid: 999_999), table: [process(pid: 4300, started_at: OTHER)])
    assert_equal :recycled, verdict
  end

  def test_a_recycled_CERT_pid_does_not_read_as_a_concurrent_cert
    # The same recyclable-integer bug, one field over, and nobody had looked at it:
    # cert_pid is graded on liveness too. A stale lock whose cert_pid the OS recycled
    # would grade :concurrent FOREVER — "another cert is already running" — wedging
    # every cert in the worktree behind a stranger that will never exit.
    #
    # Identity settles it: the live pid 4242 did not start when our cert did.
    stranger = process(pid: 4242, started_at: OTHER, command: "node /usr/lib/language-server")
    verdict, = decide(lock(pgid: 0), table: [stranger])

    refute_equal :concurrent, verdict, "a recycled cert_pid is not a concurrent cert"
    assert_equal :stale, verdict, "our cert is dead and no group survived — clear the lock and run"
  end

  # --- [unit] a LIVE cert in this tree: refuse, never kill ---------------------

  def test_a_live_cert_with_matching_identity_is_concurrent_and_we_refuse
    # The cert process is still alive AND is provably the one that wrote the lock → a
    # REAL concurrent cert (a second terminal, a sibling agent). Killing it would be
    # hostile, and running alongside it is the known "two suites on one worktree test
    # DB" hazard (it also SIGSEGVs Ruby). Refuse, loudly.
    verdict, detail = decide(lock, table: [process(pid: 4242, command: "ruby bin/fast-check")])

    assert_equal :concurrent, verdict
    assert_equal 4242, detail[:cert_pid]
  end

  # --- [unit] a DEAD cert whose suite lives on: THE ORPHAN, STILL REAPED --------

  def test_a_dead_cert_with_a_provably_ours_process_group_is_still_an_orphan
    # The fix must not over-correct into a reaper that never reaps. This is the
    # original bug and it must still be caught: the cert parent is gone (the harness
    # timeout killed it), its group leader `bin/rails test` survived with PPID 1 and is
    # holding the test DB, and its start time MATCHES what we recorded when we spawned
    # it. Provably ours. Reap it.
    verdict, detail = decide(lock(cert_pid: 999_999), table: [process(pid: 4300, started_at: OURS)])

    assert_equal :orphan, verdict
    assert_equal 4300, detail[:pgid]
    assert_equal OURS, detail[:pgid_started_at], "we reap on the identity we recorded, not on a bare number"
  end

  def test_start_time_matching_tolerates_the_ps_day_padding
    # `ps` space-pads the day-of-month ("Jul  9" vs "Jul 9"). A false MISMATCH here
    # would only ever make us refuse to kill — safe, but it would silently stop reaping
    # every orphan spawned on a single-digit day, which is a fine way to ship a reaper
    # that quietly does nothing for a third of every month.
    padded = process(pid: 4300, started_at: "Wed Jul  9 22:14:03 2026")
    verdict, = decide(lock(cert_pid: 999_999, pgid_started_at: "Wed Jul 9 22:14:03 2026"),
                      table: [padded])

    assert_equal :orphan, verdict, "same instant, different whitespace — the same process"
  end

  # --- [unit] identity we cannot establish: REFUSE, never guess ----------------

  def test_a_legacy_lock_with_no_recorded_identity_refuses_rather_than_killing
    # A lock written by the PREVIOUS version of this guard records a pgid and no start
    # time. Something is alive under that number. It might be our stranded suite; it
    # might be the operator's editor. We cannot tell — so we do not get to kill it.
    # Refuse, name what is alive, and let a human decide.
    verdict, detail = decide(lock(cert_pid: 999_999, cert_started_at: nil, pgid_started_at: nil),
                             table: [process(pid: 4300)])

    assert_equal :unverifiable, verdict
    assert_equal :group, detail[:subject]
  end

  def test_a_group_whose_leader_died_but_whose_members_live_is_unverifiable
    # The leader is gone, so there is no pid whose start time we can match against the
    # lock — the members are just processes that share a number with something we once
    # owned. Unprovable is unprovable: refuse and name them. (The test-DB backstop is
    # what catches this one in practice, and it names the holder without killing it.)
    worker = process(pid: 4311, pgid: 4300, command: "ruby bin/rails test (worker 2)")
    verdict, detail = decide(lock(cert_pid: 999_999), table: [worker])

    assert_equal :unverifiable, verdict
    refute_empty detail[:members]
  end

  def test_a_live_cert_pid_with_no_recorded_identity_refuses_rather_than_racing_it
    # Legacy lock, cert pid alive. It may be a real concurrent cert. Two suites on one
    # test DB is the hazard that SIGSEGVs Ruby, so the safe move is to refuse — never
    # to assume the pid was recycled and barge in.
    verdict, detail = decide(lock(cert_started_at: nil, pgid_started_at: nil),
                             table: [process(pid: 4242, command: "ruby bin/fast-check")])

    assert_equal :unverifiable, verdict
    assert_equal :cert, detail[:subject]
  end

  # --- [unit] the catastrophic groups: 1, 0, and our own -----------------------

  def test_a_lock_naming_process_group_1_is_never_reaped
    # `kill(sig, -1)` is not "process group 1". POSIX defines it as EVERY process the
    # caller may signal — the whole user session. The old reaper guarded the kill with
    # `pgid.positive?`, which admits 1, so a single truncated lock file stood between a
    # wedged cert and `kill -TERM -1`. Verified live: kill(0, -1) reports the group
    # EXISTS, so a real signal would have been delivered.
    verdict, detail = decide(lock(cert_pid: 999_999, pgid: 1, pgid_started_at: nil),
                             table: [process(pid: 1, command: "/sbin/launchd")])

    refute_equal :orphan, verdict, "we must never aim a signal at -1"
    assert_equal :unverifiable, verdict
    assert_equal :unsafe_pgid, detail[:subject]
  end

  def test_a_lock_naming_the_reapers_own_process_group_is_never_reaped
    # Suicide vector: a lock that names the group the CERT ITSELF is running in. The
    # old predicate would find it alive (of course it is — we are it), grade it
    # :orphan, and SIGKILL the whole group: the cert, its shell, the terminal.
    verdict, detail = decide(lock(cert_pid: 999_999, pgid: 100, pgid_started_at: nil),
                             table: [process(pid: 100, command: "ruby bin/fast-check")],
                             self_pid: 100, self_pgid: 100)

    refute_equal :orphan, verdict, "a cert must never reap the group it is running in"
    assert_equal :unsafe_pgid, detail[:subject]
  end

  def test_signalable_refuses_group_zero_one_and_our_own
    # The last line of defence lives next to the trigger, not only in the decision.
    refute CertOrphanGuard.signalable?(0, self_pid: 100, self_pgid: 100), "kill(sig, 0) hits our own group"
    refute CertOrphanGuard.signalable?(1, self_pid: 100, self_pgid: 100), "kill(sig, -1) hits EVERYTHING"
    refute CertOrphanGuard.signalable?(100, self_pid: 100, self_pgid: 100), "that is us"
    assert CertOrphanGuard.signalable?(4300, self_pid: 100, self_pgid: 100)
  end

  # --- [unit] a previous boot --------------------------------------------------

  def test_a_lock_from_a_previous_boot_cannot_match_and_is_never_reaped
    # The runlock is repo-relative: it survives reboots, which is what makes a recycled
    # pgid an EXPECTED condition rather than an exotic one. After a reboot every pid is
    # being handed out again from the start — and pgid 4300 is now something else.
    #
    # Start-time identity handles this for free, and provably: every process on this
    # side of the reboot started AFTER the reboot, so none of them can match a start
    # time we recorded before it.
    post_boot = process(pid: 4300, started_at: "Tue Jul 14 09:02:41 2026", command: "/usr/libexec/secd")
    verdict, = decide(lock(cert_pid: 999_999, pgid_started_at: "Mon Jul  6 18:40:11 2026"),
                      table: [post_boot])

    assert_equal :recycled, verdict, "nothing from before the reboot can still be running"
  end

  # --- [unit] a lock left by a cert that fully died: just stale ----------------

  def test_dead_cert_and_dead_group_is_a_stale_lock
    # Nothing survived: the lock is a relic (the whole group was reaped, or the machine
    # rebooted into an empty pid space). Clear it and carry on — never refuse a cert
    # over a corpse.
    verdict, = decide(lock(cert_pid: 999_999), table: [])
    assert_equal :stale, verdict
  end

  def test_a_zombie_is_a_corpse_not_an_orphan
    # A zombie answers signal 0 (its pid exists until someone reaps it) but holds no DB
    # connection and cannot be killed — it is already dead. Grading one :orphan makes
    # the reaper spin its full grace period on a corpse and then report a reap that
    # never happened.
    verdict, = decide(lock(cert_pid: 999_999), table: [process(pid: 4300, state: "Z")])
    assert_equal :stale, verdict
  end

  def test_a_dead_cert_with_no_pgid_recorded_cannot_prove_an_orphan_and_is_stale
    # Fail SAFE, not clever: the cert is dead, but with no group recorded there is
    # nothing we can prove is ours — so we must not kill anything on a guess. The
    # DB-backend probe is the backstop for exactly this case.
    verdict, = decide(lock(cert_pid: 999_999, pgid: 0), table: [process(pid: 4300)])
    assert_equal :stale, verdict
  end

  # --- [unit] the loud messages must NAME what they found ----------------------

  def test_orphan_message_names_the_db_the_pid_and_disclaims_the_diff
    msg = CertOrphanGuard.orphan_message(pgid: 4300, lane: "spine", db: "studio_test_x",
                                         started_at: "2026-07-13T05:00:00Z")

    assert_match(/4300/, msg, "the message must NAME the orphaned process group")
    assert_match(/studio_test_x/, msg, "the message must NAME the database it is holding")
    assert_match(/NOT a regression in your diff/, msg,
                 "an ENV-class failure must say so — this wave's convention")
  end

  def test_recycled_message_says_out_loud_that_it_did_NOT_kill_the_stranger
    # The operator must be able to see that the guard looked at a live process, proved
    # it was not ours, and LEFT IT ALONE. Silence here is how the old bug hid.
    msg = CertOrphanGuard.recycled_message(
      pgid: 4300, recorded_start: OURS,
      found: { pid: 4300, started_at: OTHER, command: "/Applications/Chrome Helper" }
    )

    assert_match(/NOT killing it/i, msg)
    assert_match(/Chrome Helper/, msg, "name the bystander we refused to kill")
    assert_match(/recycl/i, msg, "say WHY: the OS recycled the number")
  end

  def test_unverifiable_message_refuses_hands_over_the_commands_and_never_guesses
    msg = CertOrphanGuard.unverifiable_message(
      pgid: 4300, subject: :group, db: "studio_test_x", root: "/tmp/wt",
      members: [{ pid: 4311, started_at: OURS, command: "ruby bin/rails test" }]
    )

    assert_match(/REFUSING/, msg)
    assert_match(/4311/, msg, "name what is actually alive")
    assert_match(%r{rm /tmp/wt/tmp/cert-run\.json}, msg, "hand over the exact way to clear a stale lock")
    assert_match(/kill -TERM -4300/, msg, "and the exact way to reap it, if a HUMAN judges it stranded")
    assert_match(/NOT a regression in your diff/, msg)
  end

  def test_foreign_backend_message_hands_over_the_exact_kill_command
    msg = CertOrphanGuard.foreign_backend_message(
      db: "studio_test_x", backends: [{ pid: 46_382, application_name: "bin/rails" }]
    )

    assert_match(/46382/, msg, "name the PG backend pid")
    assert_match(/studio_test_x/, msg)
    assert_match(/pg_terminate_backend/, msg, "hand over the exact command that clears it")
    assert_match(/NOT a regression in your diff/, msg)
  end

  def test_concurrent_message_refuses_rather_than_killing_a_healthy_sibling
    msg = CertOrphanGuard.concurrent_message(cert_pid: 4242, lane: "spine", db: "studio_test_x")

    assert_match(/4242/, msg)
    refute_match(/kill -9 -4242/, msg, "we never hand out a group-kill for a LIVE cert")
    assert_match(/still running|in progress|wait/i, msg)
  end

  # --- [unit] the ps parser: identity is only as good as the field we read ------

  def test_ps_lines_parse_into_identity
    row = CertOrphanGuard.parse_ps_line("41578  41538 S    Mon Jul 13 05:00:00 2026 ruby bin/rails test test/x.rb")

    assert_equal 41_578, row[:pid]
    assert_equal 41_538, row[:pgid]
    assert_equal "Mon Jul 13 05:00:00 2026", row[:started_at]
    assert_equal "ruby bin/rails test test/x.rb", row[:command]
  end

  def test_an_unparseable_ps_line_yields_no_identity_and_therefore_no_kill
    assert_nil CertOrphanGuard.parse_ps_line("garbage")
    assert_nil CertOrphanGuard.parse_ps_line("")
  end

  # --- [unit] THE INVARIANT, ASSERTED ACROSS BOTH EMISSION LAYERS ------------------
  #
  # A guard emits a kill on TWO layers. It FIRES one (`signal_group`, `signal_pid`), and
  # it PRINTS one for a human to paste (`*_message`). The second cut of this file hardened
  # the first layer and left the second wide open (review, 2026-07-14): for a runlock
  # naming pgid 1, `unverifiable_message` rendered, verbatim,
  #
  #   If it IS a stranded suite:  kill -TERM -1
  #
  # — the exact POSIX catastrophe `MIN_SIGNALABLE_PGID` exists to prevent (`kill -TERM -1`
  # signals EVERY process the caller may signal), under the house's authoritative "here is
  # how to clear it" framing, addressed to an agent or to an operator 35 minutes into a
  # wedged cert. pgid 0 rendered `kill -TERM -0`: the reader's own process group. We had
  # stopped the PROGRAM from doing it and then told the HUMAN to do it by hand. A line whose
  # whole job is to be copy-pasted is not commentary — it is an instruction, and it needs
  # the same guard as the trigger.
  #
  # WHY IT SLIPPED, precisely: the message tests only ever rendered pgid 4300 — a SAFE
  # pgid. A test that never renders the dangerous vector cannot see the dangerous output.
  # So the fix is not a second guard bolted onto the copy (two guards drift, and that drift
  # IS this bug); it is ONE test asserting the POSITIVE invariant over BOTH layers at the
  # vectors that matter:
  #
  #   Every kill command this guard emits — FIRED or PRINTED — addresses a number that
  #   `signalable?` admits.

  # Every kill command in a blob of copy, as its TARGET: `kill -TERM -4300` → -4300,
  # `kill -9 4242` → 4242, `kill pid 4242` → 4242. Matched on the SHAPE OF THE COMMAND, not
  # on the strings this file happens to emit today — a blacklist of the spellings we thought
  # of is exactly how the copy path got missed the first time.
  KILL_IN_COPY = /\bkill(?:[ \t]+-\w+)*[ \t]+(?:pid[ \t]+)?(-?\d+)/

  def kill_targets_in(text)
    text.to_s.scan(KILL_IN_COPY).flatten.map(&:to_i)
  end

  # EVERY message this guard can emit, rendered at one pgid. If you add a message, add it
  # here: the invariant is a property of the FILE, not of the messages we remembered.
  def all_messages(pgid)
    found = { pid: pgid, started_at: OURS, command: "ruby bin/rails test" }
    # `reap_failed_message` is rendered against a world where the group IS provably ours —
    # its most kill-prone configuration, where the guard has every reason to print a kill
    # and ONLY the predicate stands between it and the copy. Rendering it on a world it
    # would refuse anyway would pass this test for the wrong reason.
    reap_failed = with_stub(CertOrphanGuard, :process_table,
                            [process(pid: pgid, pgid: pgid, started_at: OURS)]) do
      CertOrphanGuard.reap_failed_message(pgid: pgid, lane: "spine", db: DB, root: ROOT,
                                          reason: :survived, started_at: OURS)
    end

    %i[cert group unsafe_pgid].map do |subject|
      CertOrphanGuard.unverifiable_message(pgid: pgid, subject: subject, found: found,
                                           members: [found], db: DB, root: ROOT)
    end + [
      CertOrphanGuard.orphan_message(pgid: pgid, lane: "spine", db: DB, started_at: OURS),
      CertOrphanGuard.orphan_vanished_message(pgid: pgid, lane: "spine", db: DB),
      CertOrphanGuard.recycled_message(pgid: pgid, found: found, recorded_start: OURS),
      reap_failed,
      CertOrphanGuard.concurrent_message(cert_pid: pgid, lane: "spine", db: DB),
      CertOrphanGuard.malformed_message(root: ROOT, db: DB),
      CertOrphanGuard.foreign_backend_message(db: DB, url: "postgres://localhost/#{DB}",
                                              backends: [{ pid: pgid, application_name: "bin/rails" }])
    ]
  end

  # A stub without `minitest/mock`: this file promises a standalone run (`ruby -Itest
  # test/lib/cert_orphan_guard_test.rb`), and the ambient minitest there is not necessarily
  # the bundled one — minitest 6 does not ship the mock library at all.
  def with_stub(receiver, name, value)
    original = receiver.method(name)
    receiver.define_singleton_method(name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  # Every kill the guard FIRES at `pgid`, with `Process.kill` stubbed so nothing actually
  # dies and the raw targets are visible. The process table is forged so identity grades
  # :ours — that is, the guard has every reason to kill, and ONLY `signalable?` stands
  # between it and the trigger. (Anything less and the test passes for the wrong reason.)
  def kill_targets_fired(pgid)
    fired = []
    table = [process(pid: pgid, pgid: pgid, started_at: OURS)]
    with_stub(Process, :kill, ->(_signal, target) { fired << target.to_i }) do
      with_stub(CertOrphanGuard, :process_table, table) do
        CertOrphanGuard.signal_group(pgid, "TERM")
        CertOrphanGuard.signal_pid(pgid, "KILL")
        CertOrphanGuard.reap_group(pgid, started_at: OURS, grace: 0.0)
      end
    end
    fired
  end

  def assert_only_signalable_kills(pgid, what)
    printed = all_messages(pgid).flat_map { |message| kill_targets_in(message) }
    fired = kill_targets_fired(pgid)

    (printed + fired).each do |target|
      assert CertOrphanGuard.signalable?(target.abs),
             "the guard emits `kill ... #{target}` at #{what} — a number it would REFUSE to signal. " \
             "`kill -TERM -1` signals EVERY process the caller owns; `kill -TERM -0` signals the " \
             "reader's own process group. A kill we refuse to FIRE is a kill we must refuse to PRINT."
    end
  end

  def test_no_kill_the_guard_emits_in_code_or_in_copy_targets_an_unsignalable_pgid
    assert_only_signalable_kills(0, "process group 0 (the reader's OWN process group)")
    assert_only_signalable_kills(1, "process group 1 (EVERY process the caller owns)")
    assert_only_signalable_kills(Process.getpgrp, "the cert's OWN process group")
  end

  # --- [unit] THE SHARED-PREDICATE INVARIANT ---------------------------------------------
  #
  # `signalable?` — the invariant above — is only the WEAKER half. It says the NUMBER is
  # safe to aim at; it says NOTHING about whether what answers to it is OURS. The reaper
  # gated its trigger on `signalable? AND identity`, while the copy gated its Clear: line on
  # `signalable?` ALONE — so a group the reaper had PROVEN was a stranger, and refused to
  # touch, was still handed to the operator as `Clear: kill -KILL -4300`. Three rounds of
  # review missed it because the test above only ever rendered that message on a group that
  # WAS ours, where the two predicates happen to agree.
  #
  # The fix is not a second guard that agrees with the first by convention. It is ONE
  # predicate — `reapable?` — asked by both emitters. This test asserts exactly that: over a
  # matrix of worlds, WHATEVER `reapable?` says, the trigger and the copy both obey it. Two
  # predicates that must agree WILL drift; one predicate cannot.
  def assert_emitters_obey_the_predicate(pgid:, leader_start:, recorded:, why:)
    table = leader_start ? [process(pid: pgid, pgid: pgid, started_at: leader_start)] : []
    fired = []
    reapable = nil
    printed = nil

    with_stub(Process, :kill, ->(_signal, target) { fired << target.to_i }) do
      with_stub(CertOrphanGuard, :process_table, table) do
        reapable = CertOrphanGuard.reapable?(pgid, recorded)
        CertOrphanGuard.reap_group(pgid, started_at: recorded, grace: 0.0)
        printed = kill_targets_in(
          CertOrphanGuard.reap_failed_message(pgid: pgid, lane: "spine", db: DB, root: ROOT,
                                              reason: :survived, started_at: recorded)
        )
      end
    end

    if reapable
      refute_empty fired, "reapable? admits #{why}, so the reaper must actually FIRE at it"
      refute_empty printed, "reapable? admits #{why}, so the honest remediation IS a kill — print it"
    else
      assert_empty fired,
                   "the guard SIGNALLED a group `reapable?` REFUSES: #{why}"
      assert_empty printed,
                   "the guard PRINTED `kill ... #{printed.first}` at a group `reapable?` REFUSES: #{why}. " \
                   "The code just established this is not ours — and then told a tired operator to kill it. " \
                   "A command we would refuse to FIRE is a command we must refuse to PRINT."
    end
  end

  def test_both_emitters_obey_the_one_shared_predicate
    # THE RACE the re-proof exists for (cert_orphan_guard.rb:456-458): the leader was
    # provably ours when `decide` read the table, then exited, and the OS handed its number
    # to a stranger before the trigger fired. This is the vector that shipped the bug.
    assert_emitters_obey_the_predicate(
      pgid: 4300, leader_start: OTHER, recorded: OURS,
      why: "a PROVEN STRANGER holding a recycled pgid (identity :not_ours)"
    )
    # A lock with no recorded identity (a legacy lock, or a `ps` that returned nothing at
    # spawn). Unprovable is not ownership, and we never kill on a guess.
    assert_emitters_obey_the_predicate(
      pgid: 4300, leader_start: OURS, recorded: nil,
      why: "a group whose identity was never recorded (identity :unprovable)"
    )
    # Nothing alive under the number at all: nothing to fire at, nothing to print.
    assert_emitters_obey_the_predicate(
      pgid: 4300, leader_start: nil, recorded: OURS,
      why: "a group that is already gone (:absent)"
    )
    # The catastrophic numbers, with identity forged to match — so ONLY the predicate stands
    # between the guard and `kill -TERM -1`.
    [0, 1, Process.getpgrp].each do |pgid|
      assert_emitters_obey_the_predicate(
        pgid: pgid, leader_start: OURS, recorded: OURS,
        why: "the unsignalable group #{pgid}, whose identity MATCHES"
      )
    end
    # THE POSITIVE HALF. A predicate that refuses everything is not a guard, it is a brick.
    # A real group, provably ours, that outlived TERM+KILL: the kill is honest — fire it AND
    # print it.
    assert_emitters_obey_the_predicate(
      pgid: 4300, leader_start: OURS, recorded: OURS,
      why: "a real group 4300 that is PROVABLY ours"
    )
  end

  def test_a_signalable_group_still_gets_the_kill_commands_it_needs
    # The invariant is a GATE, not a gag. Deleting every kill command would satisfy the test
    # above perfectly and leave an operator wedged with no way out — so assert the other half:
    # a REAL group still gets a real reap command, printed and fired.
    copy = all_messages(4300).join("\n")

    assert_includes copy, "kill -TERM -4300", "a stranded suite in a real group still gets its reap command"
    assert_includes copy, "kill -KILL -4300", "and the escalation, when TERM did not do it"
    assert_includes kill_targets_fired(4300), -4300, "and the guard still FIRES at a group it proved is ours"
  end

  def test_the_unsafe_pgid_refusal_offers_only_rm_and_never_greps_for_1
    msg = CertOrphanGuard.unverifiable_message(
      pgid: 1, subject: :unsafe_pgid, db: DB, root: ROOT,
      members: [{ pid: 4311, started_at: OURS, command: "ruby bin/rails test" }]
    )

    assert_empty kill_targets_in(msg),
                 "THE BUG: the guard refused to FIRE `kill -TERM -1` and then PRINTED it. " \
                 "A lock naming group 1 is garbage by construction — no cert ever ran in group 1 — " \
                 "so there is no stranded suite behind it and nothing a kill could correctly do."
    assert_match(%r{rm /tmp/wt/tmp/cert-run\.json}, msg, "the ONLY correct remediation: discard the garbage lock")
    assert_match(/garbage by construction|nothing to reap/i, msg, "and say WHY no kill is offered")
    refute_match(/grep -E 'rails test\|1'/, msg,
                 "`grep -E 'rails test|1'` matches nearly every line of ps (every pid/ppid/pgid with a 1 " \
                 "in it) — the whole process table handed back as suspects: noise dressed as evidence")
    assert_match(/grep -E 'rails test'/, msg, "the grep still finds a stranded suite by NAME")

    # A CORRUPT lock is not an IDENTITY GAP, and the copy must not confuse the two. This
    # message used to borrow the :cert/:group prose wholesale: it blamed a missing identity
    # ("does not carry the identity needed to prove those processes are ours… A human
    # decides") and then listed "Alive now: pid 4311 (…)" — a process that merely SHARES
    # group 1 and is DEFINITIONALLY NOT OURS — naming it as a target underneath a refusal
    # that says there is nothing to reap. Copy asserting more than the code can prove: the
    # same drift class as printing a kill we refuse to fire, one message over.
    refute_match(/Alive now/, msg,
                 "a lock naming group 0/1 names NOBODY — whatever shares that group is definitionally " \
                 "not ours, so the refusal must not parade it as a target")
    refute_match(/#{4311}/, msg, "…and specifically must not name the bystander it was handed")
    refute_match(/identity needed to prove|A human decides/, msg,
                 "the lock is STRUCTURALLY INVALID, not unverifiable — there is exactly one remedy, so " \
                 "there is no decision to hand a human and no identity gap to blame")
  end

  # --- [unit] a malformed lock names nobody, so it kills nobody --------------------

  # THE ONE PREDICATE MUST NOT CRASH ON GARBAGE. `signalable?` guarded with `pgid.to_i`,
  # and `Hash#to_i` is a NoMethodError — so `{"pgid": {}}`, a lock a half-flushed SIGKILLed
  # cert can genuinely leave, could make the single gate that stands between this guard and
  # `kill -TERM -1` RAISE instead of refuse. Every in-tree caller happens to be guarded by
  # coerce_pid one frame up, which is exactly the argument this file rejects: the last line
  # of defence belongs next to the trigger, not in the caller that happens to check today.
  # A guard that dies on garbage has no opinion about garbage. Garbage is not signalable.
  def test_signalable_refuses_garbage_instead_of_raising
    [{}, [], "not-a-pid", nil, "", Object.new].each do |garbage|
      refute CertOrphanGuard.signalable?(garbage),
             "signalable?(#{garbage.inspect}) must REFUSE — it is not a pid, and the predicate that " \
             "gates every kill in this file must never raise on input a corrupt lock can hold"
    end

    # …and it stays semantics-preserving for everything valid.
    assert CertOrphanGuard.signalable?(4300), "a real group is still signalable"
    assert CertOrphanGuard.signalable?("4300"), "…including one that came out of JSON as a string"
    refute CertOrphanGuard.signalable?(0), "0 is the reader's own group"
    refute CertOrphanGuard.signalable?(1), "1 is init — and every process we own"
    refute CertOrphanGuard.signalable?(Process.getpgrp), "never our own group"
    refute CertOrphanGuard.signalable?(Process.pid), "never our own pid"
  end

  def test_a_malformed_lock_is_graded_not_raised
    # `{"pgid": {}}` — a truncated write, a hand-edit, a half-flushed file from a SIGKILLed
    # cert. `Hash#to_i` is a NoMethodError, and a guard that CRASHES on a malformed lock has
    # no opinion about malformed locks: it takes the cert down with a backtrace naming
    # neither the lock nor the orphan, which is the blind-retry loop all over again.
    [
      { "cert_pid" => 4242, "pgid" => {} },          # the vector from review
      { "cert_pid" => 4242, "pgid" => "not-a-pid" },
      { "cert_pid" => [4242], "pgid" => 4300 },
      { "cert_pid" => nil, "pgid" => 4300 }
    ].each do |garbage|
      verdict, = decide(garbage, table: [process(pid: 4300)])

      assert_equal :malformed, verdict, "a lock that names nobody: #{garbage.inspect}"
    end
  end

  def test_a_numeric_string_is_still_a_pid
    # JSON is not typed and this lock is written by more than one tool over time. Refusing a
    # perfectly good `"4300"` would strand a REAL orphan behind a "malformed" verdict.
    verdict, detail = decide({ "cert_pid" => "999999", "pgid" => "4300",
                               "cert_started_at" => OURS, "pgid_started_at" => OURS },
                             table: [process(pid: 4300, started_at: OURS)])

    assert_equal :orphan, verdict
    assert_equal 4300, detail[:pgid]
  end

  def test_preflight_discards_a_malformed_lock_loudly_and_does_not_wedge_the_cert
    # Refusing on a malformed lock would wedge every cert in the tree behind a corrupt FILE
    # with zero evidence of a live suite — a gate asserting rather than evidencing, which is
    # the disease this whole task exists to treat. Say it out loud, discard it, and let the
    # DB backstop speak for a real orphan on real evidence.
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "tmp"))
      lock = CertOrphanGuard.lock_path(root)
      File.write(lock, JSON.generate("cert_pid" => 4242, "pgid" => {}))

      verdict, notices = CertOrphanGuard.preflight(root: root, env: { "CERT_GUARD_PSQL" => "/nonexistent" })

      assert_equal :ok, verdict, "a corrupt file is not evidence of a live suite"
      assert_match(/MALFORMED RUNLOCK/, notices.join("\n"), "never discard it silently")
      assert_empty kill_targets_in(notices.join("\n")), "it names nobody, so it may not suggest killing anybody"
      refute_path_exists lock, "the garbage lock is cleared, not left to refuse the next cert too"
    end
  end

  # --- [unit] the unwedge command must connect the way the PROBE connected ----------

  def test_the_psql_command_dials_the_url_the_probe_used_not_a_bare_db_name
    # `foreign_backends` dials the full TEST_DATABASE_URL. Printing `psql studio_test_x`
    # tells the operator to dial a bare name — which resolves ONLY where DATABASE_URL is a
    # default local socket with a matching role. Anywhere else (a non-default port, a host,
    # CI) the handed-over fix fails with an auth error, at the exact moment they are 35
    # minutes deep and trusting us.
    url = "postgres://alex@localhost:5433/#{DB}"
    msg = CertOrphanGuard.foreign_backend_message(db: DB, url: url,
                                                  backends: [{ pid: 46_382, application_name: "bin/rails" }])

    assert_match(/psql #{Regexp.escape(url)} -c/, msg, "dial exactly what the probe dialed")
    assert_match(/pg_terminate_backend/, msg)
  end

  def test_a_password_in_the_test_db_url_is_never_printed_into_a_cert_log
    # A cert log is a durable artefact that gets pasted into PRs and task records. House
    # rule, no exceptions: never print a secret.
    msg = CertOrphanGuard.foreign_backend_message(
      db: DB, url: "postgres://user:hunter2@db.example.com:5432/#{DB}",
      backends: [{ pid: 46_382, application_name: "bin/rails" }]
    )

    refute_match(/hunter2/, msg, "a password must never reach a cert log")
    assert_match(/REDACTED/, msg, "and the operator must be TOLD it was redacted, not left to wonder")
  end

  def test_no_url_falls_back_to_the_db_name
    msg = CertOrphanGuard.foreign_backend_message(db: DB, url: nil,
                                                  backends: [{ pid: 46_382, application_name: "bin/rails" }])

    assert_match(/psql #{DB} -c/, msg, "best effort beats no command at all")
  end

  # --- [unit] the post-reap SETTLE grace ------------------------------------------
  #
  # THE PATH THAT HAD NO TEST. `grep -rn 'settle_backends\|settle:' test/` found NOTHING
  # before this block — which is precisely how the bug below survived three review rounds
  # and a green CI.
  #
  # The bug (shipped by the tri-state rework, review round 6): `preflight` initialised
  # `reaped = false`, the tri-state conversion renamed the reap's assignment target to
  # `outcome`, and nobody reassigned `reaped`. So `settle: reaped` was ALWAYS false, the
  # grace loop was unreachable, and after a SUCCESSFUL, proven-ours reap the backstop
  # probed pg_stat_activity instantly, saw the just-killed suite's backend still closing,
  # and REFUSED — handing the operator a pg_terminate_backend aimed at the corpse of the
  # suite it had reaped one millisecond earlier. Rubocop cannot see it (the variable IS
  # read) and CI cannot see it (it self-heals on the next retry, so nothing goes red).
  # A cert naming its own corpse as a stranger, in the file whose whole thesis is
  # "evidence, not assertion".
  #
  # A backend does not close the instant its process dies, so the grace is REQUIRED for
  # correctness; but it must never become a blanket delay that lets a REAL foreign
  # session through. Both halves are asserted here.

  # A psql stand-in that models the linger: it reports a backend for the first
  # `linger_calls` probes and none after, and records how many times it was dialled —
  # so a test can prove the grace RE-PROBED rather than merely returning a lucky value.
  def psql_stub(dir, linger_calls:)
    counter = File.join(dir, "psql-calls")
    script  = File.join(dir, "psql-stub")
    File.write(script, <<~SH)
      #!/bin/sh
      n=$(cat #{counter.shellescape} 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > #{counter.shellescape}
      [ "$n" -le #{linger_calls} ] && echo "77777|bin/rails"
      exit 0
    SH
    FileUtils.chmod(0o755, script)
    [script, counter]
  end

  def psql_calls(counter)
    File.exist?(counter) ? File.read(counter).strip.to_i : 0
  end

  # VIRTUAL time for the settle loop — the fix for a whole family of false reds.
  #
  # These tests used to assert on `Time.now` deltas, which does not measure this loop;
  # it measures the BOX. Under a full-suite run with sibling agent sessions on the same
  # machine the clean-DB fast path measured 1.32s against a `< 1s` bound and red-failed
  # a cert whose code was correct — three times on one task, ~45 minutes of cert time.
  # The reverse error was live too: on an idle box a `< 1s` bound would have waved
  # through a 0.5s sleep the fast path must never take.
  #
  # So the clock is injected instead. `sleeper` records each requested duration AND
  # advances the clock by it, so the loop's real deadline arithmetic runs unchanged
  # while the test spends no wall time and reads nothing machine-global. Assert on
  # `slept` — the sleeps ARE the property.
  def virtual_time
    now = 0.0
    slept = []
    clock = -> { now }
    sleeper = lambda do |seconds|
      slept << seconds
      now += seconds
    end
    [clock, sleeper, slept]
  end

  def test_settle_off_takes_the_first_answer_and_never_waits
    # The default for every verdict that did NOT just reap our own suite. Anything alive
    # on our test DB then is somebody ELSE's, and a stranger gets NO grace period — it
    # gets named, now.
    Dir.mktmpdir do |dir|
      psql, counter = psql_stub(dir, linger_calls: 1)

      backends = CertOrphanGuard.settle_backends("postgres://x@localhost/#{DB}", psql: psql, settle: false)

      assert_equal [77_777], backends.map { |b| b[:pid] }, "the stranger is reported on the FIRST probe"
      assert_equal 1, psql_calls(counter), "settle: false must not re-probe — no waiting on a foreign session"
    end
  end

  def test_settle_re_probes_until_our_own_reaped_backend_closes
    # THE REGRESSION. With the grace live, the closing backend of the suite we just
    # reaped drains and the cert proceeds. Under the shipped bug this returned the
    # backend from probe #1 and the cert refused on its own corpse.
    Dir.mktmpdir do |dir|
      psql, counter = psql_stub(dir, linger_calls: 1)
      clock, sleeper, _slept = virtual_time

      backends = CertOrphanGuard.settle_backends("postgres://x@localhost/#{DB}", psql: psql,
                                                 settle: true, grace: 2.0,
                                                 clock: clock, sleeper: sleeper)

      assert_empty backends, "our own reaped suite's backend closes — it must not be reported as a stranger"
      assert_operator psql_calls(counter), :>, 1, "the grace must RE-PROBE; one probe means the loop never ran"
    end
  end

  def test_the_grace_still_reports_a_backend_that_never_closes
    # The other half, and the reason the grace is BOUNDED. A settle window must not become
    # a way to wave through a genuine foreign session (a sibling cert, a stray `bin/rails
    # test`, a psql someone left open) just because we happened to reap something first.
    # It waits, it re-probes, and then it names what is STILL there.
    Dir.mktmpdir do |dir|
      psql, counter = psql_stub(dir, linger_calls: 99)
      clock, sleeper, slept = virtual_time

      backends = CertOrphanGuard.settle_backends("postgres://x@localhost/#{DB}", psql: psql,
                                                 settle: true, grace: 0.6,
                                                 clock: clock, sleeper: sleeper)

      assert_equal [77_777], backends.map { |b| b[:pid] }, "a session that never closes is STILL reported"
      assert_operator psql_calls(counter), :>, 1, "it re-probed before giving its verdict"
      # Bounded by the grace plus at most ONE sleep quantum — the loop tests the deadline
      # BEFORE sleeping, so it can overshoot by one 0.2s step and no more. The old
      # `elapsed < 5` was eight times looser than the real bound AND load-dependent.
      assert_operator slept.sum, :<, 0.6 + 0.2, "the wait is BOUNDED by the grace — a cert may not hang here"
    end
  end

  def test_a_clean_db_never_sleeps_even_with_settle_on
    # The fast path: nothing to settle, so nothing to wait for. A 2s tax on every clean
    # cert would be paid forever by every agent in the fleet.
    #
    # THE FALSE RED THIS FILE IS NAMED FOR. This assertion used to read `elapsed < 1`
    # off the wall clock, so it passed or failed on how busy the OPERATOR'S BOX was:
    # measured at 0.3s alone and 1.32s under a full-suite run with sibling sessions
    # live, it red-failed correct certs. `slept` asserts the same claim — "never paid
    # the grace" — against this loop alone, and is immune to every other process.
    Dir.mktmpdir do |dir|
      psql, counter = psql_stub(dir, linger_calls: 0)
      clock, sleeper, slept = virtual_time

      backends = CertOrphanGuard.settle_backends("postgres://x@localhost/#{DB}", psql: psql,
                                                 settle: true, clock: clock, sleeper: sleeper)

      assert_empty backends
      assert_equal 1, psql_calls(counter), "one probe answered it; do not go round the loop"
      assert_empty slept, "a clean DB must not pay the grace — not one sleep"
    end
  end
end
