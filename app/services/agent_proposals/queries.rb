module AgentProposals
  # The read-only queries a domain agent's `ask` capabilities name
  # (config/agent_domains.yml `query:`). CODE, with bounded params the registry
  # already checked: no model writes SQL, and no query reads another app's
  # database (a satellite is read through its own health endpoint).
  #
  # FORMATTED DETERMINISTICALLY. Each query returns the text that is posted, not
  # data for a model to retell: the numbers come from code and reach the thread
  # exactly as counted, the answer costs no Claude run and no wait on the
  # dispatcher, and the format is pinned by tests. The soul already spoke when it
  # proposed the ask; the result is the board's.
  #
  # Counts only, as the daily app report: no names or emails, and error
  # classes without their messages.
  module Queries
    NAMES = %w[board_status recently_shipped release_status app_health usage].freeze
    # The accepted → release → main ladder, in order (Task::DEPLOY_STAGES before shipped).
    LADDER_STAGES = %w[submitted reviewed assembled].freeze
    SHIPPED_LISTED = 15
    ERROR_CLASSES_LISTED = 3

    class Unknown < StandardError; end
    class Unavailable < StandardError; end

    module_function

    # The text for one confirmed ask. `app` is the domain's App slug.
    def run(name, params, app: nil, now: Time.current, fetcher: DailyAppReport::Fetcher.new, env: ENV)
      raise Unknown, "no query named #{name.inspect}" unless NAMES.include?(name.to_s)

      params = (params || {}).to_h.stringify_keys
      case name.to_s
      when "board_status" then board_status
      when "recently_shipped" then recently_shipped(days: params.fetch("days", 7).to_i, now: now)
      when "release_status" then release_status
      when "app_health" then app_health(app, days: params.fetch("days", 1).to_i, fetcher: fetcher, env: env, now: now)
      when "usage" then usage(app, now: now)
      end
    end

    def board_status
      stages = Task::STAGES - %w[archived]
      counts = Task.where(stage: stages).group(:stage).count
      blocked = Task.where(stage: Task::BUILD_STAGES).where.not(blocked_at: nil).count
      line = stages.map { |stage| "#{stage} #{counts.fetch(stage, 0)}" }.join(" · ")
      "Board now: #{line}#{blocked.positive? ? " (#{blocked} blocked)" : ''}."
    end

    def recently_shipped(days:, now:)
      scope = Task.where(stage: "shipped").where(completed_at: (now - days.days)..now)
      total = scope.count
      return "Nothing shipped in the last #{days} day#{'s' unless days == 1}." if total.zero?

      rows = scope.order(completed_at: :desc).limit(SHIPPED_LISTED).map do |task|
        "- `#{task.slug}` #{task.title.to_s.squish[0, 80]} (#{task.completed_at.in_time_zone(DailyAppReport::ZONE).strftime('%b %-d')})"
      end
      more = total > rows.size ? "\n…and #{total - rows.size} more." : ""
      "Shipped in the last #{days} day#{'s' unless days == 1} (#{total}):\n#{rows.join("\n")}#{more}"
    end

    # The release ladder, read in process (no Heroku, no git): the active release
    # (Release.current) with its slug, state, stage and member count; the tasks
    # waiting on each rung; and the last release shipped.
    def release_status
      counts = Task.where(stage: LADDER_STAGES).group(:stage).count
      ladder = LADDER_STAGES.map { |stage| "#{stage} #{counts.fetch(stage, 0)}" }.join(" · ")
      release = Release.current
      now_line = if release
                   stage = release.current_stage
                   members = release.tasks.count
                   "Release now: `#{release.slug}` #{release.state}#{", stage #{stage.tr('_', ' ')}" if stage}, " \
                     "#{members} task#{'s' unless members == 1} aboard."
                 else
                   "No release is open."
                 end
      last = Release.last_shipped
      shipped_at = last && (last.shipped_at || last.created_at)
      last_line = last ? " Last shipped: `#{last.slug}` (#{shipped_at.in_time_zone(DailyAppReport::ZONE).strftime('%b %-d')})." : ""
      "#{now_line} Ladder: #{ladder}.#{last_line}"
    end

    # The domain's CTO usage this month and today, and the app's allowance
    # (AgentUsage, docs/agents/system/agent-usage.md). Every answer counts in the
    # totals; only client and public answers count against the allowance. The
    # suggestion and its price are the meter's, from config, never the model's.
    def usage(slug, now:)
      app = App.find_by(slug: slug.to_s)
      raise Unavailable, "#{slug.inspect} has no app record" unless app

      meter = AgentUsage.meter(app, now: now)
      today = AgentUsage.daily(meter.domain, days: 1, now: now).last&.last || AgentUsage::Totals.zero
      month = now.in_time_zone(AgentUsage::ZONE).strftime("%B")
      "#{app.name} agent usage, #{month} so far: #{AgentUsage.totals_line(meter.totals)} " \
        "Today: #{AgentUsage.totals_line(today)} #{AgentUsage.allowance_line(meter)}"
    end

    # Signups and errors summed over `days` daily health-report windows (each
    # ends at 07:00 America/Denver, as the daily app report reads them), through
    # DailyAppReport.health_for: the hub in-process, a satellite over HTTP.
    def app_health(slug, days:, fetcher:, env:, now:)
      app = AppCatalog.app(slug)
      raise Unavailable, "#{slug.inspect} is not in the app catalog" unless app

      last = DailyAppReport.window_end(now)
      reports = (0...days).map { |i| DailyAppReport.health_for(app, last - i.days, fetcher: fetcher, env: env) }
      if (bad = reports.find { |r| !r.ok? })
        reason = bad.not_wired? ? "its health report is not wired here" : "its health report could not be read (#{bad.reason})"
        return "#{app.name}: #{reason}, so I have no numbers."
      end

      signups = reports.sum { |r| r.section("signups")&.dig(:count).to_i }
      errors = reports.sum(&:error_count)
      classes = Hash.new(0)
      reports.each { |r| Array(r.error_groups).each { |g| classes[g[:error_class].to_s] += g[:count].to_i } }
      top = classes.sort_by { |k, v| [ -v, k ] }.first(ERROR_CLASSES_LISTED).map { |k, v| "#{k} ×#{v}" }
      span = days == 1 ? "the day" : "the #{days} days"
      text = "#{app.name}, #{span} to #{last.strftime('%b %-d, %-l:%M %p %Z')}: " \
             "#{signups} signup#{'s' unless signups == 1}, #{errors} error#{'s' unless errors == 1}."
      top.any? ? "#{text} Most frequent: #{top.join(', ')}." : text
    end
  end
end
