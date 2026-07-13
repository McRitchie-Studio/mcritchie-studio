# frozen_string_literal: true

require "test_helper"

# [unit] UsagePricing DB-override precedence. The plain-Ruby usage_pricing_test.rb
# covers the static roster + env; this Rails-loaded test covers the persisted
# model_rate_overrides layer — a saved rate must win over RATES and re-price.
class UsagePricingDbOverrideTest < ActiveSupport::TestCase
  MTOK = 1_000_000

  test "with no override, the static list rate applies" do
    assert_equal BigDecimal("5.0"), UsagePricing.price({ "input" => MTOK }, "claude-opus-4-8")
  end

  test "a saved override takes precedence over the static RATES roster" do
    ModelRateOverride.create!(model: "claude-opus-4-8", input_rate: 9.0, output_rate: 40.0)

    assert_equal BigDecimal("9.0"),  UsagePricing.price({ "input" => MTOK }, "claude-opus-4-8")
    assert_equal BigDecimal("40.0"), UsagePricing.price({ "output" => MTOK }, "claude-opus-4-8")
  end

  test "cache tiers derive from the OVERRIDDEN input rate" do
    ModelRateOverride.create!(model: "claude-opus-4-8", input_rate: 10.0, output_rate: 25.0)

    # cache_read = 0.10x input => $1.00 ; cache_creation = 2.0x input => $20.00
    assert_equal BigDecimal("1.0"),  UsagePricing.price({ "cache_read" => MTOK }, "claude-opus-4-8")
    assert_equal BigDecimal("20.0"), UsagePricing.price({ "cache_creation" => MTOK }, "claude-opus-4-8")
  end

  test "an override for one model does not disturb another" do
    ModelRateOverride.create!(model: "claude-opus-4-8", input_rate: 9.0, output_rate: 25.0)
    assert_equal BigDecimal("1.0"), UsagePricing.price({ "input" => MTOK }, "claude-haiku-4-5")
  end
end
