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

  # ── THE CREATE RACE, PINNED TO THE HALF THAT USED TO RAISE ─────────────────
  #
  # The unscheduled create race below reaches this bug only by luck — which is
  # exactly how it shipped, and how it then reddened an unrelated PR's CI at
  # random. `find_or_create_by!` issues three statements, and a rival's commit can
  # land in either gap:
  #
  #   1. SELECT … WHERE lane = ?           ← find_or_create_by!'s lookup, misses
  #      ─ gap A ─                           rival commits HERE → step 2 sees it
  #   2. SELECT 1 … WHERE lane = ? LIMIT 1 ← the uniqueness VALIDATOR's read
  #      ─ gap B ─                           rival commits HERE → step 3 collides
  #   3. INSERT …                          ← the unique index fires
  #
  # Gap B raises RecordNotUnique; gap A raises RecordInvalid from the validator.
  # The original rescue named only the former, so a loser that arrived through gap
  # A RAISED out of `acquire` — from the one method whose entire job is to answer
  # "someone else holds it". This test pins gap A instead of waiting for it: a
  # before_validation hook is the only seam between statements 1 and 2, so the
  # rival commits there, on its own connection, every single run.

  # Run the rival's FULL acquire inside the loser's gap A, and join it, so the
  # loser's validator provably reads a COMMITTED rival claim. The latch matters:
  # the rival's own create! re-enters this same callback, and a per-thread flag
  # would let it recurse until the connection pool drained.
  def with_rival_committing_in_gap_a(session:, task_slug:, agent:)
    latch = Mutex.new
    fired = false
    # ActiveSupport instance_execs a proc callback against the RECORD, so `self`
    # inside the hook is a MigrationLaneClaim, not this test. Hold the test case.
    test_case = self
    hook = lambda do |record|
      next unless record.new_record?
      next unless latch.synchronize { fired ? false : (fired = true) }

      rival = test_case.on_own_connection do
        MigrationLaneClaim.acquire(session: session, nonce: session.downcase, task_slug: task_slug, agent: agent)
      end
      rival.join(15) || test_case.flunk("the rival never committed its claim inside gap A")
    end
    MigrationLaneClaim.set_callback(:validation, :before, hook)
    yield
  ensure
    MigrationLaneClaim.skip_callback(:validation, :before, hook, raise: false)
  end

  test "[integration] a first-acquirer that loses the create race is REFUSED, not raised" do
    assert_equal 0, MigrationLaneClaim.count, "gap A only exists when no row is there yet"

    outcome = with_rival_committing_in_gap_a(session: "A", task_slug: "add-widgets-table", agent: "carl") do
      MigrationLaneClaim.acquire(session: "B", nonce: "b", task_slug: "add-gizmos-table", agent: "jasper")
    end

    refute outcome.acquired, "the loser of the CREATE race must be refused, not granted the lane"
    assert_equal :held_by_other, outcome.disposition,
                 "the loser must be told the lane is held — that verdict is the whole feature"

    assert_equal 1, MigrationLaneClaim.where(lane: LANE).count, "the lane stays a singleton"
    row = MigrationLaneClaim.find_by!(lane: LANE)
    assert_equal "A", row.claimed_session, "the lane belongs to the rival that committed first"
    assert_equal "add-widgets-table", row.task_slug, "the loser's task never overwrites the holder's"
  end

  # The guard must be narrow. A validation failure that is NOT the uniqueness
  # collision has to keep raising — otherwise the fix trades a loud bug for a
  # silent one, handing back a row the caller never asked for.
  test "[integration] an unrelated validation failure on the lane still raises" do
    error = assert_raises(ActiveRecord::RecordInvalid) { MigrationLaneClaim.claim_row("   ") }
    assert_equal [:blank], error.record.errors.details[:lane].map { |detail| detail[:error] },
                 "a blank lane is a caller bug, not a create race"
    assert_equal 0, MigrationLaneClaim.count, "nothing may be created for an invalid lane"
  end

  # The lane is a SINGLETON. Racing the very first acquire (no row yet) must not
  # produce two rows — `claim_row` tolerates the uniqueness collision and the
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
