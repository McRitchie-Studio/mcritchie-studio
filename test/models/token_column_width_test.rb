require "test_helper"

# Regression cover for the 2026-09-17 incident: `bin/task move <slug> archived`
# failed with a bare
#
#   422: 2231911675 is out of range for ActiveModel::Type::Integer with limit 4 bytes
#
# because every usage/token counter in the hub was declared `t.integer` (int4,
# max 2_147_483_647) while `cache_read_tokens` carries a CUMULATIVE session total.
# A telemetry number therefore vetoed a workflow state change, and the 422 named
# neither the table nor the column.
class TokenColumnWidthTest < ActiveSupport::TestCase
  INT4_MAX = 2_147_483_647
  ABOVE_INT4 = 2_231_911_675 # the exact value from the incident

  test "a TaskEvent stores a cache_read above int4 max" do
    task = Task.create!(title: "Wide cache read task", stage: "designed")

    event = task.task_events.create!(
      to_stage: "building",
      occurred_at: Time.current,
      cache_read_tokens: ABOVE_INT4
    )

    assert_equal ABOVE_INT4, event.reload.cache_read_tokens
  end

  test "every task_events token column stores a value above int4 max" do
    task = Task.create!(title: "Wide every column task", stage: "designed")

    event = task.task_events.create!(
      to_stage: "building",
      occurred_at: Time.current,
      cache_read_tokens: ABOVE_INT4,
      cache_creation_tokens: ABOVE_INT4,
      tokens_in: ABOVE_INT4,
      tokens_out: ABOVE_INT4
    )

    event.reload
    assert_equal ABOVE_INT4, event.cache_read_tokens
    assert_equal ABOVE_INT4, event.cache_creation_tokens
    assert_equal ABOVE_INT4, event.tokens_in
    assert_equal ABOVE_INT4, event.tokens_out
  end

  # The INCIDENT itself: the overflow happened inside Task's `after_update`
  # transition callback, so the failure was not "telemetry did not record" —
  # it was "the task did not archive".
  test "a stage move carrying a cumulative cache_read above int4 max still lands" do
    task = Task.create!(title: "Wide move task", stage: "designed")

    Current.task_event_model = "claude-opus-5"
    Current.task_event_cache_read_tokens = ABOVE_INT4
    Current.task_event_tokens_in = 120_000
    Current.task_event_tokens_out = 8_000

    task.update!(stage: "building")

    assert_equal "building", task.reload.stage
    event = task.task_events.transitions.chronological.last
    assert_equal "building", event.to_stage
    assert_equal ABOVE_INT4, event.cache_read_tokens
  end

  test "an AgentAction stores token counts above int4 max" do
    action = AgentAction.create!(
      session_id: "sess-wide-token",
      kind: "tool_call",
      occurred_at: Time.current,
      cache_read_tokens: ABOVE_INT4,
      tokens_in: ABOVE_INT4,
      tokens_out: ABOVE_INT4
    )

    action.reload
    assert_equal ABOVE_INT4, action.cache_read_tokens
    assert_equal ABOVE_INT4, action.tokens_in
    assert_equal ABOVE_INT4, action.tokens_out
  end

  test "an AgentActivity stores token counts above int4 max" do
    activity = AgentActivity.create!(
      session_id: "sess-wide-activity",
      category: "Explore",
      reason_slug: "wide-token-activity",
      opened_at: Time.current,
      cache_read_tokens: ABOVE_INT4,
      cache_creation_tokens: ABOVE_INT4,
      tokens_in: ABOVE_INT4,
      tokens_out: ABOVE_INT4
    )

    activity.reload
    assert_equal ABOVE_INT4, activity.cache_read_tokens
    assert_equal ABOVE_INT4, activity.cache_creation_tokens
    assert_equal ABOVE_INT4, activity.tokens_in
    assert_equal ABOVE_INT4, activity.tokens_out
  end

  test "a Usage rollup stores token totals above int4 max" do
    usage = Usage.create!(
      agent_slug: "carl",
      period_date: Date.current,
      period_type: "day",
      model: "claude-opus-5",
      tokens_in: ABOVE_INT4,
      tokens_out: ABOVE_INT4
    )

    usage.reload
    assert_equal ABOVE_INT4, usage.tokens_in
    assert_equal ABOVE_INT4, usage.tokens_out
  end

  test "int4 remains int4 where it belongs" do
    # Guard against a blanket widening: only the token counters move. Counters
    # bounded by their own semantics (a sequence number, a duration) stay int4.
    assert_equal 4, AgentAction.columns_hash["seq"].limit
    assert_equal 4, TaskEvent.columns_hash["seconds_in_from"].limit
  end
