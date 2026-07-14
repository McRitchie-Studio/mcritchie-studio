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
  def with_a_reap_that_fails
    original = CertOrphanGuard.method(:reap_group)
    CertOrphanGuard.define_singleton_method(:reap_group) { |*_args, **_kwargs| false }
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

    refute CertOrphanGuard.reap_group(bygid, started_at: "Mon Jul  6 18:40:11 2026"),
           "an unproven group must not be signalled"
    sleep 0.2
    assert alive?(bystander), "the bystander survives a reaper that cannot name it"
  end

  def test_reap_group_refuses_a_nil_identity
    # A lock with no recorded start time (one written by the previous version of this
    # guard) can prove nothing. It must reap nothing.
    bystander, bygid, = spawn_group

    refute CertOrphanGuard.reap_group(bygid, started_at: nil)
    sleep 0.2
    assert alive?(bystander)
  end

  # --- [integration] the catastrophic groups ------------------------------------

  def test_reap_group_never_aims_at_group_1_or_0_or_its_own
    # `kill(sig, -1)` means EVERY process the caller may signal. If the reaper would
    # address it, this test process — and the suite running it — would be among the
    # dead. That it returns false (rather than taking us all down) IS the assertion.
    refute CertOrphanGuard.reap_group(1, started_at: CertOrphanGuard.process_started_at(1))
    refute CertOrphanGuard.reap_group(0, started_at: nil)
    refute CertOrphanGuard.reap_group(Process.getpgrp,
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
end
