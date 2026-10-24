# Steffon's nightly agent job over the database backups (DbBackupSweepJob,
# config/recurring.yml, 03:30 America/Denver, after Heroku's 02:00 scheduled
# captures). Nightly backups and a monthly restore drill are a paid-plan benefit;
# config/apps.yml says which apps have them (`backups: true`,
# AppCatalog.backed_up_apps). For each, one run:
#
#   1. reads the app's Heroku Postgres transfers (HerokuClient) and finds the
#      latest completed backup;
#   2. records what it saw on the App row (apps.backup_status: finished_at, size,
#      state), which the 07:00 daily app report turns into one line per app;
#   3. when the latest completed backup is older than FRESH_WITHIN (26 h), or
#      there is none, starts a capture and marks the app missing;
#   4. opens or resolves two incidents on the floor the agent dispatcher uses
#      (AgentMailboxIncident): db_backup_missing and db_backup_sweep_failed.
#      AgentMessages::FloorAlert, every minute, posts each incident ONCE to the
#      ops channel and its recovery once.
#
# A read failure (API down, key rejected) marks that app unreadable and opens
# db_backup_sweep_failed; it never raises out of #call, so a dead API is one
# incident, not a crash. Inert, with one log line, until HEROKU_BACKUP_API_KEY
# is set: then nothing is read, recorded or opened.
#
# Steffon's SOP: docs/agents/agents/steffon/sops/db-restore-drill.md.
class DbBackupSweep
  TOKEN_ENV = "HEROKU_BACKUP_API_KEY".freeze
  FRESH_WITHIN = 26.hours
  ZONE = "America/Denver".freeze
  LOG = "[db-backup-sweep]".freeze
  MISSING = "db_backup_missing".freeze
  FAILED = "db_backup_sweep_failed".freeze

  # One app's verdict. state is "fresh", "missing" or "unreadable".
  Result = Struct.new(:slug, :heroku_app, :state, :finished_at, :size_bytes, :name, :reason, :capture,
                      keyword_init: true) do
    def fresh? = state == "fresh"
    def missing? = state == "missing"
    def unreadable? = state == "unreadable"

    def to_status(now)
      { "state" => state, "checked_at" => now.iso8601, "finished_at" => finished_at&.iso8601,
        "size_bytes" => size_bytes, "name" => name, "reason" => reason, "capture" => capture }.compact
    end
  end

  def self.configured?(env = ENV) = env[TOKEN_ENV].to_s.strip.present?

  def initialize(client: nil, apps: AppCatalog.backed_up_apps, env: ENV, logger: Rails.logger)
    @client = client
    @apps = apps
    @env = env
    @logger = logger
  end

  # Returns the Results, [] when inert.
  def call(now: Time.current)
    unless @client || self.class.configured?(@env)
      @logger.info("#{LOG} inert: #{TOKEN_ENV} is unset, nothing read " \
                   "(Steffon: docs/agents/agents/steffon/sops/db-restore-drill.md)")
      return []
    end

    results = @apps.map { |app| check(app, now) }
    results.each { |result| record(result, now) }
    reconcile(MISSING, results.select(&:missing?), now)
    reconcile(FAILED, results.select(&:unreadable?), now)
    @logger.info("#{LOG} #{results.map { |r| "#{r.slug}=#{r.state}" }.join(' ')}")
    results
  end

  # The latest completed, still-kept backup among Heroku transfers, as
  # { finished_at:, size_bytes:, name: }, or nil.
  def self.latest_backup(transfers)
    backups = Array(transfers).filter_map do |t|
      next unless t["from_type"] == "pg_dump" && t["to_type"] == "gof3r" && t["succeeded"] == true
      next if t["deleted_at"].present? || t["purged_at"].present?

      finished = parse_time(t["finished_at"]) or next
      prefix = t["schedule"].present? ? "a" : "b"
      { finished_at: finished, size_bytes: t["processed_bytes"].to_i, name: format("%s%03d", prefix, t["num"].to_i) }
    end
    backups.max_by { |b| b[:finished_at] }
  end

  # A backup started in the last two hours that has neither finished nor been
  # canceled.
  def self.backup_running?(transfers, now)
    Array(transfers).any? do |t|
      started = parse_time(t["created_at"])
      t["from_type"] == "pg_dump" && t["to_type"] == "gof3r" && t["finished_at"].blank? && t["canceled_at"].blank? &&
        started && started > now - 2.hours
    end
  end

  def self.parse_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  # --- the daily report's line ---------------------------------------------

  # "Backup 02:04, 48 MB" · "Backup MISSING" (plus " (capture started)" when
  # the sweep started one) · "Backup unread (HTTP 401 key
  # rejected)" · "Backup not checked" (no sweep has recorded this app, or none
  # since `now - FRESH_WITHIN`). `status` is an App#backup_status Hash.
  def self.report_line(status, now: Time.current)
    status = status.to_h
    checked = parse_time(status["checked_at"])
    return "Backup not checked" if checked.nil? || checked < now - FRESH_WITHIN
    return "Backup unread (#{status['reason'].presence || 'unknown'})" if status["state"] == "unreadable"

    finished = parse_time(status["finished_at"])
    if status["state"] == "missing" || finished.nil? || finished < checked - FRESH_WITHIN
      return [ "started", "in progress" ].include?(status["capture"]) ? "Backup MISSING (capture started)" : "Backup MISSING"
    end

    size = ActiveSupport::NumberHelper.number_to_human_size(status["size_bytes"].to_i)
    "Backup #{finished.in_time_zone(ZONE).strftime('%H:%M')}, #{size}"
  end

  # slug => line for every backed-up app, read from the App rows.
  def self.report_lines(apps: AppCatalog.backed_up_apps, now: Time.current)
    statuses = App.where(slug: apps.map(&:slug)).pluck(:slug, :backup_status).to_h
    apps.to_h { |app| [ app.slug, report_line(statuses[app.slug], now: now) ] }
  end

  # "Backups: 5 fresh, 1 missing" over the lines, counts only (no names, so an
  # unannounced app is never named), or nil when no app is backed up.
  def self.report_summary(lines)
    return nil if lines.empty?

    counts = lines.values.map do |line|
      if line.start_with?("Backup MISSING") then "missing"
      elsif line.start_with?("Backup unread") then "unread"
      elsif line == "Backup not checked" then "not checked"
      else "fresh"
      end
    end.tally
    parts = %w[fresh missing unread].push("not checked").filter_map { |k| "#{counts[k]} #{k}" if counts[k] }
    "Backups: #{parts.join(', ')}"
  end

  # --- the alert text (AgentMessages::FloorAlert posts it) ------------------

  # Names an app by slug, except an AppCatalog::UNANNOUNCED one.
  def self.names(apps)
    apps = Array(apps)
    shown = apps.reject { |a| AppCatalog::UNANNOUNCED.include?(a["slug"]) }.map { |a| a["slug"] }
    hidden = apps.size - shown.size
    shown << "#{hidden} unannounced app#{'s' if hidden > 1}" if hidden.positive?
    shown.join(", ")
  end

  def self.alert_text(incident)
    apps = Array(incident.detail["apps"])
    case incident.kind
    when MISSING
      failed = apps.reject { |a| [ "started", "in progress" ].include?(a["capture"]) }
      capture = failed.empty? ? "The sweep started a capture for each." : "Capture failed for #{names(failed)}."
      "Database backup missing: no completed Heroku backup in #{FRESH_WITHIN.inspect} for #{names(apps)}. " \
        "#{capture} Steffon: SOP db-restore-drill."
    when FAILED
      reasons = apps.map { |a| a["reason"] }.compact.uniq.first(3).join("; ")
      "Database backup sweep could not read #{apps.size} app(s): #{names(apps)} (#{reasons}). Whether a backup " \
        "is missing is unknown until it reads again. Steffon: SOP db-restore-drill."
    end
  end

  def self.recovery_text(incident, lasted_minutes)
    case incident.kind
    when MISSING then "Database backups fresh again: every backed-up app has one from the last #{FRESH_WITHIN.inspect} " \
                      "(incident lasted #{lasted_minutes} min)."
    when FAILED then "Database backup sweep reading again (incident lasted #{lasted_minutes} min)."
    end
  end

  private

  def client = (@client ||= HerokuClient.new(token: @env[TOKEN_ENV].to_s.strip))

  def check(app, now)
    transfers = client.transfers(app.heroku_app)
    latest = self.class.latest_backup(transfers)
    base = { slug: app.slug, heroku_app: app.heroku_app, finished_at: latest&.dig(:finished_at),
             size_bytes: latest&.dig(:size_bytes), name: latest&.dig(:name) }
    return Result.new(**base, state: "fresh") if latest && latest[:finished_at] >= now - FRESH_WITHIN

    Result.new(**base, state: "missing", capture: capture(app, transfers, now))
  rescue HerokuClient::Error => e
    Result.new(slug: app.slug, heroku_app: app.heroku_app, state: "unreadable", reason: e.message)
  end

  # A retried run (or a second one the same night) finds its own capture still
  # running and does not start another.
  def capture(app, transfers, now)
    return "in progress" if self.class.backup_running?(transfers, now)

    client.capture(app.heroku_app)
    @logger.warn("#{LOG} #{app.slug}: no backup in #{FRESH_WITHIN.inspect}; capture started")
    "started"
  rescue HerokuClient::Error => e
    @logger.warn("#{LOG} #{app.slug}: no backup in #{FRESH_WITHIN.inspect}; capture failed (#{e.message})")
    "failed (#{e.message})"
  end

  def record(result, now)
    App.where(slug: result.slug).update_all(backup_status: result.to_status(now), updated_at: now)
  rescue ActiveRecord::ActiveRecordError => e
    @logger.warn("#{LOG} #{result.slug}: could not record backup status (#{e.class})")
  end

  # One open incident per kind: opened on the first failing run, its detail kept
  # current while it lasts, resolved on the first passing run.
  def reconcile(kind, failing, now)
    open = AgentMailboxIncident.open_for(kind)
    detail = { "apps" => failing.map { |r| r.to_h.slice(:slug, :heroku_app, :reason, :capture).compact.stringify_keys } }
    if failing.any? && open.nil?
      AgentMailboxIncident.create!(kind: kind, detail: detail, opened_at: now)
      @logger.warn("#{LOG} incident opened: #{kind} #{detail.to_json}")
    elsif failing.any?
      open.update!(detail: detail)
    elsif open
      open.update!(resolved_at: now)
      @logger.info("#{LOG} incident resolved: #{kind}")
    end
  rescue ActiveRecord::RecordNotUnique
    nil # a concurrent run opened it first
  end
end
