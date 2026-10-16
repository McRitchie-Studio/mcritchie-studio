# What the domain CTOs' answers cost, and the monthly allowance that caps a
# client app's share (docs/agents/system/agent-usage.md; Phase 7 of
# .agents/epics/domain-agents.md).
#
#   AgentUsage.totals(souls: %w[avi xan], from:, to:)       # one Totals
#   AgentUsage.daily("turf_monster", days: 7)               # [[Date, Totals]] per Denver day
#   AgentUsage.meter(app)                                   # this month's Meter for an App row
#   AgentUsage.gate(message)                                # before a claim: :ok, :warn or :stop
#
# THE SOURCE is each completed answer's run summary (agent_messages.run_meta,
# AgentMailbox::ClaudeRun.meta): computed from the rows on every read, so there
# is no rollup table to drift and no job to run. The sums read each key only
# where it holds a JSON number.
#
# WHAT COUNTS AGAINST AN ALLOWANCE: the answers to client and public senders
# (run_meta.audience, stamped by the board at complete). Owner and team answers
# are counted in the totals but never metered and never capped. An answer from
# before this release carries no audience and is not metered (only the owner
# was answered then).
#
# THE TOKENS an allowance counts are input + cache read + cache write + output
# (thinking is inside output). No price is computed here: total_cost_usd is the
# CLI's own figure, shown as reported.
module AgentUsage
  ZONE = DailyAppReport::ZONE
  METERED_AUDIENCES = %w[client public].freeze
  UNCAPPED_AUDIENCES = %w[owner team].freeze
  TOKEN_KINDS = %w[input_tokens cache_read_tokens cache_creation_tokens output_tokens].freeze
  SUMMED = (TOKEN_KINDS + %w[thinking_tokens total_cost_usd duration_ms]).freeze
  DEFAULT_WARN_PERCENT = 80
  # Capped this many times in a month: suggest the next tier whatever the trend.
  CAPPED_TWICE = 2

  Totals = Struct.new(:messages, :input_tokens, :cache_read_tokens, :cache_creation_tokens, :output_tokens,
                      :thinking_tokens, :cost_usd, :duration_ms, :timed, keyword_init: true) do
    def self.zero = new(messages: 0, input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0,
                        output_tokens: 0, thinking_tokens: 0, cost_usd: 0.0, duration_ms: 0, timed: 0)

    # The tokens an allowance counts.
    def tokens = input_tokens + cache_read_tokens + cache_creation_tokens + output_tokens
    def avg_duration_ms = timed.positive? ? (duration_ms.to_f / timed).round : nil
    def empty? = messages.zero?

    def as_json(*)
      { "messages" => messages, "tokens" => tokens, "input_tokens" => input_tokens,
        "cache_read_tokens" => cache_read_tokens, "cache_creation_tokens" => cache_creation_tokens,
        "output_tokens" => output_tokens, "thinking_tokens" => thinking_tokens,
        "cost_usd" => cost_usd.round(4), "avg_duration_ms" => avg_duration_ms }
    end
  end

  # One app's month. `allowance` nil is unlimited (no tier, a blank
  # cto_monthly_tokens, or an admin's lift). `used` is the metered tokens.
  Meter = Struct.new(:app_slug, :domain, :tier, :tier_name, :allowance, :used, :totals, :lifted,
                     :capped_count, :period_start, :period_end, :now, :warn_percent, keyword_init: true) do
    def unlimited? = allowance.nil?
    def percent = unlimited? ? nil : ((used.to_f / allowance) * 100).floor
    def state
      return :unlimited if unlimited?
      return :capped if used >= allowance
      return :warn if percent >= warn_percent

      :ok
    end

    def capped? = state == :capped
    def warn? = state == :warn
    def remaining = unlimited? ? nil : [ allowance - used, 0 ].max
    def suggestion = @suggestion ||= Suggestion.for(self)

    def as_json(*)
      { "app" => app_slug, "domain" => domain, "tier" => tier, "allowance" => allowance, "used" => used,
        "percent" => percent, "state" => state.to_s, "lifted" => lifted, "capped_this_month" => capped_count,
        "period" => { "start" => period_start.iso8601, "end" => period_end.iso8601 },
        "month" => totals.as_json, "suggestion" => suggestion&.as_json }
    end
  end

  Gate = Struct.new(:state, :meter, keyword_init: true) do
    def stop? = state == :stop
    def warn? = state == :warn
  end

  module_function

  # The registry the proposals read, loaded once per process.
  def registry = AgentProposal.registry

  # An app's monthly allowance: nil (unlimited) without a tier, with a blank
  # cto_monthly_tokens, or while an admin's lift stands.
  def allowance_for(app)
    return nil if app.cto_cap_lifted_at.present? || app.package_tier.blank?

    WorkspacePackage.find(app.package_tier)&.cto_monthly_tokens
  end

  # The domain key whose front door serves `app_slug` (config/agent_domains.yml `app:`).
  def domain_for_app(app_slug, registry: self.registry)
    registry.domains.find { |_, d| d.is_a?(Hash) && d["app"].to_s == app_slug.to_s && !d["internal"] }&.first
  end

  # Every soul whose answers a domain's usage counts (the `souls:` map).
  def souls_for(domain, registry: self.registry)
    return [] if domain.blank?

    souls = registry.soul_domains.select { |_, d| d.to_s == domain.to_s }.keys
    front = registry.domains.dig(domain.to_s, "soul")
    (souls + [ front ]).compact.map(&:to_s).uniq
  end

  def month_range(now = Time.current)
    local = now.in_time_zone(ZONE)
    [ local.beginning_of_month, local.end_of_month ]
  end

  # Sum the run summaries of completed answers by these souls in [from, to).
  def totals(souls:, from:, to:, metered_only: false)
    rows = sums(scope(souls, from, to, metered_only)).first
    totals_from(rows)
  end

  # [[Date, Totals]] for each of the last `days` Denver days ending today,
  # oldest first; a day with no answers is Totals.zero.
  def daily(domain, days: 7, now: Time.current, metered_only: false)
    today = now.in_time_zone(ZONE).to_date
    from = (today - (days - 1)).in_time_zone(ZONE)
    to = (today + 1).in_time_zone(ZONE)
    day_sql = "(agent_messages.completed_at AT TIME ZONE 'UTC' AT TIME ZONE '#{ZONE}')::date"
    by_day = sums(scope(souls_for(domain), from, to, metered_only).group(Arel.sql(day_sql)),
                  extra: [ Arel.sql("#{day_sql} AS day") ]).to_h { |row| [ row["day"].to_date, totals_from(row) ] }
    (from.to_date..today).map { |date| [ date, by_day.fetch(date) { Totals.zero } ] }
  end

  # This month's meter for an App row (owner pages, the usage ask, the gate).
  def meter(app, now: Time.current, registry: self.registry)
    domain = domain_for_app(app.slug, registry: registry)
    start, finish = month_range(now)
    souls = souls_for(domain, registry: registry)
    package = app.package_tier.present? ? WorkspacePackage.find(app.package_tier) : nil
    Meter.new(app_slug: app.slug, domain: domain, tier: app.package_tier, tier_name: package&.name,
              allowance: allowance_for(app), lifted: app.cto_cap_lifted_at.present?,
              used: souls.empty? ? 0 : totals(souls: souls, from: start, to: now, metered_only: true).tokens,
              totals: souls.empty? ? Totals.zero : totals(souls: souls, from: start, to: now),
              capped_count: capped_count(souls, start, now),
              period_start: start, period_end: finish, now: now, warn_percent: warn_percent)
  end

  # The check before a run is claimed. Owner and team senders are never capped
  # (and never metered, so they cost no query). For anyone else: the app their
  # soul's domain serves, its meter, and :stop at 100%, :warn at warn_percent.
  def gate(message, now: Time.current, registry: self.registry)
    return Gate.new(state: :ok) if UNCAPPED_AUDIENCES.include?(message.usage_audience)

    domain = registry.domain_key_for(message.soul_slug) || registry.front_door(message.soul_slug)&.dig("key")
    app_slug = domain && registry.domains.dig(domain, "app")
    app = app_slug && App.find_by(slug: app_slug)
    return Gate.new(state: :ok) unless app && allowance_for(app)

    meter = meter(app, now: now, registry: registry)
    state = if meter.capped? then :stop
    elsif meter.warn? then :warn
    else :ok
    end
    Gate.new(state: state, meter: meter)
  end

  def warn_percent
    value = WorkspacePackage.cto_usage["warn_percent"]
    value.is_a?(Integer) && value.between?(1, 99) ? value : DEFAULT_WARN_PERCENT
  end

  # The line a warned answer ends with. Code, never the model.
  def warn_line(meter)
    "_#{[ "#{meter.percent}% of this app's monthly agent allowance is used.", meter.suggestion&.line ].compact.join(' ')}_"
  end

  # The whole reply to a message refused at the cap. Code, never the model.
  def cap_reply(meter)
    resets = meter.period_end.in_time_zone(ZONE).to_date.next_day.strftime("%b %-d")
    [ "This app has used its monthly agent allowance, so I can't answer this one. It resets #{resets}.",
      meter.suggestion&.line, "The app's owner can raise it." ].compact.join(" ")
  end

  def capped_count(souls, from, to)
    return 0 if souls.empty?

    AgentMessageEvent.joins("INNER JOIN agent_messages ON agent_messages.id = agent_message_events.agent_message_id")
                     .where(kind: "usage_capped", created_at: from...to)
                     .where(agent_messages: { soul_slug: souls }).count
  end

  def scope(souls, from, to, metered_only)
    scope = AgentMessage.where(status: "completed", soul_slug: Array(souls), completed_at: from...to)
                        .where("agent_messages.run_meta->>'usage_capped' IS NULL")
    metered_only ? scope.where("agent_messages.run_meta->>'audience' IN (?)", METERED_AUDIENCES) : scope
  end

  # One SELECT of COUNT(*) and a numeric-only SUM per summed key.
  def sums(scope, extra: [])
    columns = SUMMED.map do |key|
      Arel.sql("COALESCE(SUM(CASE WHEN jsonb_typeof(agent_messages.run_meta->'#{key}') = 'number' " \
               "THEN (agent_messages.run_meta->>'#{key}')::numeric END), 0) AS #{key}")
    end
    timed = Arel.sql("COUNT(*) FILTER (WHERE jsonb_typeof(agent_messages.run_meta->'duration_ms') = 'number') AS timed")
    AgentMessage.connection.select_all(scope.reorder(nil).select(Arel.sql("COUNT(*) AS messages"), timed, *columns, *extra).to_sql).to_a
  end

  def totals_from(row)
    return Totals.zero unless row

    Totals.new(messages: row["messages"].to_i, input_tokens: row["input_tokens"].to_i,
               cache_read_tokens: row["cache_read_tokens"].to_i, cache_creation_tokens: row["cache_creation_tokens"].to_i,
               output_tokens: row["output_tokens"].to_i, thinking_tokens: row["thinking_tokens"].to_i,
               cost_usd: row["total_cost_usd"].to_f, duration_ms: row["duration_ms"].to_i, timed: row["timed"].to_i)
  end
  private_class_method :scope, :sums, :totals_from, :capped_count

  # The upgrade a meter earns, decided by a rule in code (never by the model),
  # with the price read from config/workspace_packages.yml:
  #
  #   - projected to pass the allowance before the month ends (used so far,
  #     run forward at the month's average daily rate), or capped CAPPED_TWICE
  #     times this month
  #   - then the next package up with a bigger (or unlimited) allowance, at its
  #     price_monthly; with none, the configured top-up; with neither, "talk to us"
  #
  # nil for an unlimited meter, or one on track.
  class Suggestion
    attr_reader :kind, :tier, :tier_name, :price, :tokens, :reason

    def self.for(meter, packages: WorkspacePackage.all, topup: WorkspacePackage.cto_usage["topup"])
      return nil if meter.unlimited?

      reason = if meter.capped_count >= CAPPED_TWICE then :capped_twice
      elsif projected(meter) > meter.allowance then :projected
      end
      return nil unless reason

      ladder = packages.map(&:key)
      at = meter.tier && ladder.index(meter.tier)
      above = at ? packages.drop(at + 1) : packages
      better = above.find { |p| p.cto_monthly_tokens.nil? || p.cto_monthly_tokens > meter.allowance }
      return new(kind: :tier, tier: better.key, tier_name: better.name, price: better.price_monthly, reason: reason) if better

      topup = topup.is_a?(Hash) ? topup : {}
      if topup["tokens"].is_a?(Integer) && topup["price"].is_a?(Numeric)
        return new(kind: :topup, tokens: topup["tokens"], price: topup["price"], reason: reason)
      end

      new(kind: :talk, reason: reason)
    end

    # Tokens by month end at this month's average daily rate so far.
    def self.projected(meter)
      elapsed = [ (meter.now - meter.period_start) / 1.day, 1.0 ].max
      total = (meter.period_end - meter.period_start) / 1.day
      (meter.used / elapsed * total).ceil
    end

    def initialize(kind:, reason:, tier: nil, tier_name: nil, price: nil, tokens: nil)
      @kind = kind
      @reason = reason
      @tier = tier
      @tier_name = tier_name
      @price = price
      @tokens = tokens
    end

    def line
      case kind
      when :tier
        cost = price.nil? ? "" : " (#{price.zero? ? 'free' : "$#{price.to_i}/month"})"
        "#{tier_name}#{cost} raises it."
      when :topup then "A top-up of #{tokens.to_fs(:delimited)} tokens is $#{price}."
      else "Talk to us about a larger allowance."
      end
    end

    def as_json(*)
      { "kind" => kind.to_s, "tier" => tier, "tier_name" => tier_name, "price" => price, "tokens" => tokens,
        "reason" => reason.to_s, "line" => line }.compact
    end
  end
end
