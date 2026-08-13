# frozen_string_literal: true

require "test_helper"

# THE LANE'S ONE PROMISE, RUN FOR REAL — several Postgres connections reaching for
# the `backend_migration` lane at the same instant.
#
# WHY THIS FILE EXISTS SEPARATELY. The unit tests in
# test/models/migration_lane_claim_test.rb prove the RULE ("a second live agent is
# refused") on the schedules a single connection can express. They cannot tell an
# atomic compare-and-set apart from a plain in-Ruby `return false if held?`,
# because on ONE connection both behave identically. The lane's entire value is
# that two Devs cannot both hold it, and that claim diverges only under real
# concurrency — so it has to be tested where it diverges, or it is a claim about
# code nobody has run.
#
# This is not hypothetical for this lane. The mechanism it REPLACED —
# `pg_try_advisory_lock` on a pooled connection — grants the SAME connection the
# lock twice (advisory locks are re-entrant), so the predecessor would have failed
# exactly this test while passing every single-connection test written about it.
# A lane that grants twice is worse than no lane, because the docs then promise
# protection nobody has.
#
# TRANSACTIONAL FIXTURES ARE OFF HERE, and they have to be: Rails pins one shared
# connection for a transactional test, so the threads would serialise on it and
# the race would be a fiction. The cost is manual cleanup, which #teardown does.
class MigrationLaneExclusionRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  LANE = Task::MIGRATION_LANE

  def setup
    cleanup!
  end

  def teardown
    cleanup!
  end

  # Transactional fixtures are off, so these rows are really COMMITTED and this is
  # the only thing that removes them. MigrationLaneClaim has no children and no
  # after_create hooks, so the single delete_all is the whole cleanup.
  def cleanup!
    MigrationLaneClaim.delete_all
  end

  # Run a block on its OWN database connection. Thread#join re-raises, so a failed
  # assertion inside a thread fails the test instead of vanishing.
  def on_own_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  # Block until Postgres reports a backend blocked BY THIS ONE — a positive signal
  # that the other connection is genuinely parked on the row lock, rather than a
  # sleep hoping it got there. (`pg_locks` + `pg_blocking_pids` rather than
  # `pg_stat_activity`, which is a per-transaction cached snapshot and cannot see
  # a wait that starts after the first poll.)
  def wait_for_blocked_writer!(connection, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until connection.select_value(<<~SQL).to_i.positive?
      SELECT count(*)
      FROM (SELECT DISTINCT pid FROM pg_locks WHERE NOT granted) AS waiters
      WHERE pg_backend_pid() = ANY(pg_blocking_pids(waiters.pid))
    SQL
      flunk("no second acquirer ever blocked on the row lock — the race was not set up") if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    true
  end

  def join_all!(threads, label)
    threads.each { |thread| thread.join(15) || flunk("a lane thread deadlocked #{label}") }
  ensure
    threads.each { |thread| thread.kill if thread.alive? }
  end

  # Seed the singleton row in a FREE state, so both racers contend for one
  # existing row rather than racing the create.
  def seed_free_row!
    MigrationLaneClaim.acquire(session: "seed", nonce: "seed", task_slug: "seed")
    MigrationLaneClaim.release(session: "seed", nonce: "seed")
  end

  # ── THE DETERMINISTIC PROOF ────────────────────────────────────────────────
  #
  # No sleeps and no luck: one connection holds the claim row's write lock while
  # the other tries to acquire, so the interleave is pinned by Postgres rather
  # than by the scheduler. The loser's `with_lock` must park, then RE-READ the
  # winner's committed claim and refuse — that re-read is the entire mechanism.

  test "[integration] the DATABASE arbitrates the lane — a blocked acquirer is refused" do
    seed_free_row!
    holder_has_lock = Queue.new
    loser_outcome = nil

    winner = on_own_connection do |connection|
      MigrationLaneClaim.transaction do
        row = MigrationLaneClaim.lock.find_by!(lane: LANE)
        holder_has_lock << true
        # Only claim once the other connection is PROVABLY parked in its lock wait.
        wait_for_blocked_writer!(connection)
        row.update!(claimed_session: "A", claim_nonce: "a", task_slug: "add-widgets-table",
                    holder_agent: "carl", acquired_at: Time.current,
                    claim_expires_at: Time.current + MigrationLaneClaim::DEFAULT_TTL_SECONDS)
      end
    end

    loser = on_own_connection do
      holder_has_lock.pop
      loser_outcome = MigrationLaneClaim.acquire(session: "B", nonce: "b", task_slug: "add-gizmos-table",
                                                 agent: "jasper")
    end

    join_all!([winner, loser], "on the deterministic race")

    refute loser_outcome.acquired, "the blocked acquirer must be REFUSED, not granted a second copy of the lane"
    assert_equal :held_by_other, loser_outcome.disposition

    row = MigrationLaneClaim.find_by!(lane: LANE)
    assert_equal "A", row.claimed_session, "the lane belongs to the connection that committed first"
    assert_equal "add-widgets-table", row.task_slug, "the loser's task never overwrites the holder's"
    assert_equal "carl", row.holder_agent
  end

  # ── THE UNSCHEDULED PROOF ──────────────────────────────────────────────────
  #
  # The same collision with nobody arranging the order: three threads race into
  # `acquire` on a free lane. Whoever wins is fine — what must NEVER happen is two
  # winners, which is the whole failure this lane exists to prevent.
  #
  # Repeated, because one pass of a race proves nothing.

  test "[integration] fifteen three-way races grant the lane exactly once each time" do
    15.times do |round|
      cleanup!
      seed_free_row!
      gate = Queue.new
      winners = Queue.new

      threads = %w[A B C].map do |session|
        on_own_connection do
          gate.pop # every thread parks here until the barrier opens
          outcome = MigrationLaneClaim.acquire(session: session, nonce: session.downcase,
                                               task_slug: "migration-#{session.downcase}", agent: session)
          winners << session if outcome.acquired
        end
      end

      3.times { gate << :go }
      join_all!(threads, "in round #{round}")

      assert_equal 1, winners.size, "round #{round}: exactly one agent may hold the migration lane"
      won = winners.pop

      row = MigrationLaneClaim.find_by!(lane: LANE)
      assert_equal won, row.claimed_session, "round #{round}: the row must read what the WINNER wrote"
      assert_equal "migration-#{won.downcase}", row.task_slug,
                   "round #{round}: a loser must not smear its task over the winner's claim"
      assert row.live?, "round #{round}: the granted lane is live"
    end
  end

  # The lane is a SINGLETON. Racing the very first acquire (no row yet) must not
  # produce two rows — `claim_row` rescues the unique-index violation and the
  # loser re-reads the winner's row, so the unique index is load-bearing here.
  test "[integration] racing the FIRST acquire creates exactly one lane row" do
    10.times do |round|
      cleanup!
      gate = Queue.new
      winners = Queue.new

      threads = %w[A B C].map do |session|
        on_own_connection do
          gate.pop
          outcome = MigrationLaneClaim.acquire(session: session, nonce: session.downcase,
                                               task_slug: "first-#{session.downcase}")
          winners << session if outcome.acquired
        end
      end

      3.times { gate << :go }
      join_all!(threads, "in create-race round #{round}")

      assert_equal 1, MigrationLaneClaim.where(lane: LANE).count,
                   "round #{round}: the lane must have exactly one row"
      assert_equal 1, winners.size, "round #{round}: a create race must still grant the lane once"
    end
  end
end