end

# The second half of the incident: the 422 said nothing about WHICH column, so
# the diagnosis took most of a session. A range error must name itself.
class OutOfRangeColumnNamingTest < ActiveSupport::TestCase
  # `seconds_in_from` stays a 4-byte integer after the bigint migration, so it is
  # a real, still-narrow column to overflow — not a fixture of the test.
  ABOVE_INT4 = 2_231_911_675

  test "an integer overflow names the table and column" do
    task = Task.create!(title: "Naming overflow task", stage: "designed")

    error = assert_raises(IntegerColumnRange::OutOfRangeColumnError) do
      task.task_events.create!(
        to_stage: "building",
        occurred_at: Time.current,
        seconds_in_from: ABOVE_INT4
      )
    end

    assert_includes error.message, "task_events.seconds_in_from"
    assert_includes error.message, ABOVE_INT4.to_s
    assert_includes error.message, "4-byte integer column"
    assert_equal "seconds_in_from", error.attribute
    assert_equal ABOVE_INT4, error.value
  end

  test "the named error stays catchable as the error it replaces" do
    # Callers already rescuing ActiveModel::RangeError (or bare RangeError) must
    # keep working — this changes the message, not the contract.
    assert IntegerColumnRange::OutOfRangeColumnError < ActiveModel::RangeError
    assert IntegerColumnRange::OutOfRangeColumnError < RangeError
  end

  test "an overflow inside a nested write still names the nested column" do
    # The incident's exact shape: Task#update! -> after_update -> TaskEvent insert.
    task = Task.create!(title: "Nested overflow task", stage: "designed")
    Current.task_event_source = "cli"

    error = assert_raises(IntegerColumnRange::OutOfRangeColumnError) do
      task.task_events.create!(to_stage: "x", occurred_at: Time.current, seconds_in_from: ABOVE_INT4)
    end
    assert_includes error.message, "task_events.seconds_in_from"
  end

  test "a save that does not overflow is untouched" do
    task = Task.create!(title: "Control no overflow task", stage: "designed")
    event = task.task_events.create!(to_stage: "building", occurred_at: Time.current, seconds_in_from: 42)
    assert_equal 42, event.reload.seconds_in_from
  end
end

# Telemetry must degrade, never veto. A token count too wide for its column is
# clamped and logged; the write it rides along with still lands.
class TelemetryClampTest < ActiveSupport::TestCase
  ABOVE_INT8 = (1 << 63) + 500 # beyond bigint too, so the clamp is reachable post-migration
  INT8_MAX = (1 << 63) - 1

  test "a token count beyond the column ceiling is clamped, not raised" do
    task = Task.create!(title: "Clamp telemetry task", stage: "designed")

    event = task.task_events.create!(
      to_stage: "building",
      occurred_at: Time.current,
      cache_read_tokens: ABOVE_INT8
    )

    assert_equal INT8_MAX, event.reload.cache_read_tokens
  end

  test "a clamp still lets the stage transition land" do
    task = Task.create!(title: "Clamp keeps move task", stage: "designed")
    Current.task_event_cache_read_tokens = ABOVE_INT8

    task.update!(stage: "building")

    assert_equal "building", task.reload.stage
    assert_equal INT8_MAX, task.task_events.transitions.chronological.last.cache_read_tokens
  end

  test "a clamp writes an ErrorLog naming the column and the raw value" do
    task = Task.create!(title: "Clamp logs task", stage: "designed")

    assert_difference -> { ErrorLog.count }, 1 do
      task.task_events.create!(to_stage: "building", occurred_at: Time.current, tokens_in: ABOVE_INT8)
    end

    log = ErrorLog.order(:id).last
    assert_includes log.message, "task_events.tokens_in"
    assert_includes log.message, ABOVE_INT8.to_s
    assert_includes log.message, "clamped to #{INT8_MAX}"
  end

  test "an in-range token count is never clamped and logs nothing" do
    task = Task.create!(title: "Clamp control task", stage: "designed")

    assert_no_difference -> { ErrorLog.count } do
      event = task.task_events.create!(
        to_stage: "building", occurred_at: Time.current, cache_read_tokens: 2_231_911_675
      )
      assert_equal 2_231_911_675, event.reload.cache_read_tokens
    end
  end

  test "clamping is opt-in: a non-telemetry column still raises" do
    task = Task.create!(title: "Clamp opt in task", stage: "designed")

    assert_raises(IntegerColumnRange::OutOfRangeColumnError) do
      task.task_events.create!(to_stage: "building", occurred_at: Time.current, seconds_in_from: 2_231_911_675)
    end
  end
end
