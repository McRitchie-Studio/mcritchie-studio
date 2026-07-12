require "test_helper"

# The server-side cost-derivation contract (UsagePricing.cost_from_capture) and the
# request-scoped rate memo. These are the guardrails on the money path: the capture CLIs
# mint cost in a plain-Ruby process with no ActiveRecord and so can NEVER see a DB rate
# override — the server re-derives on ingest, and must do so WITHOUT changing the number
# when no override exists.
class UsagePricingCaptureTest < ActiveSupport::TestCase
  MODEL = "claude-opus-4-8" # list: input 5.0, output 25.0 per MTok

  # The four-bucket delta a transcript yields, and the FOLDED tokens_in the wire carries.
  DELTA = { "input" => 100_000, "output" => 20_000,
            "cache_creation" => 40_000, "cache_read" => 3_000_000 }.freeze
  FOLDED_TOKENS_IN = DELTA["input"] + DELTA["cache_creation"] # what the CLI sends

  test "[unit] a server derive reproduces the CLI's number EXACTLY when no override exists" do
    cli_cost = UsagePricing.price(DELTA, MODEL)

    derived = UsagePricing.cost_from_capture(
      model: MODEL,
      tokens_in: FOLDED_TOKENS_IN,
      tokens_out: DELTA["output"],
      cache_creation_tokens: DELTA["cache_creation"],
      cache_read_tokens: DELTA["cache_read"]
    )

    # If this ever drifts, the server is silently RE-PRICING history. The classic way to
    # break it is to treat the folded tokens_in as pure `input`, which bills cache WRITES
    # at 1x instead of 2x — a systematic under-count of the bucket that dominates the bill.
    assert_equal cli_cost, derived, "server derive must not change the bill at list rates"
  end

  test "[unit] the derive splits the folded tokens_in — cache writes still price at 2x" do
    # Only cache_creation tokens: 40k at 2.0x the 5.0 input rate = 10.0/MTok → $0.40.
    derived = UsagePricing.cost_from_capture(
      model: MODEL, tokens_in: 40_000, tokens_out: 0,
      cache_creation_tokens: 40_000, cache_read_tokens: 0
    )

    assert_equal BigDecimal("0.4"), derived
    # Naively pricing that same tokens_in as pure input would yield HALF ($0.20).
    assert_not_equal BigDecimal("0.2"), derived
  end

  test "[unit] the derive returns nil without the cache_creation bucket, so the CLI's cost stands" do
    # An older CLI (or a historical row) never sent the un-folded bucket. We cannot split
    # tokens_in, so we must NOT guess — the caller keeps the CLI's list-priced cost.
    assert_nil UsagePricing.cost_from_capture(
      model: MODEL, tokens_in: FOLDED_TOKENS_IN, tokens_out: DELTA["output"],
      cache_creation_tokens: nil, cache_read_tokens: DELTA["cache_read"]
    )
  end

  test "[unit] the derive returns nil for an unpriced model — we never fabricate a price" do
    assert_nil UsagePricing.cost_from_capture(
      model: "some-unknown-model", tokens_in: 1000, tokens_out: 10,
      cache_creation_tokens: 0, cache_read_tokens: 0
    )
  end

  test "[unit] a saved override re-prices the derive — the whole point of the feature" do
    ModelRateOverride.create!(model: MODEL, input_rate: 10.0, output_rate: 25.0)

    # input doubled (5.0 → 10.0), so the input AND the multiplier-derived cache tiers double.
    derived = UsagePricing.cost_from_capture(
      model: MODEL, tokens_in: 1_000_000, tokens_out: 0,
      cache_creation_tokens: 0, cache_read_tokens: 0
    )

    assert_equal BigDecimal("10.0"), derived
  end

  test "[unit] a freshly-saved rate is visible immediately — the memo self-invalidates" do
    assert_equal BigDecimal("5.0"), UsagePricing.price({ "input" => 1_000_000 }, MODEL) # memoizes

    ModelRateOverride.create!(model: MODEL, input_rate: 9.0, output_rate: 25.0)

    # Without the generation stamp on the memo, this process would keep pricing at the
    # roster it cached BEFORE the save (there is no request boundary here to reset Current).
    assert_equal BigDecimal("9.0"), UsagePricing.price({ "input" => 1_000_000 }, MODEL)
  end

  test "[unit] the rate table is read ONCE per request, not once per price() call" do
    ModelRateOverride.create!(model: MODEL, input_rate: 7.0, output_rate: 25.0)
    Current.model_rate_overrides = nil # fresh request

    queries = 0
    counter = ->(_n, _s, _f, _i, payload) { queries += 1 if payload[:sql]&.include?("model_rate_overrides") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      5.times { UsagePricing.price({ "input" => 1_000 }, MODEL) }
    end

    assert_equal 1, queries, "price() sits on the hot capture path — it must not re-SELECT per call"
  end
end
