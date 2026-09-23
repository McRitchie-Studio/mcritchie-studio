require "test_helper"

# [unit] ImportRun AS THE VERDICT, which is what it became the day
# Nflverse::SeedPlayers stopped raising on a feed outage. That rescue is
# deliberate — the importer is a declared post_deploy_cmd and a dead upstream
# must not abort a ship — but it means the process exits 0 whether it read the
# feed or never reached it. Every lane that graded the importer by its exit
# status has been reading a constant since; the row is the only thing left that
# still discriminates.
#
# SO EACH READER IS GRADED ON DISCRIMINATION, not on returning the right answer
# once. A check that gives the same answer in both worlds is not a check, so for
# every true case below there is a false one that differs from it by exactly the
# property under test.
class ImportRunTest < ActiveSupport::TestCase
  SOURCE = "nflverse_players"

  setup { ImportRun.delete_all }

  def run!(status:, finished_at:, source: SOURCE, started_at: nil)
    ImportRun.create!(source: source, status: status, finished_at: finished_at,
                      started_at: started_at || finished_at || Time.current)
  end

  # --- fresh_success? ------------------------------------------------------

  test "a success that finished within the window is fresh" do
    run!(status: "ok", finished_at: 1.hour.ago)

    assert ImportRun.fresh_success?(SOURCE)
  end

  # THE CASE THE LEVEL CANNOT SEE, and the reason this predicate exists rather
  # than a bare `last_success_for(...).present?`. A reader that only asks "has
  # this source EVER succeeded" answers true here and true above — identical
  # under a healthy importer and one that has not reached the feed in a week.
  # Recency is the entire discrimination, so this is the assertion a mutation
  # that drops the window has to turn red.
  test "a success that finished outside the window is NOT fresh" do
    run!(status: "ok", finished_at: 3.days.ago)

    assert_not ImportRun.fresh_success?(SOURCE),
               "a stale success must not read as a fresh one — that is the whole question"
  end

  test "a failed run inside the window is not a fresh success" do
    run!(status: "failed", finished_at: 1.hour.ago)

    assert_not ImportRun.fresh_success?(SOURCE)
  end

  test "a source that has never run is not a fresh success" do
    assert_not ImportRun.fresh_success?(SOURCE)
  end

  test "a fresh success for another source does not answer for this one" do
    run!(status: "ok", finished_at: 1.hour.ago, source: "nflverse_schedule")

    assert_not ImportRun.fresh_success?(SOURCE)
  end

  test "the window is the caller's to widen" do
    run!(status: "ok", finished_at: 3.days.ago)

    assert ImportRun.fresh_success?(SOURCE, within: 7.days)
  end

  # --- last_success_for ----------------------------------------------------

  # MEASURED ON THIS SCHEMA, not reasoned from the docs. Postgres sorts NULLS
  # FIRST on a DESC order, so an `ok` row that never stamped a finish sorted
  # ahead of every genuine success and WON this lookup — handing the caller a
  # run that never ended, and a nil finished_at to do freshness arithmetic on.
  test "a success with no finished_at never wins over a completed one" do
    completed = run!(status: "ok", finished_at: 3.days.ago)
    run!(status: "ok", finished_at: nil, started_at: 1.hour.ago)

    assert_equal completed.id, ImportRun.last_success_for(SOURCE)&.id,
                 "an unfinished success outranked a finished one (NULLS FIRST on DESC)"
  end

  test "the most recently finished success wins" do
    run!(status: "ok", finished_at: 3.days.ago)
    newest = run!(status: "ok", finished_at: 1.hour.ago)

    assert_equal newest.id, ImportRun.last_success_for(SOURCE)&.id
  end

  test "stats defaults to an empty hash, never nil" do
    assert_equal({}, run!(status: "ok", finished_at: 1.hour.ago).stats)
  end
end
