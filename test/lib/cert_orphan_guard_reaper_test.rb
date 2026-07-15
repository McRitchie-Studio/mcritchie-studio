# frozen_string_literal: true

# Integration tests for the REAPER — the part of CertOrphanGuard that pulls a trigger.
#
# The unit tests reason about a synthetic process table. These spawn REAL processes in
# REAL process groups and let the guard decide their fate, because the finding that
# blocked this PR was not a reasoning error the unit tests could have caught by
# thinking harder — the old suite thought about pid reuse and argued its way past it.
# It was a claim about what the code DOES when it meets a live process it does not own.
# So we put a live process in front of it and look.
#
# Two obligations, and the fix is only real if BOTH hold:
#
#   1. It must NOT kill a bystander. A pgid is a recyclable integer and the runlock is
#      repo-relative (it outlives reboots), so "the pgid in this lock now belongs to
#      somebody else" is an EXPECTED state, not an exotic one. The reviewer reproduced
#      it live: the guard TERM/KILLed an unrelated process and reported "ORPHAN REAPED".
#
#   2. It must STILL kill a genuine orphan. A reaper that never reaps is not a fix —
#      the original bug (a wedged cert stranding `bin/rails test` on the test DB for
#      35 minutes) is real, and this PR exists to reap it.
#
# Run directly:  ruby -Itest test/lib/cert_orphan_guard_reaper_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "shellwords"
require_relative "../../bin/lib/cert_orphan_guard"

