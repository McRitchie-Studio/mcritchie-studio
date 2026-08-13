# frozen_string_literal: true

require "test_helper"

# The `backend_migration` lane's rules, on the schedules ONE connection can
# express. The property that needs two connections — that a genuine race grants
# the lane exactly once — is proved in
# test/integration/migration_lane_exclusion_race_test.rb, because a single
# connection cannot tell a real compare-and-set apart from a lucky one.
class MigrationLaneClaimTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 8, 12, 9, 0, 0)

  def acquire(session:, nonce:, task_slug: nil, label: nil, agent: nil, now: NOW)
    MigrationLaneClaim.acquire(session: session, nonce: nonce, task_slug: task_slug,
                               label: label, agent: agent, now: now)
  end

  test "[unit] the first agent takes a free lane" do
    outcome = acquire(session: "A", nonce: "a", task_slug: "add-widgets-table", agent: "carl")

    assert outcome.acquired
    assert_equal :unclaimed, outcome.disposition
    assert_equal "add-widgets-table", outcome.claim.task_slug
    assert_equal Task::MIGRATION_LANE, outcome.claim.lane
  end

  # THE RULE THE LANE EXISTS FOR, in its single-connection form.
  test "[unit] a second live agent is refused and told who holds the lane" do
    acquire(session: "A", nonce: "a", task_slug: "add-widgets-table", agent: "carl")
    outcome = acquire(session: "B", nonce: "b", task_slug: "add-gizmos-table", agent: "jasper")

    refute outcome.acquired, "two Devs must never both hold the migration lane"
    assert_equal :held_by_other, outcome.disposition
    assert_equal "add-widgets-table", outcome.claim.task_slug, "the refusal names the task to chase for an ETA"
    assert_equal "carl", outcome.claim.holder_agent
  end

  # The refusal is keyed on the HOLDING INSTANCE, not the task: a second session
  # on the same task is still a second Dev writing migrations at the same time.
  test "[unit] the same task from a second session is still refused" do
    acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")
    outcome = acquire(session: "B", nonce: "b", task_slug: "add-widgets-table")

    refute outcome.acquired
    assert_equal :held_by_other, outcome.disposition
  end

  test "[unit] the holder re-acquiring renews without resetting when it took the lane" do
    first = acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")
    acquired_at = first.claim.acquired_at

    later = acquire(session: "A", nonce: "a", now: NOW + 60)

    assert later.acquired
    assert_equal :same_instance, later.disposition
    assert_equal acquired_at.to_i, later.claim.acquired_at.to_i, "a renewal keeps the original acquire time"
    assert_equal "add-widgets-table", later.claim.task_slug, "a renewal keeps the holder's own task"
    assert_equal (NOW + 60 + MigrationLaneClaim::DEFAULT_TTL_SECONDS).to_i, later.claim.claim_expires_at.to_i
  end

  # A crashed holder must not wedge the lane forever — the question the brief
  # asked directly. Nothing renews this lease, so the TTL is the whole answer.
  test "[unit] a lapsed lease frees the lane for the next agent" do
    acquire(session: "A", nonce: "a", task_slug: "add-widgets-table", agent: "carl")

    outcome = acquire(session: "B", nonce: "b", task_slug: "add-gizmos-table", agent: "jasper",
                      now: NOW + MigrationLaneClaim::DEFAULT_TTL_SECONDS + 1)

    assert outcome.acquired, "a dead holder's lane must lapse, not wedge"
    assert_equal :expired, outcome.disposition
    assert_equal "add-gizmos-table", outcome.claim.task_slug, "a change of hands never inherits the old holder's task"
    assert_equal "jasper", outcome.claim.holder_agent
  end

  test "[unit] only the holder can release the lane" do
    acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")

    refute MigrationLaneClaim.release(session: "B", nonce: "b", now: NOW),
           "a queued Dev must never release a live migration out from under its author"
    assert MigrationLaneClaim.status_for(Task::MIGRATION_LANE, now: NOW)["live"], "the lane stays held"

    assert MigrationLaneClaim.release(session: "A", nonce: "a", now: NOW)
    refute MigrationLaneClaim.status_for(Task::MIGRATION_LANE, now: NOW)["live"]
  end

  # The SOP's belt-and-suspenders release fires on shipped/blocked/archived
  # whether or not the lane was ever taken, so it must be harmless.
  test "[unit] releasing a lane you never acquired is a harmless no-op" do
    assert_nothing_raised do
      refute MigrationLaneClaim.release(session: "never", nonce: "held", now: NOW)
    end
  end

  test "[unit] status reports truthfully when nobody holds the lane" do
    assert_nil MigrationLaneClaim.status_for(Task::MIGRATION_LANE, now: NOW),
               "no claim row at all reads as free"

    acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")
    MigrationLaneClaim.release(session: "A", nonce: "a", now: NOW)

    holder = MigrationLaneClaim.status_for(Task::MIGRATION_LANE, now: NOW)
    refute holder["live"], "a released row reads as free, not as held"
    assert_nil holder["task_slug"]
    assert_nil holder["session"]
  end

  # A row can OUTLIVE its lease. Anything that reads mere presence as "held"
  # would wedge the lane after the first holder ever crashed.
  test "[unit] status reports a lapsed lease as free" do
    acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")

    holder = MigrationLaneClaim.status_for(Task::MIGRATION_LANE,
                                           now: NOW + MigrationLaneClaim::DEFAULT_TTL_SECONDS + 1)
    refute holder["live"], "an expired lease is not a holder"
  end

  test "[unit] the lane row is a singleton — a second create is refused" do
    acquire(session: "A", nonce: "a")

    duplicate = MigrationLaneClaim.new(lane: Task::MIGRATION_LANE)
    refute duplicate.valid?, "the lane must have exactly one row"
    assert_raises(ActiveRecord::RecordInvalid) { duplicate.save! }
  end
end
