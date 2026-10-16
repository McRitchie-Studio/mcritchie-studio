# The hub's morning CTO summary: ONE 07:00 America/Denver run
# (DailyAppReportJob, config/recurring.yml) reads every live studio-engine app's
# health for the same day and posts one Discord message through
# ReportDestinations under the registered key `daily_app_report`.
# Operator guide: docs/agents/system/daily-app-report.md.
#
#   DailyAppReport.run                         # today's window, delivered
#   DailyAppReport.run(ending: Time.zone.parse("2026-10-15 07:00 -06:00"))
#
# Every app reports the window that ENDS at the same 07:00 Denver, so a late run
# or a retry reports exactly the day an on-time run would have. The hub reads
# itself in-process (Studio::HealthReport); every other app answers
# GET <production_url>/_studio/health_report?ending=<iso8601> with a bearer token
# from ENV["HEALTH_TOKEN_<SLUG>"]. An app with no token is "not wired" and is not
# fetched; an app that cannot be read is "unreachable (<reason>)" plus an
# ErrorLog row, and the report still goes out for the rest.
#
# Counts only: no names or emails reach Discord (error messages are redacted).
module DailyAppReport
  REPORT_KEY = "daily_app_report".freeze
  ZONE = "America/Denver".freeze
  HOUR = 7 # the hour config/recurring.yml runs it
  HUB_SLUG = "mcritchie-studio".freeze
  TOKEN_PREFIX = "HEALTH_TOKEN_".freeze

  # One app's answer, normalized from either the JSON endpoint or the in-process
  # report. state is :ok, :not_wired or :unreachable.
  #   sections      [{ key:, title:, count:, failure: }]
  #   error_groups  [{ error_class:, message:, count: }]
  AppHealth = Struct.new(:slug, :name, :state, :reason, :sections, :error_kinds, :error_groups,
                         :engine_version, keyword_init: true) do
    def ok? = state == :ok
    def not_wired? = state == :not_wired
    def unreachable? = state == :unreachable
    def section(key) = Array(sections).find { |s| s[:key] == key }
    def error_count = section("errors")&.dig(:count).to_i
    def failed_sections = Array(sections).select { |s| s[:failure].present? }

    # :unreachable · :not_wired · :errors (errors, or a section that could not be
    # read) · :activity (signups or contacts, no errors) · :quiet.
    def category
      return state unless ok?
      return :errors if error_count.positive? || failed_sections.any?
      return :activity if Array(sections).any? { |s| s[:count].to_i.positive? }

      :quiet
    end
  end

  module_function

  # The window every app reports: the latest 07:00 Denver at or before `now`.
  def window_end(now = Time.current)
    Studio::HealthReport.window(now, zone: ZONE, hour: HOUR).end
  end

  def idempotency_key(ending) = "#{REPORT_KEY}:#{ending.in_time_zone(ZONE).to_date.iso8601}"

  # Live studio-engine apps with a production URL, catalog order. Live is
  # active, delinquent or showcase (AppCatalog::LIVE_STATUSES): Turf Monster and
  # Cyvasse are showcase. AppCatalog::UNANNOUNCED apps are left out, because
  # their name may not reach a post yet.
  def apps
    AppCatalog.apps.select do |app|
      app.engine && app.live? && app.production_url.present? && !AppCatalog::UNANNOUNCED.include?(app.slug)
    end
  end

  # "turf-monster" => "HEALTH_TOKEN_TURF_MONSTER"
  def token_env(slug) = "#{TOKEN_PREFIX}#{slug.to_s.upcase.tr('-', '_')}"

  # Read every app, build the message, deliver it. Returns the
  # ReportDestinations::Result (or the existing posted one when this day's
  # report already went out, without fetching anything).
  #
  # `healths` (slug => AppHealth) is a memo the caller may share: every app
  # read here lands in it, and an app already in it is not read again, so the
  # per-app CTO reports that follow in the same job (CtoReport) reuse this
  # morning's reads instead of fetching each app twice.
  def run(ending: window_end, fetcher: Fetcher.new, env: ENV, logger: Rails.logger, healths: {})
    ending = ending.in_time_zone(ZONE)
    key = idempotency_key(ending)
    if (done = ReportDelivery.find_by(idempotency_key: key)) && done.posted?
      logger.info("[daily-app-report] #{key} already posted: #{done.url}")
      return ReportDestinations::Result.new(status: :posted, message_id: done.message_external_id, url: done.url, delivery: done)
    end

    results = apps.map { |app| healths[app.slug] ||= health_for(app, ending, fetcher: fetcher, env: env) }
    message = Message.new(ending: ending, results: results).to_h
    result = ReportDestinations.deliver(REPORT_KEY, **message, idempotency_key: key)
    log_result(logger, key, result)
    # deliver recorded the failure (and an ErrorLog); the job retries it with
    # back-off under the same key, so it still posts at most once.
    ReportDeliveryJob.set(wait: 1.minute).perform_later(REPORT_KEY, **message, idempotency_key: key) if result.status == :failed
    result
  end

  def health_for(app, ending, fetcher:, env:)
    return hub_health(app, ending) if app.slug == HUB_SLUG

    token = env[token_env(app.slug)].to_s.strip
    return AppHealth.new(slug: app.slug, name: app.name, state: :not_wired) if token.empty?

    from_json(app, fetcher.fetch(app.production_url, token: token, ending: ending))
  rescue Fetcher::Error => e
    unreachable(app, e.message, e)
  end

  # The hub reads its own database: no HTTP, no token.
  def hub_health(app, ending)
    report = Studio::HealthReport.build(window: Studio::HealthReport.window_ending(ending, zone: ZONE))
    AppHealth.new(
      slug: app.slug, name: app.name, state: :ok, engine_version: Studio::VERSION,
      sections: report.sections.map { |s| { key: section_key(s.title), title: s.title, count: s.count.to_i, failure: s.failure } },
      error_kinds: report.error_kinds.to_i,
      error_groups: report.error_groups.map { |g| { error_class: g.error_class, message: g.message, count: g.count.to_i } }
    )
  rescue StandardError => e
    unreachable(app, "in-process #{e.class.name.demodulize}", e)
  end

  def from_json(app, body)
    raise Fetcher::Error, "unknown schema #{body['schema'].inspect}" unless body.is_a?(Hash) && body["schema"].to_i == 1

    sections = Array(body["sections"]).grep(Hash).map do |s|
      { key: s["key"].to_s, title: s["title"].to_s.presence || s["key"].to_s.humanize, count: s["count"].to_i,
        failure: s["failure"].presence&.to_s }
    end
    groups = Array(body["error_groups"]).grep(Hash).map do |g|
      { error_class: g["error_class"].to_s, message: g["message"].to_s, count: g["count"].to_i }
    end
    AppHealth.new(slug: app.slug, name: app.name, state: :ok, sections: sections, error_kinds: body["error_kinds"].to_i,
                  error_groups: groups, engine_version: body["engine_version"].presence&.to_s)
  end

  def section_key(title)
    key = title.to_s.parameterize(separator: "_")
    key == "contact_messages" ? "contacts" : key
  end

  # The line says "unreachable (<reason>)"; the ErrorLog row says which app.
  def unreachable(app, reason, error)
    log_error(app, reason, error)
    AppHealth.new(slug: app.slug, name: app.name, state: :unreachable, reason: reason)
  end

  def log_error(app, reason, error)
    wrapped = Fetcher::Error.new("#{app.slug} health report unreachable: #{reason}")
    wrapped.set_backtrace(error.backtrace || caller)
    log = ErrorLog.capture!(wrapped)
    log.update(target: App.find_by(slug: app.slug), target_name: "daily-app-report #{app.slug}")
  rescue StandardError => e
    Rails.logger.warn("[daily-app-report] could not write ErrorLog: #{e.class}")
  end

  def log_result(logger, key, result)
    line = "[daily-app-report] #{key} status=#{result.status}"
    line += " url=#{result.url}" if result.url.present?
    line += " reason=#{result.reason}" if result.reason.present?
    result.status == :failed ? logger.warn(line) : logger.info(line)
  end
end
