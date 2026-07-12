require "test_helper"

# B1 regression: an operator's saved rate override must actually reach the DOMINANT cost
# paths (AgentActivity + TaskEvent), not just the server-derived AgentAction one.
#
# Before this, cost was minted CLIENT-side by bin/atomic-event / bin/task — plain-Ruby
# processes with no ActiveRecord, where UsagePricing.db_rates returns {} — and the API
# stored that number verbatim. The static roster was not a fallback, it was the ONLY
# path: every activity and task event priced at list rate forever, so the admin page's
# headline promise ("applied to future cost calculations") was false.
class CaptureCostDerivationTest < ActiveSupport::TestCase
  MODEL = "claude-opus-4-8" # list: input 5.0/MTok

  test "[unit] an activity close DERIVES cost server-side, honoring a rate override" do
    ModelRateOverride.create!(model: MODEL, input_rate: 10.0, output_rate: 25.0)
    AgentActivity.open_activity!(session_id: "s-derive", category: "Edit", reason_slug: "write code")

    activity = AgentActivity.close_activity!(
      session_id: "s-derive", outcome_slug: "done",
      model: MODEL, tokens_in: 1_000_000, tokens_out: 0,
      cache_creation_tokens: 0, cache_read_tokens: 0,
      cost: "5.0" # what the no-ActiveRecord CLI computed at LIST rate
    )

    # The override doubled the input rate — the server re-derives rather than trusting
    # the client's list-priced number.
    assert_equal BigDecimal("10.0"), activity.cost
  end

  test "[unit] the client's cost stands when the CLI sends no cache_creation bucket" do
    ModelRateOverride.create!(model: MODEL, input_rate: 10.0, output_rate: 25.0)
    AgentActivity.open_activity!(session_id: "s-old-cli", category: "Edit", reason_slug: "write code")

    activity = AgentActivity.close_activity!(
      session_id: "s-old-cli", outcome_slug: "done",
      model: MODEL, tokens_in: 1_000_000, tokens_out: 0,
      cache_creation_tokens: nil, # an older CLI: tokens_in is folded and cannot be split
      cache_read_tokens: 0, cost: "5.0"
    )

    # We must NOT re-derive here: treating the folded tokens_in as pure input would
    # under-price cache writes. Keep the CLI's (correct, list-rate) number.
    assert_equal BigDecimal("5.0"), activity.cost
  end

  test "[unit] an unpriced model keeps the client's cost rather than fabricating one" do
    AgentActivity.open_activity!(session_id: "s-unknown", category: "Edit", reason_slug: "write code")

    activity = AgentActivity.close_activity!(
      session_id: "s-unknown", outcome_slug: "done",
      model: "mystery-model-9", tokens_in: 1_000, tokens_out: 10,
      cache_creation_tokens: 0, cache_read_tokens: 0, cost: "0.1234"
    )

    assert_equal BigDecimal("0.1234"), activity.cost
  end

  test "[unit] a task event DERIVES its cost server-side, honoring a rate override" do
    ModelRateOverride.create!(model: MODEL, input_rate: 10.0, output_rate: 25.0)
    task = Task.create!(title: "Derive Task Event Cost")

    Current.with_task_event_usage(
      model: MODEL, tokens_in: 1_000_000, tokens_out: 0,
      cache_creation_tokens: 0, cache_read_tokens: 0,
      cost: "5.0" # the CLI's list-rate number
    ) { task.update!(stage: "building") }

    event = task.task_events.transitions.order(:occurred_at).last
    assert_equal "building", event.to_stage
    # actual_size on the sizing dashboard derives from TaskEvent cost — so this is the
    # path that was silently pinned to list rate.
    assert_equal BigDecimal("10.0"), event.cost
    assert_equal 0, event.cache_creation_tokens
  end

  test "[unit] a task event keeps the CLI cost when the cache buckets are absent" do
    ModelRateOverride.create!(model: MODEL, input_rate: 10.0, output_rate: 25.0)
    task = Task.create!(title: "Keep Cli Cost Fallback")

    Current.with_task_event_usage(
      model: MODEL, tokens_in: 1_000_000, tokens_out: 0, cost: "5.0"
    ) { task.update!(stage: "building") }

    event = task.task_events.transitions.order(:occurred_at).last
    assert_equal BigDecimal("5.0"), event.cost
  end
end