class CertOrphanGuardReaperTest < Minitest::Test
  # No psql, no TEST_DATABASE_URL: the DB backstop is a separate concern and we do not
  # want it refusing on this box's real databases while we are testing the reaper.
  NO_DB_ENV = { "CERT_GUARD_PSQL" => "/nonexistent/psql" }.freeze

  def setup
    @root = Dir.mktmpdir("cert-orphan-guard")
    @spawned = []
  end

  def teardown
    @spawned.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    FileUtils.rm_rf(@root)
  end

  # A real process, in a process group of its very own — exactly how CertProcess spawns
  # a cert lane, and therefore exactly what a recycled pgid lands on.
  #
  # `Process.detach` is load-bearing, not tidiness. These are our own children, so once
  # the guard kills one it becomes a ZOMBIE — and a zombie answers signal 0 for as long
  # as nobody reaps it, so `alive?` below would report a successfully-killed orphan as
  # alive forever and red this suite against a guard that did its job. (The guard is not
  # fooled: it reads the process table and skips state Z. That asymmetry is exactly why
  # `alive?` is a poor definition of alive, which is the moral of this entire file.)
  # Detaching hands the reaping to a Ruby thread, so a dead child really does vanish.
  def spawn_group(command = "sleep 30")
    pid = Process.spawn(command, pgroup: true, out: File::NULL, err: File::NULL)
    @spawned << pid
    pgid = Process.getpgid(pid)
    started_at = CertOrphanGuard.process_started_at(pid)
    Process.detach(pid)
    [pid, pgid, started_at]
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until_dead(pid, timeout: 5.0)
    deadline = Time.now + timeout
    sleep 0.05 while alive?(pid) && Time.now < deadline
    !alive?(pid)
  end

  # Make the reap FAIL. Hand-rolled rather than minitest/mock, because this file must
  # also run standalone (`ruby -Itest ...`), where minitest/mock is not on the path.
  #
  # `:survived` — we PROVED the group was ours, signalled TERM then KILL, and it outlived
  # us (an unkillable process, stuck in an uninterruptible syscall). NOT `:refused`: that
  # is the other failure, where we never signalled at all because we could not prove
  # ownership. They get opposite remediations, so the fixture must say which one it means.
  def with_a_reap_that_fails(outcome = :survived)
    original = CertOrphanGuard.method(:reap_group)
    CertOrphanGuard.define_singleton_method(:reap_group) { |*_args, **_kwargs| outcome }
    yield
  ensure
    CertOrphanGuard.define_singleton_method(:reap_group, original)
  end

  # --- [integration] THE BUG: the guard must not murder a bystander -------------

  def test_it_refuses_to_kill_a_process_that_merely_INHERITED_the_pgid
    # Shannon's reproduction, permanently. A live, unrelated process — and a runlock,
    # days old, whose long-dead cert happened to hold the number the OS has since
    # handed to it. The old guard graded this :orphan on "something with this pgid is
    # alive" and killed it.
    #
    # We fabricate the recorded start time (the lock claims our suite started days
    # before this process existed), which is precisely what a recycled pgid looks like.
    bystander, bygid, real_start = spawn_group
    refute_nil real_start, "ps must give us the OS's start-time record — identity depends on it"

    CertOrphanGuard.write_lock(@root, cert_pid: 999_999, pgid: bygid,
                               cert_started_at: "Mon Jul  6 18:40:11 2026",
                               pgid_started_at: "Mon Jul  6 18:40:11 2026",
                               lane: "spine", db: "studio_test_x",
                               now: Time.now - (9 * 86_400))

    verdict, notices = CertOrphanGuard.preflight(root: @root, env: NO_DB_ENV)
    sleep 0.3 # give a kill, if one were coming, every chance to land

    assert alive?(bystander),
           "THE BLOCKING BUG: the guard killed an innocent process whose only crime was " \
           "being handed a recycled pgid (#{bygid})"
    assert_equal :ok, verdict, "a stranger's process must not wedge our cert either"
    assert_match(/NOT killing it/i, notices.join(" "), "and it must say out loud that it refused")
    refute_path_exists CertOrphanGuard.lock_path(@root), "the stale lock is a corpse — clear it"
  end

  def test_reap_group_itself_refuses_an_identity_it_cannot_match
    # The trigger, called directly. Even if a caller hands it a pgid, the reaper
    # re-proves ownership at the kill site — the proof must be adjacent to the trigger,
    # because between a decision and a signal a leader can exit and its number be
    # handed on.
    bystander, bygid, = spawn_group

    assert_equal :refused, CertOrphanGuard.reap_group(bygid, started_at: "Mon Jul  6 18:40:11 2026"),
                 "an unproven group must not be signalled"
    sleep 0.2
    assert alive?(bystander), "the bystander survives a reaper that cannot name it"
  end

  def test_reap_group_refuses_a_nil_identity
    # A lock with no recorded start time (one written by the previous version of this
    # guard, or by a `ps` that returned nothing at spawn) can prove nothing. It must reap
    # nothing — and it must say `:refused`, NOT `:absent`. Those two both used to be
    # `false`, and the caller that cleared the runlock on `false` deleted the only record
    # naming a live process it had just declined to kill.
    bystander, bygid, = spawn_group

    assert_equal :refused, CertOrphanGuard.reap_group(bygid, started_at: nil)
    sleep 0.2
    assert alive?(bystander)
  end

  def test_reap_group_reports_absent_when_there_is_simply_nothing_to_reap
    # THE TRI-STATE'S WHOLE REASON TO EXIST. A group that has already exited is not a
    # refusal — there is nothing there. This is what EVERY CLEAN CERT looks like at its
    # ensure block, so a caller that treats it as a refusal strands a stale runlock behind
    # every successful run. `:absent` and `:refused` must never collapse back into `false`.
    dead, deadgid, started_at = spawn_group
    Process.kill("KILL", dead)

    assert wait_until_dead(dead), "the group is gone before we ask"
    assert_equal :absent, CertOrphanGuard.reap_group(deadgid, started_at: started_at)
    assert CertOrphanGuard.reap_cleared?(:absent), "nothing to reap → the lock may go"
    refute CertOrphanGuard.reap_cleared?(:refused), "a refusal KEEPS the lock — it names the process"
    refute CertOrphanGuard.reap_cleared?(:survived), "a survivor KEEPS the lock too"
  end

  # --- [integration] the catastrophic groups ------------------------------------

  def test_reap_group_never_aims_at_group_1_or_0_or_its_own
    # `kill(sig, -1)` means EVERY process the caller may signal. If the reaper would
    # address it, this test process — and the suite running it — would be among the
    # dead. That it REFUSES (rather than taking us all down) IS the assertion.
    assert_equal :refused,
                 CertOrphanGuard.reap_group(1, started_at: CertOrphanGuard.process_started_at(1))
    assert_equal :refused, CertOrphanGuard.reap_group(0, started_at: nil)
    assert_equal :refused,
                 CertOrphanGuard.reap_group(Process.getpgrp,
                                            started_at: CertOrphanGuard.process_started_at(Process.getpgrp))
    assert alive?(Process.pid), "we are, gratifyingly, still here"
  end

  # --- [integration] and it MUST still reap a real orphan ------------------------

  def test_it_still_reaps_a_genuine_orphan_process_group
    # The over-correction check. The original bug is real: a cert killed by its harness
    # strands `bin/rails test` on the worktree test DB and every retry dies in
    # test-prepare. This is that suite — a real process group, and a runlock recording
    # the identity CertProcess would have recorded when it spawned it (its TRUE start
    # time), whose cert is dead.
    #
    # Provably ours. It dies.
    orphan, pgid, started_at = spawn_group

    CertOrphanGuard.write_lock(@root, cert_pid: 999_999, pgid: pgid,
                               cert_started_at: "Mon Jul  6 18:40:11 2026",
                               pgid_started_at: started_at,
                               lane: "spine", db: "studio_test_x")

    verdict, notices = CertOrphanGuard.preflight(root: @root, env: NO_DB_ENV)

    assert_equal :ok, verdict
    assert wait_until_dead(orphan), "a genuine orphan MUST still be reaped — this PR exists to reap it"
    assert_match(/ORPHAN REAPED/, notices.join(" "))
    assert_match(/#{pgid}/, notices.join(" "), "and it must NAME the group it killed")
    refute_path_exists CertOrphanGuard.lock_path(@root)
  end

  def test_it_reaps_the_whole_GROUP_not_just_the_leader
    # The group is the unit that matters: the suite forks (parallel workers, a `sh -c`
    # wrapper), and killing only the leader strands the rest of them on the DB — which
    # is the failure this whole file exists to prevent. The leader here spawns a child
    # and exits its shell into it, so the group has more than one member.
    leader, pgid, started_at = spawn_group("sh -c 'sleep 30 & sleep 30'")
    sleep 0.4 # let the child land in the group

    members = CertOrphanGuard.group_members(CertOrphanGuard.process_table, pgid).map { |p| p[:pid] }
    assert_operator members.size, :>=, 2, "the fixture must actually have a group with members"

    CertOrphanGuard.write_lock(@root, cert_pid: 999_999, pgid: pgid, pgid_started_at: started_at)
    CertOrphanGuard.preflight(root: @root, env: NO_DB_ENV)

    assert wait_until_dead(leader), "the leader dies"
    members.each do |pid|
      assert wait_until_dead(pid), "every member of the group dies — a survivor keeps holding the test DB"
    end
  end

  # --- [integration] never report a kill we did not perform ----------------------

  def test_a_FAILED_reap_refuses_instead_of_claiming_ORPHAN_REAPED
    # The old code discarded reap_group's return value and printed "ORPHAN REAPED ...
    # Continuing with a clean test DB" even when the reap had failed — then failed
    # closed anyway on the DB backstop, leaving the operator a contradictory
    # ORPHAN REAPED + REFUSING pair. A cert that reports a kill it did not perform is
    # asserting rather than evidencing, which is the disease this whole wave is about.
    #
    # The orphan is real and provably ours; the reap fails (the process is unkillable —
    # stuck in an uninterruptible syscall, say).
    orphan, pgid, started_at = spawn_group

    CertOrphanGuard.write_lock(@root, cert_pid: 999_999, pgid: pgid,
                               pgid_started_at: started_at, lane: "spine", db: "studio_test_x")

    verdict, message = with_a_reap_that_fails do
      CertOrphanGuard.preflight(root: @root, env: NO_DB_ENV)
    end

    assert_equal :refuse, verdict, "an orphan still holding the test DB must not be waved through"
    refute_match(/ORPHAN REAPED/, message, "NEVER claim a kill that did not happen")
    assert_match(/could NOT reap/i, message, "say what actually happened")
    assert_match(/#{pgid}/, message, "and NAME the process that is still holding the DB")
    assert_path_exists CertOrphanGuard.lock_path(@root),
                       "the lock is kept on purpose — it is the only record naming the process"
    assert alive?(orphan)
  end

  # --- [integration] a live cert is refused, never killed ------------------------

  def test_a_live_concurrent_cert_is_refused_and_left_running
    # The lock names a cert process that is genuinely alive and genuinely ours (this
    # very test process, with its true start time). Two suites against one worktree test
    # DB corrupt each other's fixtures and SIGSEGV Ruby. Refuse — and do not kill it.
    CertOrphanGuard.write_lock(@root, cert_pid: Process.pid, pgid: 999_999,
                               cert_started_at: CertOrphanGuard.process_started_at(Process.pid),
                               pgid_started_at: nil, lane: "spine")

    verdict, message = CertOrphanGuard.preflight(root: @root, env: NO_DB_ENV)

    assert_equal :refuse, verdict
    assert_match(/another cert is already running/i, message)
    assert alive?(Process.pid), "we most certainly did not kill ourselves"
  end

  # --- [integration] identity, end to end ----------------------------------------

  def test_a_live_process_reports_a_stable_start_time_and_a_dead_one_reports_none
    # The whole fix rests on this: the OS gives us a start time, it does not drift
    # between reads, and it disappears with the process. If any of that were false the
    # guard would be verifying identity against noise.
    pid, = spawn_group

    first = CertOrphanGuard.process_started_at(pid)
    sleep 1.1 # cross a second boundary — a drifting clock would show up here
    refute_nil first
    assert_equal first, CertOrphanGuard.process_started_at(pid), "identity must not drift between reads"

    Process.kill("KILL", pid)
    assert wait_until_dead(pid)
    assert_nil CertOrphanGuard.process_started_at(999_999), "a pid that names nothing has no identity"
  end

  # --- [integration] the post-reap SETTLE grace, through the real preflight -----------
  #
  # A PG backend does not close the instant its process is killed, so between the reap and
  # the DB backstop there is a window in which the suite we JUST PROVED was ours and JUST
  # KILLED is still sitting in pg_stat_activity. Probe inside that window with no grace and
  # the cert refuses, naming its own corpse as a foreign session and handing the operator a
  # pg_terminate_backend aimed at it — while DISCARDING the ORPHAN REAPED notice (notices
  # are dropped on :refuse). That is what shipped: `reaped` was initialised false and never
  # reassigned after the tri-state rework, so `settle:` was always false and the grace was
  # dead code. Neither rubocop nor CI could see it. These tests can.
  #
  # A REAL process group, a REAL reap, a stubbed psql modelling the linger.

  # psql that reports a backend for the first `linger_calls` probes and none after, and
  # counts its own invocations — so we can prove the grace RE-PROBED.
  def psql_stub(linger_calls:)
    counter = File.join(@root, "psql-calls")
    script  = File.join(@root, "psql-stub")
    File.write(script, <<~SH)
      #!/bin/sh
      n=$(cat #{counter.shellescape} 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > #{counter.shellescape}
      [ "$n" -le #{linger_calls} ] && echo "77777|bin/rails"
      exit 0
    SH
    FileUtils.chmod(0o755, script)
    { "CERT_GUARD_PSQL" => script,
      "TEST_DATABASE_URL" => "postgres://alex@localhost:5432/studio_test_wt" }
  end

  def psql_calls
    counter = File.join(@root, "psql-calls")
    File.exist?(counter) ? File.read(counter).strip.to_i : 0
  end

  def test_a_reaped_suites_lingering_backend_is_waited_out_not_named_as_a_stranger
    # THE REGRESSION, end to end. Genuine orphan, provably ours, reaped — and its backend
    # still closing when the backstop first looks.
    orphan, pgid, started_at = spawn_group
    CertOrphanGuard.write_lock(@root, cert_pid: 999_999, pgid: pgid, pgid_started_at: started_at,
                               lane: "spine", db: "studio_test_wt")

    verdict, notices = CertOrphanGuard.preflight(root: @root, env: psql_stub(linger_calls: 1))

    assert_equal :ok, verdict,
                 "THE BUG: the cert reaped its own orphan and then REFUSED on that orphan's " \
                 "closing backend — reporting the suite it had just killed as a foreign session"
    assert wait_until_dead(orphan), "the orphan really was reaped — this is not a vacuous pass"
    assert_match(/ORPHAN REAPED/, notices.join(" "), "and the reap notice SURVIVES (it is dropped on :refuse)")
    assert_operator psql_calls, :>, 1, "the grace must RE-PROBE; a single probe means the loop never ran"
  end

  def test_an_orphan_that_dies_before_our_signal_gets_the_same_grace
    # :absent — the group `decide` graded ORPHAN exited on its own between the snapshot and
    # the trigger. We killed nothing, but the corpse is just as much OURS, and its backend
    # lingers exactly the same way. Gating the grace on :reaped ALONE leaves this identical
    # defect live on the sibling path, so the predicate is reap_cleared? (:reaped OR :absent).
    _orphan, pgid, started_at = spawn_group
    CertOrphanGuard.write_lock(@root, cert_pid: 999_999, pgid: pgid, pgid_started_at: started_at)

    verdict, notices = with_a_reap_that_fails(:absent) do
      CertOrphanGuard.preflight(root: @root, env: psql_stub(linger_calls: 1))
    end

    assert_equal :ok, verdict, "our own vanished suite's closing backend must not refuse the cert either"
    assert_operator psql_calls, :>, 1, "the :absent path re-probes too"
    refute_match(/ORPHAN REAPED/, notices.join(" "), "and it still claims NO kill it did not make")
  end

  def test_a_run_that_reaped_NOTHING_gives_a_foreign_backend_no_grace_at_all
    # The other half — the mutation that "fixes" the bug by passing settle: true always.
    # A stranger on our test DB (a sibling cert, a stray `bin/rails test`) is refused on
    # the FIRST probe: we never reaped anything, so nothing here is our corpse, and nobody
    # gets a waiting period. A blanket grace would tax every cert AND soften the backstop.
    verdict, message = CertOrphanGuard.preflight(root: @root, env: psql_stub(linger_calls: 99))

    assert_equal :refuse, verdict, "a foreign session holding the test DB still refuses the cert"
    assert_match(/77777/, message.to_s, "and it NAMES the session")
    assert_equal 1, psql_calls, "no reap happened, so no grace is owed — refuse on the first probe"
  end
end
