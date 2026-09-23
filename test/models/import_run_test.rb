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

  # --- fresh_success?(since:) ----------------------------------------------

  # THE CELL THE WINDOW CANNOT SEE, and the one that survived BOTH halves of the
  # earlier fix. `within` asks "did some run succeed today"; a lane grading its
  # own run has to ask "did THIS one". The two come apart on the second rebuild
  # of a day, and that is not a hypothetical shape: measured end-to-end against
  # the real importer, an `ok` row from two hours ago plus a feed outage now
  # leaves the process exiting 0, its own run recorded `failed`, and this
  # predicate answering true.
  test "a success that finished before this run started does not vouch for it" do
    run!(status: "ok", finished_at: 2.hours.ago)

    assert ImportRun.fresh_success?(SOURCE),
           "precondition: the day does hold a success, which is what makes the cell possible"
    assert_not ImportRun.fresh_success?(SOURCE, since: 1.hour.ago),
               "an earlier run's success cannot answer for a run that started after it"
  end

  # The half that keeps the predicate from being a constant. Differs from the
  # case above by EXACTLY the order of the two timestamps; a boundary that
  # refused everything would pass that one and fail this.
  test "a success that finished after this run started does vouch for it" do
    boundary = 1.hour.ago
    run!(status: "ok", finished_at: 30.minutes.ago)

    assert ImportRun.fresh_success?(SOURCE, since: boundary)
  end

  # `since` IS A FLOOR, NEVER A CEILING. Taking the later of the two bounds is
  # what makes this change strictly narrower than the behaviour it replaces — a
  # caller cannot hand in an old boundary and quietly turn a freshness check
  # back into "has it ever worked".
  test "since only narrows the window — it cannot widen it" do
    run!(status: "ok", finished_at: 3.days.ago)

    assert_not ImportRun.fresh_success?(SOURCE, since: 5.days.ago),
               "a since older than `within` must not resurrect a success the window already rejected"
  end

  # The shape bin/ecosystem-build actually passes: `date -u +%Y-%m-%dT%H:%M:%SZ`
  # through the environment. A model that only accepted a Time would leave the
  # lane interpolating Ruby into a bash string to build one.
  test "an ISO 8601 string is read as the boundary" do
    run!(status: "ok", finished_at: 30.minutes.ago)

    assert ImportRun.fresh_success?(SOURCE, since: 1.hour.ago.utc.iso8601)
    assert_not ImportRun.fresh_success?(SOURCE, since: 10.minutes.ago.utc.iso8601),
               "the string boundary has to bite in both directions, or it is decoration"
  end

  # A BOUNDARY NOBODY CAN READ IS REFUSED. Falling back to the wide window on an
  # unparseable `since` would hand the caller back the exact false green it
  # passed `since` to close, and would do it silently — which is the defect this
  # whole model exists to end, not a tidy default.
  # "last tuesday-ish" is not an arbitrary bit of garbage — it is the case that
  # chose the reader. `Time.zone.parse` does not return nil for it; it returns
  # TODAY AT MIDNIGHT, a boundary earlier than any run of the day, which quietly
  # restores the whole-day window `since` was passed to escape. So the assertion
  # is on a string a LENIENT reader would have accepted, not only on one that
  # every reader rejects.
  test "a boundary that cannot be read is refused, not dropped" do
    run!(status: "ok", finished_at: 30.minutes.ago)

    error = assert_raises(ArgumentError) { ImportRun.fresh_success?(SOURCE, since: "last tuesday-ish") }
    assert_match(/refusing to fall back/, error.message)
    assert_raises(ArgumentError) { ImportRun.fresh_success?(SOURCE, since: "") }
    assert_raises(ArgumentError) { ImportRun.fresh_success?(SOURCE, since: "garbage") }
  end

  # Every caller that does not pass a boundary keeps the answer it had. The pair
  # is load-bearing: a `since: nil` path that returned true for everything would
  # satisfy the first assertion alone.
  test "since: nil leaves the plain window answering exactly as before" do
    run!(status: "ok", finished_at: 2.hours.ago)
    assert ImportRun.fresh_success?(SOURCE, since: nil)

    ImportRun.delete_all
    run!(status: "ok", finished_at: 3.days.ago)
    assert_not ImportRun.fresh_success?(SOURCE, since: nil)
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
