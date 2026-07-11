# frozen_string_literal: true

require "test_helper"

# [unit] The Model Pricing read model — roster, last-session summary, and the
# override-aware rate/cost calculation.
class ModelPricingTest < ActiveSupport::TestCase
  test "roster lists every static RATES model, sorted" do
    assert_equal UsagePricing::RATES.keys.sort, ModelPricing.roster.map(&:model)
  end

  test "a model with no usage summarizes to zero at its list rate" do
    row = ModelPricing.for_model("claude-opus-4-8")
    assert_equal 5.0, row.input_rate
    assert_equal 25.0, row.output_rate
    assert_nil row.session_id
    assert_equal 0, row.tokens_in
    assert_equal 0, row.tokens_out
    assert_in_delta 0.0, row.total_cost, 0.0001
    assert_not row.overridden
  end

  test "for_model summarizes only the most recent session that used the model" do
    make_activity("sess-old", "claude-opus-4-8", 100, 50, 3.hours.ago, 0)
    make_activity("sess-new", "claude-opus-4-8", 1_000_000, 200_000, 1.hour.ago, 0)
    make_activity("sess-new", "claude-opus-4-8", 500_000, 100_000, 1.hour.ago, 1)
    # a different model in the same recent session must not bleed into the totals
    make_activity("sess-new", "claude-haiku-4-5", 999, 999, 1.hour.ago, 2)

    row = ModelPricing.for_model("claude-opus-4-8")
    assert_equal "sess-new", row.session_id
    assert_equal 1_500_000, row.tokens_in
    assert_equal 300_000, row.tokens_out
    # in: 1.5M * $5 / 1M = $7.50 ; out: 0.3M * $25 / 1M = $7.50 ; total $15.00
    assert_in_delta 7.5, row.in_cost, 0.0001
    assert_in_delta 7.5, row.out_cost, 0.0001
    assert_in_delta 15.0, row.total_cost, 0.0001
  end

  test "a saved override changes the model's rate and its computed in-cost" do
    make_activity("sess-x", "claude-opus-4-8", 1_000_000, 0, 1.hour.ago, 0)
    assert_in_delta 5.0, ModelPricing.for_model("claude-opus-4-8").in_cost, 0.0001

    ModelRateOverride.create!(model: "claude-opus-4-8", input_rate: 8.0, output_rate: 25.0)

    row = ModelPricing.for_model("claude-opus-4-8")
    assert row.overridden
    assert_equal 8.0, row.input_rate
    assert_in_delta 8.0, row.in_cost, 0.0001
  end

  private

  def make_activity(session_id, model, tokens_in, tokens_out, opened_at, seq)
    AgentActivity.create!(
      session_id: session_id, category: "Edit", reason_slug: "work",
      model: model, tokens_in: tokens_in, tokens_out: tokens_out,
      opened_at: opened_at, seq: seq
    )
  end
end
