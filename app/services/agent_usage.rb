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
# WHAT COUNTS AGAINST AN ALLOWANCE: the answers to client senders
# (run_meta.audience, stamped by the board at complete). Public answers are
# metered SEPARATELY (Meter#public_used): they never consume the app's
# allowance, so a stranger can never exhaust what the client paid for (Alex,
# 2026-10-16). Owner and team answers are counted in the totals but never
# metered and never capped. An answer from before this release carries no
# audience and is not metered (only the owner was answered then).
#
# DOLLARS are for admins. Totals#without_cost drops the CLI's cost figure, and
# totals_line then prints tokens only: a non-admin owner's page and JSON read
# tokens and the meter, never a price.
#
# THE TOKENS an allowance counts are input + cache read + cache write + output
# (thinking is inside output). No price is computed here: total_cost_usd is the
# CLI's own figure, shown as reported.
module AgentUsage
  ZONE = DailyAppReport::ZONE
  METERED_AUDIENCES = %w[client].freeze
  # Metered on its own line, never against the allowance.
  PUBLIC_AUDIENCES = %w[public].freeze
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

    # The same totals with no dollar figure, for a viewer who is not an admin.
    def without_cost = dup.tap { |t| t.cost_usd = nil }
    def cost? = !cost_usd.nil?

    def as_json(*)
      { "messages" => messages, "tokens" => tokens, "input_tokens" => input_tokens,
        "cache_read_tokens" => cache_read_tokens, "cache_creation_tokens" => cache_creation_tokens,
        "output_tokens" => output_tokens, "thinking_tokens" => thinking_tokens,
        "cost_usd" => cost_usd&.round(4), "avg_duration_ms" => avg_duration_ms }.then { |h| cost? ? h : h.except("cost_usd") }
    end
  end

  # One app's month. `allowance` nil is unlimited (no tier, a blank
  # cto_monthly_tokens, or an admin's lift). `used` is the metered tokens.
  # `public_used` is the public's tokens this month: shown, never counted in `used`.
  Meter = Struct.new(:app_slug, :domain, :tier, :tier_name, :allowance, :used, :public_used, :totals, :lifted,
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

    # The meter for a viewer who is not an admin: the same numbers, no dollars.
    def without_cost = dup.tap { |m| m.totals = totals.without_cost }

    def as_json(*)
      { "app" => app_slug, "domain" => domain, "tier" => tier, "allowance" => allowance, "used" => used,
        "public_used" => public_used.to_i,
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

  # The souls and channel_ref a no-domain app is metered on: a client app's one
  # `client_cto` (AppCto row), or a configured CTO (config/cto_reports.yml, e.g.
  # Cyvasse's tyrion) that serves no domain, each on THAT app's rows only. [[], nil]
  # for an app with neither.
  def undomained_souls(app_slug)
    cto = AppOwnership.cto_for_app(app_slug)
    cto ? [ [ cto.soul ], app_slug.to_s ] : [ [], nil ]
  end

  def month_range(now = Time.current)
    local = now.in_time_zone(ZONE)
    [ local.beginning_of_month, local.end_of_month ]
  end

  # Sum the run summaries of completed answers by these souls in [from, to).
  # metered_only: true (the client answers the allowance counts), :public (the
  # public's, metered apart), or false (every answer).
  # ref: one app's rows only (a client CTO's channel_ref), for the one
  # `client_cto` soul that answers every client app.
  def totals(souls:, from:, to:, metered_only: false, ref: nil)
    rows = sums(scope(souls, from, to, metered_only, ref: ref)).first
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
  # The capped count only matters to the upgrade rule, which an unlimited meter
  # never runs, so an app with no allowance skips that query.
  #
  # A client app (no domain, an AppCto row) is metered on the one `client_cto`
  # soul's answers in THAT app's chat (channel_ref), never another client's.
  def meter(app, now: Time.current, registry: self.registry)
    domain = domain_for_app(app.slug, registry: registry)
    start, finish = month_range(now)
    souls = souls_for(domain, registry: registry)
    ref = nil
    if domain.nil?
      souls, ref = undomained_souls(app.slug)
    end
    package = app.package_tier.present? ? WorkspacePackage.find(app.package_tier) : nil
    allowance = allowance_for(app)
    Meter.new(app_slug: app.slug, domain: domain, tier: app.package_tier, tier_name: package&.name,
              allowance: allowance, lifted: app.cto_cap_lifted_at.present?,
              used: souls.empty? ? 0 : totals(souls: souls, from: start, to: now, metered_only: true, ref: ref).tokens,
              public_used: souls.empty? ? 0 : totals(souls: souls, from: start, to: now, metered_only: :public, ref: ref).tokens,
              totals: souls.empty? ? Totals.zero : totals(souls: souls, from: start, to: now, ref: ref),
              capped_count: allowance.nil? ? 0 : capped_count(souls, start, now, ref: ref),
              period_start: start, period_end: finish, now: now, warn_percent: warn_percent)
  end

  # The meter an APP OWNER's answers are held to (AgentMessages::Answerers
  # #app_owner_thread?): the app's own meter, and when its tier names no
  # allowance, config/agent_answerers.yml `app_owners.default_monthly_tokens`.
  # An admin's lift still removes the cap. Their answers are stamped audience
  # `client`, so they count in `used` like any client's.
  def owner_meter(app, now: Time.current, registry: self.registry, answerers: AgentMessages::Answerers.current)
    base = meter(app, now: now, registry: registry)
    fallback = answerers.app_owners&.default_monthly_tokens
    return base if base.lifted || !base.unlimited? || fallback.nil?

    start, = month_range(now)
    souls, ref = base.domain.nil? ? undomained_souls(app.slug) : [ souls_for(base.domain, registry: registry), nil ]
    base.dup.tap do |m|
      m.allowance = fallback
      m.capped_count = capped_count(souls, start, now, ref: ref)
    end
  end

  # The meter a chat page shows `user` for `app`: the owner meter when the
  # app-owner rule answers them there, else the app's meter.
  def chat_meter(app, user:, soul:, now: Time.current, answerers: AgentMessages::Answerers.current)
    person = user && AgentMessages::WebIngest.existing_person(user)
    # The same people the rule answers: no person yet (their first message makes
    # a public one), or a public or client person. Owner and team never.
    eligible = person.nil? || AgentMessages::Answerers::APP_OWNER_ROLES.include?(person.role)
    owner = user && eligible && answerers.app_owner_user?(user, app_slug: app.slug, soul: soul)
    owner ? owner_meter(app, now: now, answerers: answerers) : meter(app, now: now)
  end

  # The check before a run is claimed. Owner and team senders are never capped
  # (and never metered, so they cost no query). For anyone else: the app their
  # soul's domain serves, its meter, and :stop at 100%, :warn at warn_percent.
  # A public sender never adds to `used`, but is still stopped once the
  # client's allowance is spent: the app's cap holds for everyone it meters.
  #
  # `meters` caches each app's meter for the length of one claim
  # (AgentMessage.claim! passes a Hash), so a claim that skips several capped
  # candidates of one app reads its meter once.
  def gate(message, now: Time.current, registry: self.registry, meters: nil)
    return Gate.new(state: :ok) if UNCAPPED_AUDIENCES.include?(message.usage_audience)

    # An app owner's own thread names its app in channel_ref (set by WebIngest
    # from the route), whether or not the CTO serves a domain (Cyvasse's does not).
    owner_row = AgentMessages::Answerers.current.app_owner_thread?(message)
    app_slug = if owner_row || message.soul_slug == AppCto::SOUL
                 message.channel_ref
               else
                 domain = registry.domain_key_for(message.soul_slug) || registry.front_door(message.soul_slug)&.dig("key")
                 domain && registry.domains.dig(domain, "app")
               end
    app = app_slug && App.find_by(slug: app_slug)
    return Gate.new(state: :ok) unless app

    if owner_row
      read = -> { owner_meter(app, now: now, registry: registry) }
      key = "owner:#{app.slug}"
    else
      return Gate.new(state: :ok) unless allowance_for(app)

      read = -> { meter(app, now: now, registry: registry) }
      key = app.slug
    end
    meter = meters ? (meters[key] ||= read.call) : read.call
    return Gate.new(state: :ok) if meter.unlimited?

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

  # The whole reply to a message refused at the cap. Code, never the model. A
  # public sender reads a plain line: no meter, no price, no upgrade (the meter
  # is the owner's, never the public's).
  def cap_reply(meter, audience: nil)
    resets = meter.period_end.in_time_zone(ZONE).to_date.next_day.strftime("%b %-d")
    if PUBLIC_AUDIENCES.include?(audience.to_s)
      return "I can't answer right now. Please try again after #{resets}."
    end

    [ "This app has used its monthly agent allowance, so I can't answer this one. It resets #{resets}.",
      meter.suggestion&.line, "Upgrade your plan or contact us." ].compact.join(" ")
  end

  # "12 answers, 230,400 tokens (in 1,200 · cache read 200,000 · cache write
  # 20,400 · out 8,800), $1.23, avg 6.2s." Shared by the usage ask, the CTO
  # morning report and the app page.
  def totals_line(totals)
    return "no answers." if totals.empty?

    kinds = [ "in #{fmt(totals.input_tokens)}", "cache read #{fmt(totals.cache_read_tokens)}",
              "cache write #{fmt(totals.cache_creation_tokens)}", "out #{fmt(totals.output_tokens)}" ].join(" · ")
    avg = totals.avg_duration_ms ? ", avg #{(totals.avg_duration_ms / 1000.0).round(1)}s" : ""
    cost = totals.cost? ? ", $#{format('%.2f', totals.cost_usd)}" : ""
    "#{totals.messages} #{'answer'.pluralize(totals.messages)}, #{fmt(totals.tokens)} tokens (#{kinds})#{cost}#{avg}."
  end

  # "Allowance: 42% of 1,000,000 tokens used (Builder)." or "Allowance: unlimited (Team)."
  def allowance_line(meter)
    tier = meter.tier_name ? " (#{meter.tier_name})" : " (no tier)"
    return "Allowance: unlimited, cap lifted by an admin#{tier}." if meter.lifted
    return "Allowance: unlimited#{tier}." if meter.unlimited?

    line = "Allowance: #{meter.percent}% of #{fmt(meter.allowance)} tokens used#{tier}."
    meter.suggestion ? "#{line} #{meter.suggestion.line}" : line
  end

  def fmt(number) = number.to_i.to_fs(:delimited)

  def capped_count(souls, from, to, ref: nil)
    return 0 if souls.empty?

    messages = { soul_slug: souls }
    messages[:channel_ref] = ref if ref
    AgentMessageEvent.joins("INNER JOIN agent_messages ON agent_messages.id = agent_message_events.agent_message_id")
                     .where(kind: "usage_capped", created_at: from...to)
                     .where(agent_messages: messages).count
  end

  def scope(souls, from, to, metered_only, ref: nil)
    scope = AgentMessage.where(status: "completed", soul_slug: Array(souls), completed_at: from...to)
                        .where("agent_messages.run_meta->>'usage_capped' IS NULL")
    scope = scope.where(channel_ref: ref) if ref
    case metered_only
    when :public then scope.where("agent_messages.run_meta->>'audience' IN (?)", PUBLIC_AUDIENCES)
    when true then scope.where("agent_messages.run_meta->>'audience' IN (?)", METERED_AUDIENCES)
    else scope
    end
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
