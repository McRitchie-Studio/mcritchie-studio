# frozen_string_literal: true

require "bigdecimal"
require "json"

# The SINGLE source of truth for pricing agent token usage at provider LIST price.
# One rate roster, one cost function — every usage surface (per-action, per-activity,
# per-task) routes through here, so their dollar figures agree with each other and
# reconcile with the provider's own /usage meter.
#
# Before this module there were TWO pricing tables that disagreed:
#   * AgentAction::MODEL_RATES (cache WRITES folded into input at 1x — under-priced), and
#   * AgentSessionUsage::PRICING (cache writes at 1.25x).
# Both now delegate here.
#
# Plain Ruby (no Rails) so bin/task and bin/atomic-event can `require_relative` it
# directly; also autoloaded in-app via Zeitwerk (config.autoload_lib) — the same
# dual-load pattern lib/agent_session_usage.rb already relies on. The constant name
# matches the path (lib/usage_pricing.rb → UsagePricing) so Zeitwerk is happy even
# when a sibling lib file require_relatives it first.
module UsagePricing
  # USD per 1,000,000 tokens, per canonical model id. {input, output} are required.
  # Optional ABSOLUTE per-MTok overrides `cache_read` / `cache_creation` replace the
  # multiplier-derived rate for a provider that prices caches differently (e.g.
  # OpenAI's flat cached-input rate). Source: the claude-api skill pricing reference.
  # A model with NO entry yields a NIL cost — we never fabricate a price. Extend at
  # runtime via the ATOMIC_ACTION_MODEL_RATES env (JSON, see .env_rates).
  RATES = {
    "claude-fable-5"    => { input: 10.0, output: 50.0 },
    "claude-mythos-5"   => { input: 10.0, output: 50.0 },
    "claude-opus-4-8"   => { input: 5.0,  output: 25.0 },
    "claude-opus-4-7"   => { input: 5.0,  output: 25.0 },
    "claude-opus-4-6"   => { input: 5.0,  output: 25.0 },
    "claude-sonnet-4-6" => { input: 3.0,  output: 15.0 },
    "claude-haiku-4-5"  => { input: 1.0,  output: 5.0 },
    "gpt-5.5"           => { input: 5.0,  output: 30.0, cache_read: 0.5 }
  }.freeze

  # Cache tiers as a fraction of the model's input rate (Anthropic list price):
  #   READ  (cache hit)    = 0.10x
  #   WRITE (cache create) = 1.25x for a 5-minute TTL, 2.0x for a 1-hour TTL.
  # The transcript flattens both write TTLs into ONE cache_creation bucket, and
  # Claude Code writes 1-hour caches, so the write default is the 1-hour tier
  # (2.0x) — this is what makes the total reconcile with Claude Code's /usage
  # meter (the operator's chosen ground truth). A later phase can honor the
  # per-TTL breakdown (usage.cache_creation.ephemeral_{5m,1h}_input_tokens).
  CACHE_READ_MULTIPLIER  = BigDecimal("0.10")
  CACHE_WRITE_MULTIPLIER = BigDecimal("2.0")
  PER_MILLION = 1_000_000

  # The four usage tiers a priced bucket hash carries.
  BUCKETS = %w[input output cache_creation cache_read].freeze

  # Dollar cost (BigDecimal, rounded to the 4 decimals the cost column stores) of a
  # usage bucket hash for a model, or nil when the model has no known rate (never a
  # fabricated $0). `buckets` keys: input / output / cache_creation / cache_read
  # (missing → 0; string OR symbol keys accepted). Total/best-effort: any bad input
  # degrades to nil rather than raising into a capture.
  def self.price(buckets, model)
    return nil if buckets.nil?

    rate = rate_for(model)
    return nil unless rate

    input_rate  = to_d(rate[:input])
    output_rate = to_d(rate[:output])
    read_rate   = rate[:cache_read]     ? to_d(rate[:cache_read])     : input_rate * CACHE_READ_MULTIPLIER
    write_rate  = rate[:cache_creation] ? to_d(rate[:cache_creation]) : input_rate * CACHE_WRITE_MULTIPLIER

    per_mtok =
      bucket(buckets, "input")          * input_rate  +
      bucket(buckets, "output")         * output_rate +
      bucket(buckets, "cache_creation") * write_rate  +
      bucket(buckets, "cache_read")     * read_rate
    (per_mtok / PER_MILLION).round(4)
  rescue StandardError
    nil
  end

  # {input:, output:, cache_read?:, cache_creation?:} for a model, or nil. Strips a
  # trailing tier suffix ("[1m]" bills at standard rates for these models) and
  # merges the env override.
  def self.rate_for(model)
    key = normalize_model(model)
    return nil if key.nil?

    rates[key]
  end

  # The canonical model id: trimmed, with a trailing "[tier]" suffix removed. nil
  # for a blank/nil model.
  def self.normalize_model(model)
    return nil if model.nil?

    key = model.to_s.strip.sub(/\[[^\]]*\]\z/, "")
    key.empty? ? nil : key
  end

  # RATES merged with an optional ATOMIC_ACTION_MODEL_RATES env override. NOT
  # memoized so a test (or a hot-reloaded operator config) never reads a stale
  # roster; the merge is trivial.
  def self.rates
    RATES.merge(env_rates)
  end

  # Parse ATOMIC_ACTION_MODEL_RATES — JSON {"model-id": {"input"|"in": n,
  # "output"|"out": n, "cache_read"?: n, "cache_creation"?: n}}. A malformed value
  # or a half-defined rate is dropped so a bad env can never break costing.
  def self.env_rates
    raw = ENV["ATOMIC_ACTION_MODEL_RATES"].to_s.strip
    return {} if raw.empty?

    JSON.parse(raw).each_with_object({}) do |(model, v), acc|
      next unless v.is_a?(Hash)

      input  = v["input"]  || v["in"]
      output = v["output"] || v["out"]
      next if input.nil? || output.nil?

      entry = { input: input.to_f, output: output.to_f }
      entry[:cache_read]     = v["cache_read"].to_f     if v.key?("cache_read")
      entry[:cache_creation] = v["cache_creation"].to_f if v.key?("cache_creation")
      acc[model] = entry
    end
  rescue StandardError
    {}
  end

  # A single bucket's token count as an Integer (string or symbol key, missing → 0).
  def self.bucket(buckets, key)
    (buckets[key] || buckets[key.to_sym]).to_i
  end

  # Exact BigDecimal from a numeric rate literal (via its string form, so 5.0 stays 5.0).
  def self.to_d(value)
    BigDecimal(value.to_s)
  end

  private_class_method :env_rates, :bucket, :to_d
end
