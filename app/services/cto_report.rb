# The per-app CTO morning reports: each app with a CTO (config/cto_reports.yml)
# gets its own Discord message at 07:00 America/Denver, in that CTO's voice,
# under its own report key `cto_report:<domain>`, so Alex picks a channel per
# app at /admin/report_destinations. It rides DailyAppReportJob after the
# combined daily_app_report, sharing that run's health reads (one fetch per app
# per morning). Operator guide: docs/agents/system/daily-app-report.md.
#
#   CtoReport.run                                  # today's window
#   CtoReport.run(ending: DailyAppReport.window_end, healths: {})
#
# DETERMINISTIC. The voice is a fixed per-soul template (CtoReport::Voice); every
# number comes from code: the app's health report (DailyAppReport.health_for)
# and, for the hub, the board's stage counts, the tasks shipped in the window
# and the release in flight, and one usage line: the CTO domain's answers in
# the window (AgentUsage). No model call. Counts only: no names or emails.
#
# Skips, each a log line and never an error: an app with no
# HEALTH_TOKEN_<SLUG> (not wired), a destination with no channel or turned off
# (ReportDestinations answers :not_configured / :disabled), a day already
# posted. An unreachable app still reports, saying so.
module CtoReport
  CONFIG_PATH = Rails.root.join("config/cto_reports.yml")
  DOMAINS_PATH = Rails.root.join("config/agent_domains.yml")
  KEY_PREFIX = "cto_report".freeze

  # One configured CTO report: the domain key, the catalog app it reads, the soul.
  Entry = Struct.new(:domain, :app, :soul, keyword_init: true) do
    def report_key = "#{KEY_PREFIX}:#{domain}"
    def idempotency_key(ending) = "#{report_key}:#{ending.in_time_zone(DailyAppReport::ZONE).to_date.iso8601}"
    def hub? = app.slug == DailyAppReport::HUB_SLUG
  end

  # The hub's board facts for the window, counts only.
  #   stages     { "designed" => 3, … } for the open stages (not shipped, not archived)
  #   blocked    build-stage tasks carrying a block
  #   shipped    tasks that reached shipped inside the window
  #   release    { stage:, tasks: } for the release in flight, or nil
  BoardFacts = Struct.new(:stages, :blocked, :shipped, :release, keyword_init: true) do
    def building = stages.values_at("designed", "building").sum(&:to_i)
    def in_review = stages.fetch("submitted", 0)
    def deploying = stages.values_at("reviewed", "assembled").sum(&:to_i)
  end
  OPEN_STAGES = %w[designed building submitted reviewed assembled].freeze

  module_function

  def config(path = CONFIG_PATH) = (YAML.safe_load_file(path) || {}).fetch("ctos", {}) || {}

  # The CTO soul whose own Discord bot posts `report_key` (`cto_report:<domain>`),
  # read from config/cto_reports.yml; nil for a key that is not a CTO report or
  # names no configured domain. ReportDestinations asks this to pick the bot.
  def soul_for(report_key, config: self.config) = souls_by_report_key(config)[report_key.to_s]

  # { "cto_report:<domain>" => soul } for every configured CTO, built from the
  # config's own keys, so a report key is matched, never parsed.
  def souls_by_report_key(config = self.config)
    config.each_with_object({}) do |(domain, row), map|
      soul = row.is_a?(Hash) ? row["soul"].to_s.presence : nil
      map["#{KEY_PREFIX}:#{domain}"] = soul if soul
    end
  end

  # Domain keys marked `internal: true` in config/agent_domains.yml.
  def internal_domains(path = DOMAINS_PATH)
    domains = (YAML.safe_load_file(path) || {}).fetch("domains", {}) || {}
    domains.select { |_key, entry| entry.is_a?(Hash) && entry["internal"] }.keys
  end

  # The CTO reports that may run: configured, on a live studio-engine app
  # (DailyAppReport.apps already drops AppCatalog::UNANNOUNCED), never an
  # internal domain or an unannounced slug. Config order.
  def entries(config: self.config, apps: DailyAppReport.apps, internal: internal_domains)
    by_slug = apps.index_by(&:slug)
    config.filter_map do |domain, row|
      next unless row.is_a?(Hash)
      next if internal.include?(domain.to_s)

      slug = row["app"].to_s
      next if AppCatalog::UNANNOUNCED.include?(slug)
      next unless (app = by_slug[slug])

      Entry.new(domain: domain.to_s, app: app, soul: row["soul"].to_s)
    end
  end

  # Deliver every CTO report for the window ending `ending`. `healths` is a
  # slug => DailyAppReport::AppHealth memo shared with the combined report, so
  # an app read once this morning is not read again. Returns
  # { report_key => ReportDestinations::Result or :not_wired }.
  def run(ending: DailyAppReport.window_end, healths: {}, fetcher: DailyAppReport::Fetcher.new, env: ENV,
          logger: Rails.logger, entries: self.entries)
    ending = ending.in_time_zone(DailyAppReport::ZONE)
    entries.to_h do |entry|
      [ entry.report_key, run_one(entry, ending, healths: healths, fetcher: fetcher, env: env, logger: logger) ]
    end
  end

  def run_one(entry, ending, healths:, fetcher:, env:, logger:)
    key = entry.idempotency_key(ending)
    if (done = ReportDelivery.find_by(idempotency_key: key)) && done.posted?
      logger.info("[cto-report] #{key} already posted: #{done.url}")
      return ReportDestinations::Result.new(status: :posted, message_id: done.message_external_id, url: done.url, delivery: done)
    end

    health = healths[entry.app.slug] ||= DailyAppReport.health_for(entry.app, ending, fetcher: fetcher, env: env)
    if health.not_wired?
      logger.info("[cto-report] #{key} skipped: #{entry.app.slug} is not wired (no #{DailyAppReport.token_env(entry.app.slug)})")
      return :not_wired
    end

    board = entry.hub? ? board_facts(ending) : nil
    message = Message.new(entry: entry, ending: ending, health: health, board: board, usage: usage_for(entry, ending)).to_h
    result = ReportDestinations.deliver(entry.report_key, **message, idempotency_key: key)
    log_result(logger, key, result)
    ReportDeliveryJob.set(wait: 1.minute).perform_later(entry.report_key, **message, idempotency_key: key) if result.status == :failed
    result
  rescue StandardError => e
    # One app's report never stops the next one's.
    ErrorLog.capture!(e)
    logger.warn("[cto-report] #{key} crashed: #{e.class}")
    e
  end

  # The board as of now, and what shipped in the 24 hours ending `ending`. A
  # shipped task archives when the next release ships, so a second release
  # inside the window would hide the first one's tasks: count by completed_at
  # (stamped on the move to shipped) across shipped AND archived.
  def board_facts(ending)
    counts = Task.where(stage: OPEN_STAGES).group(:stage).count
    release = Release.current
    BoardFacts.new(
      stages: OPEN_STAGES.index_with { |s| counts.fetch(s, 0) },
      blocked: Task.where(stage: Task::BUILD_STAGES).where.not(blocked_at: nil).count,
      shipped: Task.where(stage: %w[shipped archived], completed_at: (ending - 1.day)..ending).count,
      release: release && { stage: (release.current_stage || release.state).to_s, tasks: release.tasks.count }
    )
  end

  # The CTO's own answers in the 24 hours ending `ending` (AgentUsage), or nil
  # for a domain no routed soul answers for (no usage line then).
  def usage_for(entry, ending)
    souls = AgentUsage.souls_for(entry.domain)
    souls.any? ? AgentUsage.totals(souls: souls, from: ending - 1.day, to: ending) : nil
  end

  def log_result(logger, key, result)
    line = "[cto-report] #{key} status=#{result.status}"
    line += " url=#{result.url}" if result.url.present?
    line += " reason=#{result.reason}" if result.reason.present?
    result.status == :failed ? logger.warn(line) : logger.info(line)
  end
end
