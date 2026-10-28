# The /applications index as two lists: the apps that are live, and the apps
# still waiting to launch, each with what the hub already knows about it.
#
#   list = ApplicationsWatchList.build(AppOwnership.visible_apps(user).to_a, admin: true)
#   list.live      # [Row] apps running for someone today
#   list.pending   # [Row] apps not launched yet, each with #why
#   list.other     # [Row] libraries and archived apps, listed for completeness
#
# LIVE comes from config/apps.yml through AppCatalog, the one record of every
# app's status: an app is live when its catalog status is live
# (AppCatalog::LIVE_STATUSES: active, delinquent or showcase) AND it has a
# production_url. Anything else that is not a library or archived is pending:
# a catalog app with no production URL yet, or an app the catalog does not name
# at all (a client app from the /build queue).
#
# Reads only the database and config. Nothing here calls Heroku or an app:
# health is drawn by the page as one lazy frame per live app
# (ApplicationsController#health), after the page has rendered.
module ApplicationsWatchList
  # Stages a task can be in while it is still work in progress (Task.live).
  OPEN_STAGES = (Task::STAGES - %w[shipped archived]).freeze

  # One open task, as the row needs it. Titles are an admin's only.
  OpenTask = Data.define(:slug, :title, :stage, :blocked)

  Row = Data.define(:app, :entry, :kind, :open_tasks, :mail, :warnings, :why) do
    def slug = app.slug
    def production_url = entry&.production_url
    def live? = kind == :live
    def pending? = kind == :pending
    def unannounced? = AppCatalog::UNANNOUNCED.include?(slug)
    # Whether the daily health report covers this app, so the page may lazy-load
    # its health frame (DailyAppReport.apps; read from config, no fetch).
    def health_reported? = DailyAppReport.apps.any? { |e| e.slug == slug }

    # "2 building, 1 designed", furthest along first; nil when none are open.
    def stage_summary
      return nil if open_tasks.empty?

      counts = open_tasks.map(&:stage).tally
      OPEN_STAGES.reverse.filter_map { |stage| "#{counts[stage]} #{Task::STAGE_LABELS[stage].downcase}" if counts[stage] }.join(", ")
    end

    # The open task furthest along, which is the next thing to land.
    def next_task = open_tasks.max_by { |task| OPEN_STAGES.index(task.stage) }
  end

  List = Data.define(:live, :pending, :other)

  module_function

  def build(apps, admin:, catalog: AppCatalog)
    library_slugs = catalog.libraries.map(&:slug)
    tasks = open_tasks_by_repo(apps.map(&:slug))
    mail = mail_by_domain(apps.map { |app| catalog.app(app.slug) })

    rows = apps.map do |app|
      entry = catalog.app(app.slug)
      kind = classify(app, entry, library_slugs)
      open = tasks.fetch(app.slug, [])
      row_mail = entry && mail[domain_of(entry.production_url)]
      Row.new(app: app, entry: entry, kind: kind, open_tasks: open, mail: row_mail,
              warnings: kind == :live ? warnings_for(app, entry, open) : [],
              why: kind == :pending ? why_pending(app, entry) : nil)
    end
    rows = rows.map { |row| row.with(open_tasks: row.open_tasks.map { |t| t.with(title: nil) }) } unless admin

    grouped = rows.group_by(&:kind)
    List.new(live: grouped.fetch(:live, []), pending: grouped.fetch(:pending, []), other: grouped.fetch(:other, []))
  end

  # :live, :pending or :other (a library, or an archived app).
  def classify(app, entry, library_slugs)
    return :other if library_slugs.include?(app.slug)
    return :pending if entry.nil?
    return :other if entry.archived?

    entry.live? && entry.production_url.present? ? :live : :pending
  end

  # Why the app is not live yet, in one short line.
  def why_pending(app, entry)
    return "No production URL yet" if entry && entry.production_url.blank?
    return "Preview #{app.preview_version} published; not launched" if app.preview_version.present?

    "Not launched; no production URL on record"
  end

  # What is off on a live app, from what the hub has already recorded: a
  # delinquent account, a backup that is owed or failing, a blocked task.
  def warnings_for(app, entry, open)
    warnings = []
    warnings << "Delinquent" if entry.status == "delinquent"
    if entry.backups_owed? && !entry.backups_watched?
      warnings << "Backups owed"
    elsif entry.backups_watched?
      line = DbBackupSweep.report_line(app.backup_status)
      warnings << line unless line.match?(/\ABackup \d/) # "Backup 02:04, 48 MB" is a fresh one
    end
    blocked = open.count(&:blocked)
    warnings << "#{blocked} blocked #{'task'.pluralize(blocked)}" if blocked.positive?
    warnings
  end

  # slug => [OpenTask], one query for every app on the page.
  def open_tasks_by_repo(slugs)
    return {} if slugs.empty?

    rows = Task.where(stage: OPEN_STAGES)
               .where("tasks.metadata -> 'devops' -> 'repositories' ?| array[:slugs]", slugs: slugs)
               .order(:created_at)
               .pluck(:slug, :title, :stage, :blocked_at, Arel.sql("tasks.metadata -> 'devops' -> 'repositories'"))
    rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(slug, title, stage, blocked_at, repos), out|
      task = OpenTask.new(slug: slug, title: title, stage: stage, blocked: stage == "building" && blocked_at.present?)
      (Array(repos) & slugs).each { |repo| out[repo] << task }
    end
  end

  # Mail is the Google Workspace on the app's own domain (WorkspaceAccount, the
  # allow-list of workspaces the hub holds access to): domain => status.
  def mail_by_domain(entries)
    domains = entries.compact.filter_map { |entry| domain_of(entry.production_url) }.uniq
    return {} if domains.empty?

    WorkspaceAccount.where(domain: domains).pluck(:domain, :status).to_h
  end

  # "https://www.turfmonster.media/x" => "turfmonster.media"
  def domain_of(url)
    host = URI.parse(url.to_s).host
    host&.downcase&.delete_prefix("www.")
  rescue URI::InvalidURIError
    nil
  end
end
