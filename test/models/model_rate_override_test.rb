# frozen_string_literal: true

require "test_helper"

# [unit] The persisted per-model rate override — validations + the rates_hash
# shape UsagePricing merges.
class ModelRateOverrideTest < ActiveSupport::TestCase
  test "model, input_rate and output_rate are required" do
    override = ModelRateOverride.new
    assert_not override.valid?
    assert override.errors[:model].any?
    assert override.errors[:input_rate].any?
    assert override.errors[:output_rate].any?
  end

  test "model is unique" do
    ModelRateOverride.create!(model: "claude-opus-4-8", input_rate: 5, output_rate: 25)
    dup = ModelRateOverride.new(model: "claude-opus-4-8", input_rate: 6, output_rate: 26)
    assert_not dup.valid?
    assert dup.errors[:model].any?
  end

  test "rates cannot be negative" do
    override = ModelRateOverride.new(model: "claude-opus-4-8", input_rate: -1, output_rate: 25)
    assert_not override.valid?
    assert override.errors[:input_rate].any?
  end

  test "rates_hash maps each model to its input/output rate" do
    ModelRateOverride.create!(model: "claude-opus-4-8", input_rate: 4.5, output_rate: 22.5)
    ModelRateOverride.create!(model: "claude-haiku-4-5", input_rate: 0.8, output_rate: 4.0)

    hash = ModelRateOverride.rates_hash
    assert_equal({ input: 4.5, output: 22.5 }, hash["claude-opus-4-8"])
    assert_equal({ input: 0.8, output: 4.0 }, hash["claude-haiku-4-5"])
  end

  test "rates_hash includes optional absolute cache rates only when set" do
    ModelRateOverride.create!(model: "gpt-5.5", input_rate: 5, output_rate: 30, cache_read_rate: 0.5)
    entry = ModelRateOverride.rates_hash["gpt-5.5"]
    assert_equal 0.5, entry[:cache_read]
    assert_not entry.key?(:cache_creation)
  end
end
