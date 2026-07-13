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

  # Cost derived from the STORED capture columns, or nil when we cannot derive
  # faithfully. This is the server-side SoT: the capture CLIs mint their cost in a
  # plain-Ruby process with no ActiveRecord, so they can NEVER see a DB rate
  # override (db_rates returns {} there). Re-deriving on ingest is what makes an
  # operator's saved rate actually apply.
  #
  # `tokens_in` is the FOLDED count the capture contract has always stored
  # (input + cache_creation — cache_read is deliberately excluded from the COUNT;
  # see AgentSessionUsage::Result#tokens_in), so the raw input bucket is
  # tokens_in - cache_creation_tokens.
  #
  # Returns nil when cache_creation_tokens is ABSENT — without it we cannot split
  # tokens_in, and would price cache WRITES at 1x input instead of 2x: a silent
  # under-count of the bucket that dominates the bill. An older CLI (or a historical
  # row) omits it, and the caller then keeps the cost the CLI computed — correct at
  # LIST price, merely blind to an override. Never guess.
  def self.cost_from_capture(model:, tokens_in:, tokens_out:, cache_creation_tokens:, cache_read_tokens:)
    return nil if cache_creation_tokens.nil?

    cache_creation = cache_creation_tokens.to_i
    input = [tokens_in.to_i - cache_creation, 0].max
    price({ "input" => input, "output" => tokens_out.to_i,
            "cache_creation" => cache_creation, "cache_read" => cache_read_tokens.to_i }, model)
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

  # RATES merged with an optional ATOMIC_ACTION_MODEL_RATES env override, then with the
  # persisted DB overrides (operator-tuned, highest precedence).
  #
  # The merge is PER-MODEL, not per-entry. Hash#merge is shallow, so a plain merge would
  # let an override that sets only input/output REPLACE a model's whole rate entry —
  # silently discarding an explicit ABSOLUTE cache rate. gpt-5.5 ships exactly that
  # (cache_read: 0.5): saving an input override would drop it, and price() would fall
  # back to input * CACHE_READ_MULTIPLIER — 2x drift on cache_read, which is ~96-98% of
  # all tokens (see AgentSessionUsage::Result#tokens_in), i.e. most of the bill. An
  # override's OWN cache_read/cache_creation still wins when set; the static absolute
  # rate survives when it is not.
  #
  # db_rates is a TABLE READ and price() sits on the hot capture path (a cost is derived
  # for every action/activity, and once per model across the pricing roster) — so it is
  # memoized per REQUEST inside db_rates, not here.
  def self.rates
    per_model = ->(_model, static, override) { static.merge(override) }
    RATES.merge(env_rates, &per_model).merge(db_rates, &per_model)
  end

  # Persisted per-model overrides from the model_rate_overrides table (the admin
  # Model Pricing page writes these). Highest precedence, so a saved rate wins.
  #
  # AR-GUARDED: the plain-Ruby require_relative callers (bin/task, bin/atomic-event)
  # have no ActiveRecord, so this returns {} there. That is NOT a benign degradation
  # to a "fallback" — in those CLIs the static roster is the ONLY roster, which is
  # exactly why cost must be re-derived SERVER-side on ingest (cost_from_capture);
  # otherwise an operator's override would never reach the dominant cost path.
  #
  # Memoized per REQUEST via Current, so price() stops re-SELECTing this table on every
  # single call (it is on the hot capture path, and ran once per model across the
  # pricing roster). CurrentAttributes resets per request/job, so a write in another
  # process is picked up on the next request.
  #
  # The memo is STAMPED WITH A GENERATION that ModelRateOverride bumps on every commit.
  # Current alone is not sufficient: a process that prices, saves, and prices again
  # WITHOUT a request boundary between (a test, a job, a rake task, the console) would
  # otherwise keep serving the roster it cached before the save — the exact staleness
  # this module's "not memoized" comment used to guard against. The generation makes
  # the memo self-invalidating, so a freshly-saved rate is never read stale.
  def self.db_rates
    return {} unless defined?(ActiveRecord::Base)
    # The memo check comes FIRST: table_exists? checks out a DB connection, and price()
    # is on the hot capture path — a memo hit must cost nothing.
    unless request_memo?
      return {} unless ModelRateOverride.table_exists?

      return ModelRateOverride.rates_hash
    end

    generation = ModelRateOverride.rate_generation
    cached = Current.model_rate_overrides
    return cached.last if cached.is_a?(Array) && cached.first == generation
    return {} unless ModelRateOverride.table_exists?

    ModelRateOverride.rates_hash.tap do |rates|
      Current.model_rate_overrides = [generation, rates]
    end
  rescue StandardError => e
    warn_db_rates_failure(e)
    {}
  end

  def self.request_memo?
    defined?(Current) && Current.respond_to?(:model_rate_overrides)
  end

  # Swallowing a real DB failure here would price EVERYTHING at LIST rate with zero
  # visibility — the operator's override would appear to do nothing, with no breadcrumb.
  # This module is plain Ruby (bin/task and bin/atomic-event require_relative it, with no
  # Rails), so both sinks are guarded: log a warning when Rails is loaded, and capture an
  # ErrorLog when the app's model is there — honoring the every-rescue-logs discipline
  # wherever it is reachable. Best-effort: a failure to LOG must never break a capture.
  def self.warn_db_rates_failure(error)
    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.warn("[usage-pricing] db_rates failed — pricing at LIST rate: #{error.class}: #{error.message}")
    end
    ErrorLog.capture!(error) if defined?(ErrorLog)
  rescue StandardError
    nil
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

  private_class_method :env_rates, :db_rates, :request_memo?, :warn_db_rates_failure, :bucket, :to_d
end
