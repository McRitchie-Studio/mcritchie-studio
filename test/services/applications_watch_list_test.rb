require "test_helper"

# [unit] ApplicationsWatchList: the /applications split. Live is AppCatalog's
# word (a live status plus a production URL); everything else that is not a
# library or archived is pending, with a reason and its open tasks.
class ApplicationsWatchListTest < ActiveSupport::TestCase
  # A catalog double: the real entries, with any slug swapped for a variant.
  FakeCatalog = Struct.new(:entries, :libraries) do
    def app(slug) = entries[slug.to_s]
  end

  def catalog(overrides = {})
    entries = AppCatalog.apps.to_h { |entry| [ entry.slug, entry ] }.merge(overrides)
    FakeCatalog.new(entries, AppCatalog.libraries)
  end

  def task!(title, stage, repos, **attrs)
    Task.create!(title: title, stage: stage, metadata: { "devops" => { "repositories" => repos } }, **attrs)
  end

  def app!(slug, **attrs) = App.find_by(slug: slug) || App.create!(slug: slug, name: slug.titleize, **attrs)

  test "[unit] a live catalog app with a URL is live; a client app, a URL-less app, a library and an archived app are not" do
    apps = [ apps(:turf_monster), app!("pawsome"), app!("chain-ops"), app!("studio-engine"), app!("rolio") ]
    list = ApplicationsWatchList.build(apps, admin: true,
                                             catalog: catalog("rolio" => AppCatalog.app("rolio").with(production_url: nil)))

    assert_equal %w[turf-monster], list.live.map(&:slug)
    assert_equal %w[pawsome rolio], list.pending.map(&:slug).sort
    assert_equal %w[chain-ops studio-engine], list.other.map(&:slug).sort
    assert_equal "No production URL yet", list.pending.find { |r| r.slug == "rolio" }.why
    assert_equal "Not launched; no production URL on record", list.pending.find { |r| r.slug == "pawsome" }.why
  end

  test "[unit] a pending row counts its open tasks by stage, names the furthest along, and hides titles from an owner" do
    pawsome = app!("pawsome", preview_version: "v3")
    task!("Pawsome signup", "designed", [ "pawsome" ])
    task!("Pawsome checkout", "submitted", [ "pawsome", "mcritchie-studio" ])
    task!("Pawsome launch", "shipped", [ "pawsome" ])
    task!("Someone else's", "building", [ "turf-monster" ])

    row = ApplicationsWatchList.build([ pawsome ], admin: true).pending.first
    assert_equal "Preview v3 published; not launched", row.why
    assert_equal 2, row.open_tasks.size, "shipped and other repos' tasks are not open work here"
    assert_equal "1 submitted, 1 designed", row.stage_summary
    assert_equal "Pawsome checkout", row.next_task.title

    owner_row = ApplicationsWatchList.build([ pawsome ], admin: false).pending.first
    assert_equal "1 submitted, 1 designed", owner_row.stage_summary
    assert_nil owner_row.next_task.title, "an owner reads counts, never task titles"
  end

  test "[unit] a live app warns on a blocked task and on a delinquent account; a clean one has no warnings" do
    turf = apps(:turf_monster)
    task!("Blocked fix", "building", [ "turf-monster" ], blocked_at: Time.current)
    delinquent = catalog("mcritchie-studio" => AppCatalog.app("mcritchie-studio").with(status: "delinquent", backups: false, database: false))

    list = ApplicationsWatchList.build([ turf, apps(:mcritchie_studio) ], admin: true, catalog: delinquent)
    assert_includes list.live.find { |r| r.slug == "turf-monster" }.warnings, "1 blocked task"
    assert_equal [ "Delinquent" ], list.live.find { |r| r.slug == "mcritchie-studio" }.warnings
  end

  test "[unit] a watched backup that is missing is a warning; a fresh one is not" do
    hub = apps(:mcritchie_studio)
    assert AppCatalog.app("mcritchie-studio").backups_watched?, "the hub is a watched backup (AppCatalog)"

    hub.update!(backup_status: { "checked_at" => Time.current.iso8601, "state" => "missing" })
    assert_includes ApplicationsWatchList.build([ hub ], admin: true).live.first.warnings, "Backup MISSING"

    hub.update!(backup_status: { "checked_at" => Time.current.iso8601, "state" => "ok",
                                 "finished_at" => Time.current.iso8601, "size_bytes" => 1024 })
    assert_empty ApplicationsWatchList.build([ hub ], admin: true).live.first.warnings
  end

  test "[unit] mail is the workspace on the app's own domain, and a live app's health is drawn only when reported" do
    WorkspaceAccount.create!(domain: "turfmonster.media", entity: "turf", subject: "alex@turfmonster.media")
    list = ApplicationsWatchList.build([ apps(:turf_monster), apps(:mcritchie_studio) ], admin: true)

    assert_equal "pending", list.live.find { |r| r.slug == "turf-monster" }.mail
    assert_nil list.live.find { |r| r.slug == "mcritchie-studio" }.mail
    assert list.live.all?(&:health_reported?), "both are live engine apps in the daily report"
    assert_equal "turfmonster.media", ApplicationsWatchList.domain_of("https://www.TurfMonster.media/x")
  end
end
