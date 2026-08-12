# frozen_string_literal: true

require "test_helper"

# THE RACE, RUN FOR REAL — two Postgres connections settling one armed merge at
# the same instant.
#
# WHY THIS FILE EXISTS SEPARATELY. The unit tests around #settle! prove the RULE
# ("a settled action is never re-settled") on the schedules a single connection
# can express. They cannot tell a conditional `UPDATE … WHERE state = 'pending'`
# apart from an in-Ruby `return false unless pending?`, because on one connection
# both behave identically. The whole reason the conditional UPDATE was chosen is
# that the two DIVERGE under real concurrency — so the claim has to be tested
# where it diverges, or it is a claim about code nobody has run.
#
# The executor's claim lock is DELIBERATELY released before its GitHub round trip
# (holding it would pin one Postgres connection per in-flight merge against a
# 20-connection pool — the limit this ecosystem has already blown once), so two
# jobs really can both pass `pending?` and both arrive at the write. This is that
# moment, with the database actually arbitrating it.
#
# TRANSACTIONAL FIXTURES ARE OFF HERE, and they have to be: Rails pins one shared
# connection for a transactional test, so two threads would serialise on it and
# the race would be a fiction. The cost is manual cleanup, which #teardown does.
class ReviewPendingActionSettleRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  SLUG = "settle-race-subject"
  REPO = "McRitchie-Studio/mcritchie-studio"
  SHA  = "5ec0ffee5ec0ffee5ec0ffee5ec0ffee5ec0ffee"
  MERGE_SHA = "merged00merged00merged00merged00merged00"

  def setup
    cleanup!
    @task = Task.create!(title: "Settle Race Subject", slug: SLUG, stage: "submitted")
    Activity.create!(task_slug: SLUG, agent_slug: "carl", activity_type: "comment",
                     description: "Scout report: merge-ready",
                     metadata: { "kind" => "scout_report", "outcome" => "merge-ready" })
  end

  def teardown
    cleanup!
  end

  # CLEAN UP EVERYTHING, INCLUDING WHAT THE CALLBACKS WROTE. Transactional fixtures
  # are off here, so every row below is really COMMITTED and this method is the only
  # thing that removes it. `Task.create!` fires `after_create :record_genesis_event`,
  # which writes a TaskEvent — and `delete_all` skips callbacks AND `dependent:
  # :destroy`, so deleting the task ORPHANS that event rather than taking it along.
  # `task_events` has no fixture, so nothing else in the harness ever cleans it: the
  # orphan survived into every later test in the process and eventually reddened
  # test/integration/test_database_hermeticity_test.rb, on the orderings that put it
  # last. That cost three sessions. The children go first, explicitly.
  def cleanup!
    ReviewPendingAction.where(task_slug: SLUG).delete_all
    Activity.where(task_slug: SLUG).delete_all
    TaskEvent.where(task_slug: SLUG).delete_all
    Task.where(slug: SLUG).delete_all
  end

  def arm(head_sha: SHA)
    ReviewPendingAction.arm!(task: @task.reload, repo: REPO, pr_number: 314, head_sha: head_sha)
  end

  # Run a block on its OWN database connection. Thread#join re-raises, so a
  # failed assertion inside a thread fails the test instead of vanishing.
  def on_own_connection(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end

  # Block until Postgres reports a backend blocked BY THIS ONE — a positive signal
  # that the other connection is genuinely parked inside its UPDATE, rather than a
  # sleep hoping it got there.
  #
  # TWO TRAPS ARE ENCODED IN THIS QUERY, both of which cost real runs to find:
  #
  #   pg_stat_activity IS A CACHED SNAPSHOT. Its contents are frozen for the
  #   duration of a transaction (`stats_fetch_consistency`), and this poll runs
  #   INSIDE the lock holder's transaction — so a wait that begins after the first
  #   poll never appears, and the loop spins until it times out. It failed 4 runs
  #   in 8 that way. `pg_locks` and `pg_blocking_pids()` read the live lock
  #   manager instead, and see the block the moment it happens.
  #
  #   A ROW LOCK IS NOT A pg_locks ROW. Row-level locks live in the tuple itself,
  #   so the waiter appears as an ungranted `transactionid` lock whose `database`
  #   column is NULL — and the obvious `JOIN pg_database` to scope it to this test
  #   database silently drops exactly the row being looked for.
  #
  # Asking "who is blocked BY ME" sidesteps both, and is immune to a parallel test
  # worker's unrelated contention elsewhere in the same cluster.
  def wait_for_blocked_writer!(connection, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until connection.select_value(<<~SQL).to_i.positive?
      SELECT count(*)
      FROM (SELECT DISTINCT pid FROM pg_locks WHERE NOT granted) AS waiters
      WHERE pg_backend_pid() = ANY(pg_blocking_pids(waiters.pid))
    SQL
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk("no second writer ever blocked on the row lock — the race was not set up")
      end
      sleep 0.01
    end
    true
  end

  # Join every thread, and never leave one running into teardown — a live thread
  # would be writing to rows cleanup! is deleting, turning one clear failure into
  # a confusing second one.
  def join_all!(threads, label)
    threads.each { |thread| thread.join(15) || flunk("a settle thread deadlocked #{label}") }
  ensure
    threads.each { |thread| thread.kill if thread.alive? }
  end

  # ── THE DETERMINISTIC PROOF ────────────────────────────────────────────────
  #
  # No sleeps and no luck: one connection holds the row's write lock while the
  # other tries to settle it, so the interleave is pinned by Postgres rather than
  # by the scheduler.

  test "[integration] the DATABASE arbitrates the settle — a blocked writer loses and writes nothing" do
    action = arm
    holder_has_lock = Queue.new
    loser_result = nil

    winner = on_own_connection do |connection|
      ReviewPendingAction.transaction do
        # SELECT … FOR UPDATE: from here until this transaction commits, any other
        # connection's UPDATE of this row must WAIT.
        locked = ReviewPendingAction.lock.find(action.id)
        holder_has_lock << true
        # Only settle once the other connection is PROVABLY parked in its UPDATE.
        wait_for_blocked_writer!(connection)
        locked.settle!(state: ReviewPendingAction::EXECUTED, reason: "merged", merge_sha: MERGE_SHA)
      end
    end

    loser = on_own_connection do
      holder_has_lock.pop
      # Reads are never blocked, so this row still looks pending — exactly the
      # stale read the executor holds after releasing its claim lock. The UPDATE
      # then blocks, and when the winner commits, Postgres RE-EVALUATES the
      # `WHERE state = 'pending'` predicate against the new row version: it no
      # longer matches, so this writer updates nothing. That re-evaluation is the
      # entire mechanism, and it is the database's, not the application's.
      loser_result = ReviewPendingAction.find(action.id).settle!(
        state: ReviewPendingAction::REFUSED, reason: "task is reviewed, not submitted"
      )
    end

    join_all!([winner, loser], "on the deterministic race")

    action.reload
    assert_equal ReviewPendingAction::EXECUTED, action.state,
                 "the merge that happened must survive the refusal that arrived after it"
    assert_equal MERGE_SHA, action.merge_sha, "a recorded merge sha is never nulled by a retry"
    assert_equal "merged", action.outcome_reason
    refute loser_result, "the blocked writer must be TOLD it wrote nothing, not silently ignored"
  end

  # ── THE UNSCHEDULED PROOF ──────────────────────────────────────────────────
  #
  # The same collision with nobody arranging the order: both threads race into the
  # write. Whoever wins is fine — what must NEVER happen is a MIXED row, the
  # self-contradictory record this whole task exists to prevent (state REFUSED
  # carrying the merger's sha, or state EXECUTED carrying the refuser's blank).
  #
  # Repeated, because one pass of a race proves nothing. An in-Ruby `unless
  # pending?` check in place of the conditional UPDATE fails this within a few
  # rounds; two winners is the observable tell.

  test "[integration] twenty simultaneous double-settles never produce a mixed row" do
    20.times do |round|
      action = arm(head_sha: SecureRandom.hex(20))
      gate = Queue.new
      winners = Queue.new

      threads = [
        [ReviewPendingAction::EXECUTED, "merged", MERGE_SHA],
        [ReviewPendingAction::REFUSED, "task is reviewed, not submitted", nil]
      ].map do |state, reason, sha|
        on_own_connection do
          row = ReviewPendingAction.find(action.id)
          gate.pop # both threads are parked here until the barrier opens
          winners << state if row.settle!(state: state, reason: reason, merge_sha: sha)
        end
      end

      2.times { gate << :go }
      join_all!(threads, "in round #{round}")

      assert_equal 1, winners.size, "round #{round}: exactly one settle may win"
      won = winners.pop

      action.reload
      assert_equal won, action.state, "round #{round}: the row must read what the WINNER wrote"
      if won == ReviewPendingAction::EXECUTED
        assert_equal MERGE_SHA, action.merge_sha, "round #{round}: an executed row keeps its sha"
      else
        assert_nil action.merge_sha, "round #{round}: a refused row never carries the merger's sha"
        assert_equal "task is reviewed, not submitted", action.outcome_reason
      end

      action.destroy!
    end
  end
end
