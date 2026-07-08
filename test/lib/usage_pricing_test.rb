# frozen_string_literal: true

# Unit test for UsagePricing — the single list-price source of truth every usage
# surface routes through. Plain Ruby (no Rails); also picked up by `bin/rails test`.
#
#   ruby -Itest test/lib/usage_pricing_test.rb

require "minitest/autorun"
require "bigdecimal"
require "bigdecimal/util" # String#to_d in the assertions (ActiveSupport-free standalone run)
require_relative "../../lib/usage_pricing"

class UsagePricingTest < Minitest::Test
  MTOK = 1_000_000

  def teardown
    ENV.delete("ATOMIC_ACTION_MODEL_RATES")
  end

  # ---- [unit] per-tier list pricing -----------------------------------------

  def test_input_and_output_price_at_the_model_rate
    # claude-opus-4-8 = $5/MTok in, $25/MTok out.
    assert_equal "5.0".to_d,  UsagePricing.price({ "input" => MTOK }, "claude-opus-4-8")
    assert_equal "25.0".to_d, UsagePricing.price({ "output" => MTOK }, "claude-opus-4-8")
  end

  def test_cache_read_prices_at_ten_percent_of_input
    # 1M cache_read on opus ($5 in) => $5 * 0.10 = $0.50.
    assert_equal "0.5".to_d, UsagePricing.price({ "cache_read" => MTOK }, "claude-opus-4-8")
  end

  def test_cache_write_prices_at_the_one_hour_list_rate
    # 1M cache_creation on opus ($5 in) => $5 * 2.0 (1h TTL) = $10.00. This is the
    # correction from the old 1.25x (5m) assumption that under-priced writes.
    assert_equal "10.0".to_d, UsagePricing.price({ "cache_creation" => MTOK }, "claude-opus-4-8")
  end

  def test_prices_all_four_tiers_together
    # 1M in ($5) + 200K out ($5) + 1M cache_read ($0.50) + 100K cache_write ($1.00) = $11.50.
    buckets = { "input" => MTOK, "output" => 200_000, "cache_read" => MTOK, "cache_creation" => 100_000 }
    assert_equal "11.5".to_d, UsagePricing.price(buckets, "claude-opus-4-8")
  end

  # ---- [unit] never fabricate a price ---------------------------------------

  def test_unknown_or_blank_model_is_nil
    assert_nil UsagePricing.price({ "input" => 1000 }, "gpt-5-codex")
    assert_nil UsagePricing.price({ "input" => 1000 }, nil)
    assert_nil UsagePricing.price({ "input" => 1000 }, "")
    assert_nil UsagePricing.price(nil, "claude-opus-4-8")
  end

  def test_zero_usage_on_a_known_model_is_zero_not_nil
    assert_equal 0.to_d, UsagePricing.price({ "input" => 0, "output" => 0 }, "claude-opus-4-8")
  end

  # ---- [unit] normalization + key handling ----------------------------------

  def test_tier_suffix_is_stripped_so_the_1m_id_still_prices
    assert_equal "claude-opus-4-8", UsagePricing.normalize_model("claude-opus-4-8[1m]")
    assert_equal(
      UsagePricing.price({ "input" => MTOK }, "claude-opus-4-8"),
      UsagePricing.price({ "input" => MTOK }, "claude-opus-4-8[1m]")
    )
  end

  def test_bucket_keys_may_be_strings_or_symbols
    assert_equal(
      UsagePricing.price({ "input" => MTOK, "cache_read" => 500 }, "claude-opus-4-8"),
      UsagePricing.price({ input: MTOK, cache_read: 500 }, "claude-opus-4-8")
    )
  end

  # ---- [unit] absolute per-model cache override (OpenAI-style) ---------------

  def test_model_can_override_cache_read_with_an_absolute_rate
    # gpt-5.5 lists a flat cached-input rate of $0.50/MTok — not a multiple of input.
    assert_equal "0.5".to_d,  UsagePricing.price({ "cache_read" => MTOK }, "gpt-5.5")
    assert_equal "30.0".to_d, UsagePricing.price({ "output" => MTOK }, "gpt-5.5")
  end

  # ---- [unit] rounding + return type ----------------------------------------

  def test_returns_bigdecimal_rounded_to_four_places
    cost = UsagePricing.price({ "input" => 5_000, "output" => 250, "cache_read" => 304_000 }, "claude-opus-4-8")
    assert_kind_of BigDecimal, cost
    # (5000*5 + 250*25 + 304000*0.5) / 1e6 = 183250 / 1e6 = 0.18325 -> 0.1833 (4dp).
    assert_equal "0.1833".to_d, cost
  end

  # ---- [unit] env override --------------------------------------------------

  def test_env_override_adds_a_model_and_accepts_in_out_aliases
    ENV["ATOMIC_ACTION_MODEL_RATES"] = '{"custom-a":{"input":2.0,"output":8.0},"custom-b":{"in":1.0,"out":4.0}}'
    assert_equal "2.0".to_d, UsagePricing.price({ "input" => MTOK }, "custom-a")
    assert_equal "4.0".to_d, UsagePricing.price({ "output" => MTOK }, "custom-b")
  end

  def test_malformed_env_override_is_ignored_not_fatal
    ENV["ATOMIC_ACTION_MODEL_RATES"] = "not json {{"
    # Built-in rates still price; the bad env is swallowed.
    assert_equal "5.0".to_d, UsagePricing.price({ "input" => MTOK }, "claude-opus-4-8")
    assert_nil UsagePricing.price({ "input" => MTOK }, "custom-a")
  end
end
