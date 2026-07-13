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
# The decision table below is PURE: it takes a lock record + a liveness probe and
# returns what the cert should DO. Nothing here reads the clock, the process table,
# or the DB — so the policy is testable without spawning anything.
#
# Run directly:  ruby -Itest test/lib/cert_orphan_guard_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/cert_orphan_guard"

class CertOrphanGuardTest < Minitest::Test
  # `alive` is the injected liveness probe: a Set of pids/pgids considered alive.
  def decide(lock, alive: [])
    live = ->(id) { alive.include?(id) }
    CertOrphanGuard.decide(lock: lock, alive: live)
  end

  # --- [unit] no lock at all ---------------------------------------------------

  def test_no_lock_is_a_clean_tree
    verdict, = decide(nil)
    assert_equal :none, verdict, "no prior cert ran here — nothing to reap or refuse"
  end

  # --- [unit] a LIVE cert in this tree: refuse, never kill ---------------------

  def test_live_cert_parent_means_a_concurrent_cert_and_we_refuse
    # The cert process itself is still alive → a REAL concurrent cert is running in
    # this worktree (a second terminal, a sibling agent). Killing it would be
    # hostile, and running alongside it is the known "two suites on one worktree
    # test DB" hazard (it also SIGSEGVs Ruby). Refuse, loudly.
    lock = { "cert_pid" => 4242, "pgid" => 4242, "lane" => "spine", "started_at" => "2026-07-13T05:00:00Z" }
    verdict, detail = decide(lock, alive: [4242])

    assert_equal :concurrent, verdict
    assert_equal 4242, detail[:cert_pid]
  end

  # --- [unit] a DEAD cert whose suite lives on: THE ORPHAN ---------------------

  def test_dead_cert_parent_with_a_live_process_group_is_an_orphan
    # This is the bug. The cert parent is gone (the harness timeout killed it) but
    # its process GROUP still has members — the `bin/rails test` grandchild holding
    # the test DB. We can PROVE this is our own abandoned cert, so we may reap it.
    lock = { "cert_pid" => 4242, "pgid" => 4300, "lane" => "spine", "started_at" => "2026-07-13T05:00:00Z" }
    verdict, detail = decide(lock, alive: [4300])

    assert_equal :orphan, verdict
    assert_equal 4300, detail[:pgid], "the orphan is identified by its PROCESS GROUP, not one pid"
  end

  def test_orphan_verdict_never_depends_on_the_dead_parent_being_reused
    # A pgid that is alive while the cert pid is dead is an orphan even if some
    # unrelated process later recycles the parent's pid number — we key the reap on
    # the GROUP, and the group is what holds the DB.
    lock = { "cert_pid" => 999_999, "pgid" => 4300 }
    verdict, = decide(lock, alive: [4300])
    assert_equal :orphan, verdict
  end

  # --- [unit] a lock left by a cert that fully died: just stale ----------------

  def test_dead_cert_and_dead_group_is_a_stale_lock
    # Nothing survived: the lock is a relic (e.g. the whole group was reaped, or the
    # machine rebooted). Clear it and carry on — never refuse a cert over a corpse.
    lock = { "cert_pid" => 4242, "pgid" => 4300 }
    verdict, = decide(lock, alive: [])
    assert_equal :stale, verdict
  end

  def test_a_dead_cert_with_no_pgid_recorded_cannot_prove_an_orphan_and_is_stale
    # Fail SAFE, not clever: the cert is dead, but with no group recorded there is
    # nothing we can prove is ours — so we must not kill anything on a guess. The
    # DB-backend probe is the backstop for exactly this case.
    lock = { "cert_pid" => 4242 }
    verdict, = decide(lock, alive: [4300]) # 4300 is alive, but the lock never named it
    assert_equal :stale, verdict
  end

  # --- [unit] the loud messages must NAME the orphan --------------------------

  def test_orphan_message_names_the_db_the_pid_and_disclaims_the_diff
    msg = CertOrphanGuard.orphan_message(pgid: 4300, lane: "spine", db: "studio_test_x", started_at: "2026-07-13T05:00:00Z")

    assert_match(/4300/, msg, "the message must NAME the orphaned process group")
    assert_match(/studio_test_x/, msg, "the message must NAME the database it is holding")
    assert_match(/NOT a regression in your diff/, msg,
                 "an ENV-class failure must say so — this wave's convention")
  end

  def test_foreign_backend_message_hands_over_the_exact_kill_command
    msg = CertOrphanGuard.foreign_backend_message(db: "studio_test_x", backends: [{ pid: 46_382, application_name: "bin/rails" }])

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
end
