# Read model for the admin Model Pricing page. For each priced-roster model it
# reports the current (override-aware) input/output rate and a summary of the
# LAST session that used the model — its summed in/out tokens decomposed into
# in-cost, out-cost and total at the model's current rate.
#
# The cost here is a deliberate TWO-FACTOR view: total = in_cost + out_cost — the two
# factors the rate sliders drive. It intentionally excludes the cache_READ tier (priced
# in full by UsagePricing elsewhere); this surface is for tuning the in/out rates.
#
# It does NOT, however, mis-price the in side. tokens_in is FOLDED (input +
# cache_creation), so multiplying it by the input rate would bill cache WRITES at 1x
# instead of 2x. We split it back out with the cache_creation_tokens column and route
# BOTH factors through UsagePricing.price — the same BigDecimal SoT that stamps the
# stored cost — so this roster can never drift from the rates it is used to tune.
#
# Usage source: AgentActivity (turn-rolled-up, carries model + tokens_in/out +
# session_id + opened_at), so no per-turn dedup is needed.
class ModelPricing
  Row = Data.define(
    :model, :input_rate, :output_rate, :overridden,
    :session_id, :tokens_in, :tokens_out, :input_tokens, :cache_creation_tokens,
    :in_cost, :out_cost, :total_cost
  )

  # Every model in the static roster, sorted, each as a Row.
  def self.roster
    overridden = ModelRateOverride.pluck(:model).to_set
    UsagePricing::RATES.keys.sort.map { |model| for_model(model, overridden: overridden.include?(model)) }
  end

  # A single model's rate + last-session cost summary. `overridden` is looked up
  # when not supplied (the roster preloads it to avoid N queries).
  def self.for_model(model, overridden: nil)
    rate = UsagePricing.rate_for(model) || {}
    input_rate  = (rate[:input]  || 0).to_f
    output_rate = (rate[:output] || 0).to_f

    session_id, tokens_in, tokens_out, cache_creation = last_session_totals(model)
    # The raw input bucket: the folded count minus the cache WRITES inside it.
    input_tokens = [tokens_in - cache_creation, 0].max

    in_cost  = UsagePricing.price({ "input" => input_tokens, "cache_creation" => cache_creation }, model) || 0
    out_cost = UsagePricing.price({ "output" => tokens_out }, model) || 0

    Row.new(
      model: model, input_rate: input_rate, output_rate: output_rate,
      overridden: overridden.nil? ? ModelRateOverride.exists?(model: model) : overridden,
      session_id: session_id, tokens_in: tokens_in, tokens_out: tokens_out,
      input_tokens: input_tokens, cache_creation_tokens: cache_creation,
      in_cost: in_cost, out_cost: out_cost, total_cost: in_cost + out_cost
    )
  end

  # [session_id, sum_tokens_in, sum_tokens_out, sum_cache_creation_tokens] for the most
  # recent session that used `model`, or [nil, 0, 0, 0] when it has no recorded usage.
  def self.last_session_totals(model)
    session_id = AgentActivity.where(model: model)
                              .order(opened_at: :desc, seq: :desc)
                              .limit(1).pick(:session_id)
    return [nil, 0, 0, 0] if session_id.nil?

    tokens_in, tokens_out, cache_creation = AgentActivity
      .where(model: model, session_id: session_id)
      .pick(Arel.sql("COALESCE(SUM(tokens_in), 0), COALESCE(SUM(tokens_out), 0), " \
                     "COALESCE(SUM(cache_creation_tokens), 0)"))
    [session_id, tokens_in.to_i, tokens_out.to_i, cache_creation.to_i]
  end

  # This model's activities within the given session, newest first — the feed the
  # detail page renders (a scoped, model-filtered view of /agents/activities).
  def self.session_activities(model, session_id)
    return AgentActivity.none if session_id.nil?

    AgentActivity.where(model: model, session_id: session_id).order(opened_at: :desc, seq: :desc)
  end
end
