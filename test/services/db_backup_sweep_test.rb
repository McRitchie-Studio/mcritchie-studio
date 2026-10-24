require "test_helper"
require_relative "../support/daily_app_report_fixtures"

# [unit] DbBackupSweep, Steffon's nightly agent job over the database backups:
# a fresh backup is recorded, a missing one is captured and opens ONE floor
# incident (posted once by AgentMessages::FloorAlert), a dead API is one
# incident and never a crash, and the morning report's line reads what the sweep
# recorded. Heroku is a fake client and Discord a recording transport; nothing
# leaves the process.
class DbBackupSweepTest < ActiveSupport::TestCase
  include DailyAppReportFixtures

  NOW = Time.find_zone("America/Denver").local(2026, 10, 24, 3, 30)
  OPS = "900000000000000777".freeze
  Error = DbBackupSweep::HerokuClient::Error

  # heroku_app => Array of transfers, or an Exception to raise. Records captures.
  class FakeClient
    attr_reader :captured, :reads

    # FakeClient.new("app" => [...]) reaches here as keywords; both forms work.
    def initialize(transfers = nil, capture_error: nil, **by_app)
      @transfers = transfers || by_app.transform_keys(&:to_s)
      @capture_error = capture_error
      @captured = []
      @reads = []
    end

    def transfers(app)
      @reads << app
      answer = @transfers.fetch(app) { raise "unexpected read #{app}" }
      raise answer if answer.is_a?(Exception)

      answer
    end

    def capture(app)
      raise @capture_error if @capture_error

      @captured << app
      { "num" => 99 }
    end
  end

  class Recorder
    attr_reader :posts

    def initialize = (@posts = [])

    def call(_method, url, _headers, body)
      @posts << [ url, JSON.parse(body) ]
      [ 200, JSON.generate("id" => "1#{@posts.size}") ]
    end
  end

  def entry(slug, heroku_app = slug)
    app_entry(slug).with(heroku_app: heroku_app)
  end

  def backup(finished_at, num: 40, bytes: 48 * 1024 * 1024, schedule: true, **extra)
    { "num" => num, "from_type" => "pg_dump", "to_type" => "gof3r", "succeeded" => true,
      "finished_at" => finished_at.utc.strftime("%Y-%m-%d %H:%M:%S +0000"), "processed_bytes" => bytes,
      "deleted_at" => nil, "schedule" => (schedule ? { "uuid" => "s-1" } : nil) }.merge(extra)
  end

  def sweep(client, apps, logger: Logger.new(nil))
    DbBackupSweep.new(client: client, apps: apps, env: {}, logger: logger)
  end

  def floor(recorder)
    bot = AgentMessages::DiscordBot.new(token: "test-token", transport: recorder)
    routes = AgentMessages::Routes.new("discord" => { "ops_channel_id" => OPS, "guilds" => {} })
    AgentMessages::FloorAlert.new(routes: routes, bot: bot, logger: Logger.new(nil))
  end

  setup do
    App.where(slug: %w[turf-monster cyvasse]).delete_all
    @turf = App.create!(slug: "turf-monster", name: "Turf Monster")
    @cyvasse = App.create!(slug: "cyvasse", name: "Cyvasse")
  end

  test "[unit] inert without HEROKU_BACKUP_API_KEY: one log line, nothing read, recorded or opened" do
    log = StringIO.new
    results = DbBackupSweep.new(apps: [ entry("turf-monster") ], env: {}, logger: Logger.new(log)).call(now: NOW)

    assert_equal [], results
    assert_equal 1, log.string.lines.size
    assert_match(/inert: HEROKU_BACKUP_API_KEY is unset/, log.string)
    assert_equal({}, @turf.reload.backup_status)
    assert_equal 0, AgentMailboxIncident.count
  end

  test "[unit] a fresh backup is recorded with its time and size, and nothing is captured or opened" do
    client = FakeClient.new("turf-monster-mainnet" => [ backup(NOW - 1.day - 2.hours, num: 38), backup(NOW - 88.minutes, num: 39) ])
    result = sweep(client, [ entry("turf-monster", "turf-monster-mainnet") ]).call(now: NOW).sole

    assert result.fresh?
    assert_equal "a039", result.name
    assert_equal [], client.captured
    status = @turf.reload.backup_status
    assert_equal [ "fresh", (NOW - 88.minutes).utc.iso8601, 48 * 1024 * 1024 ], status.values_at("state", "finished_at", "size_bytes")
    assert_equal 0, AgentMailboxIncident.count
    assert_equal "Backup 02:02, 48 MB", DbBackupSweep.report_line(status, now: NOW + 3.5.hours)
  end

  test "[unit] a missing backup is captured, recorded missing, and alerted once on the dispatcher's floor" do
    stale = backup(NOW - 27.hours)
    deleted = backup(NOW - 1.hour, num: 41, "deleted_at" => "2026-10-24 09:00:00 +0000")
    failed = backup(NOW - 1.hour, num: 42, "succeeded" => false)
    client = FakeClient.new("turf-monster-mainnet" => [ stale, deleted, failed ], "cyvasse" => [ backup(NOW - 1.hour) ])
    apps = [ entry("turf-monster", "turf-monster-mainnet"), entry("cyvasse") ]

    results = sweep(client, apps).call(now: NOW)

    assert_equal %w[missing fresh], results.map(&:state)
    assert_equal [ "turf-monster-mainnet" ], client.captured
    assert_equal [ "missing", "started" ], @turf.reload.backup_status.values_at("state", "capture")
    incident = AgentMailboxIncident.open_for("db_backup_missing")
    assert_equal [ { "slug" => "turf-monster", "heroku_app" => "turf-monster-mainnet", "capture" => "started" } ],
                 incident.detail["apps"]

    recorder = Recorder.new
    floor(recorder).call(now: NOW + 1.minute)
    floor(recorder).call(now: NOW + 2.minutes)
    sweep(client, apps).call(now: NOW + 1.day) # still missing the next night: same incident, no second alert
    floor(recorder).call(now: NOW + 1.day + 1.minute)

    assert_equal 1, recorder.posts.size
    text = recorder.posts.sole.last["content"]
    assert_match(/Database backup missing: no completed Heroku backup since the 02:00 Denver schedule for turf-monster\./, text)
    assert_match(/The sweep started a capture for each\. Steffon: SOP db-restore-drill\./, text)
    assert_equal 1, AgentMailboxIncident.where(kind: "db_backup_missing").count
  end

  test "[unit] ONE missed night is caught: only yesterday's 02:03 backup, swept at 03:30, is MISSING" do
    yesterday = Time.find_zone("America/Denver").local(2026, 10, 23, 2, 3)
    assert_operator NOW - yesterday, :<, 26.hours, "the case a rolling 26-hour window reads as fresh"
    client = FakeClient.new("cyvasse" => [ backup(yesterday) ])

    result = sweep(client, [ entry("cyvasse") ]).call(now: NOW).sole

    assert_equal [ "missing", "started" ], [ result.state, result.capture ]
    assert_equal [ "cyvasse" ], client.captured
    assert AgentMailboxIncident.open_for("db_backup_missing")
    assert_equal "Backup MISSING (capture started)", DbBackupSweep.report_line(@cyvasse.reload.backup_status, now: NOW + 3.5.hours)
  end

  test "[unit] the expected slot is the latest 02:00 Denver whose 90-minute grace has passed" do
    denver = Time.find_zone("America/Denver")
    assert_equal denver.local(2026, 10, 24, 2), DbBackupSweep.expected_slot(denver.local(2026, 10, 24, 3, 30))
    assert_equal denver.local(2026, 10, 23, 2), DbBackupSweep.expected_slot(denver.local(2026, 10, 24, 3, 29)),
                 "inside the grace, last night's slot still counts"
    assert_equal denver.local(2026, 10, 24, 2), DbBackupSweep.expected_slot(denver.local(2026, 10, 24, 23, 0))
    # Across the fall-back change (Nov 1, 2026): still 02:00 local.
    assert_equal denver.local(2026, 11, 1, 2), DbBackupSweep.expected_slot(denver.local(2026, 11, 1, 3, 30))
  end

  test "[unit] the incident resolves when every app is fresh again, and the recovery posts once" do
    client = FakeClient.new("cyvasse" => [])
    sweep(client, [ entry("cyvasse") ]).call(now: NOW)
    recorder = Recorder.new
    floor(recorder).call(now: NOW + 1.minute)

    fresh = FakeClient.new("cyvasse" => [ backup(NOW + 1.day - 90.minutes) ])
    sweep(fresh, [ entry("cyvasse") ]).call(now: NOW + 1.day)
    floor(recorder).call(now: NOW + 1.day + 1.minute)
    floor(recorder).call(now: NOW + 1.day + 2.minutes)

    assert_nil AgentMailboxIncident.open_for("db_backup_missing")
    assert_equal 2, recorder.posts.size
    assert_match(/Database backups fresh again/, recorder.posts.last.last["content"])
  end

  test "[unit] a capture already running is not started twice (a retried or second run)" do
    running = { "num" => 50, "from_type" => "pg_dump", "to_type" => "gof3r", "succeeded" => false, "finished_at" => nil,
                "canceled_at" => nil, "created_at" => (NOW - 5.minutes).utc.strftime("%Y-%m-%d %H:%M:%S +0000") }
    client = FakeClient.new("cyvasse" => [ backup(NOW - 30.hours), running ])
    result = sweep(client, [ entry("cyvasse") ]).call(now: NOW).sole

    assert_equal [ "missing", "in progress" ], [ result.state, result.capture ]
    assert_equal [], client.captured
    assert_match(/The sweep started a capture for each\./, DbBackupSweep.alert_text(AgentMailboxIncident.open_for("db_backup_missing")))
    stuck = running.merge("created_at" => (NOW - 3.hours).utc.strftime("%Y-%m-%d %H:%M:%S +0000"))
    refute DbBackupSweep.backup_running?([ stuck ], NOW), "a capture stuck for hours is not waited on"
  end

  test "[unit] a failed capture is named in the alert" do
    client = FakeClient.new({ "cyvasse" => [] }, capture_error: Error.new("HTTP 403 key rejected"))
    sweep(client, [ entry("cyvasse") ]).call(now: NOW)

    incident = AgentMailboxIncident.open_for("db_backup_missing")
    assert_equal "failed (HTTP 403 key rejected)", incident.detail["apps"].sole["capture"]
    assert_match(/Capture failed for cyvasse\./, DbBackupSweep.alert_text(incident))
    assert_equal "Backup MISSING", DbBackupSweep.report_line(@cyvasse.reload.backup_status, now: NOW + 3.hours)
  end

  test "[unit] the API down is ONE incident, never a crash, and nothing is captured" do
    down = Error.new("timeout")
    client = FakeClient.new("turf-monster-mainnet" => down, "cyvasse" => Error.new("HTTP 401 key rejected"))
    apps = [ entry("turf-monster", "turf-monster-mainnet"), entry("cyvasse") ]

    results = nil
    assert_nothing_raised { results = sweep(client, apps).call(now: NOW) }
    sweep(client, apps).call(now: NOW + 1.day)

    assert_equal %w[unreadable unreadable], results.map(&:state)
    assert_equal [], client.captured
    assert_equal 1, AgentMailboxIncident.where(kind: "db_backup_sweep_failed").count
    assert_nil AgentMailboxIncident.open_for("db_backup_missing"), "unread is not missing"
    text = DbBackupSweep.alert_text(AgentMailboxIncident.open_for("db_backup_sweep_failed"))
    assert_match(/could not read 2 app\(s\): turf-monster, cyvasse \(timeout; HTTP 401 key rejected\)/, text)
    assert_equal "Backup unread (timeout)", DbBackupSweep.report_line(@turf.reload.backup_status, now: NOW + 1.day + 3.hours)
  end

  test "[unit] a missing incident stays open, with no all-clear, while an app it named goes unread" do
    sweep(FakeClient.new("cyvasse" => []), [ entry("cyvasse") ]).call(now: NOW)
    sweep(FakeClient.new("cyvasse" => Error.new("timeout")), [ entry("cyvasse") ]).call(now: NOW + 1.day)

    assert AgentMailboxIncident.open_for("db_backup_missing"), "unread is not fresh: no recovery may post"
    assert AgentMailboxIncident.open_for("db_backup_sweep_failed")
  end

  test "[unit] an unannounced app is counted, never named, in an alert" do
    incident = AgentMailboxIncident.new(kind: "db_backup_missing", detail: { "apps" => [
      { "slug" => "cyvasse", "capture" => "started" }, { "slug" => "commercial-welding", "capture" => "started" } ] })

    text = DbBackupSweep.alert_text(incident)
    assert_match(/for cyvasse, 1 unannounced app\./, text)
    refute_match(/commercial/i, text)
  end

  test "[unit] the latest backup ignores restores, copies, failures and deleted backups" do
    transfers = [
      backup(NOW - 3.hours, num: 7, schedule: false),
      backup(NOW - 1.hour, num: 8, "to_type" => "pg_restore"),
      backup(NOW - 1.hour, num: 9, "from_type" => "pg_restore"),
      backup(NOW - 1.hour, num: 10, "finished_at" => nil),
      backup(NOW - 1.hour, num: 11, "purged_at" => "2026-10-24 10:00:00 +0000")
    ]
    latest = DbBackupSweep.latest_backup(transfers)

    assert_equal "b007", latest[:name]
    assert_nil DbBackupSweep.latest_backup([])
  end

  test "[unit] the report line covers every state, and a stale record reads not checked" do
    checked = NOW.iso8601
    assert_equal "Backup not checked", DbBackupSweep.report_line({}, now: NOW)
    assert_equal "Backup not checked", DbBackupSweep.report_line(nil, now: NOW)
    assert_equal "Backup not checked",
                 DbBackupSweep.report_line({ "state" => "fresh", "checked_at" => (NOW - 27.hours).iso8601,
                                             "finished_at" => (NOW - 28.hours).iso8601 }, now: NOW)
    assert_equal "Backup MISSING (capture started)",
                 DbBackupSweep.report_line({ "state" => "missing", "checked_at" => checked, "capture" => "started" }, now: NOW)
    assert_equal "Backup unread (unknown)", DbBackupSweep.report_line({ "state" => "unreadable", "checked_at" => checked }, now: NOW)
    assert_equal "Backup 08:02, 79.4 KB",
                 DbBackupSweep.report_line({ "state" => "fresh", "checked_at" => checked,
                                             "finished_at" => "2026-10-24T14:02:00Z", "size_bytes" => 81_260 }, now: NOW + 5.hours)
  end

  test "[unit] the report summary counts the lines without naming an app" do
    lines = { "a" => "Backup 02:02, 48 MB", "b" => "Backup MISSING (capture started)", "c" => "Backup 02:03, 1 MB",
              "d" => "Backup unread (timeout)", "e" => "Backup not checked" }
    assert_equal "Backups: 2 fresh, 1 missing, 1 unread, 1 not checked", DbBackupSweep.report_summary(lines)
    assert_nil DbBackupSweep.report_summary({})
  end

  test "[unit] report_lines reads each backed-up app's recorded status" do
    @turf.update!(backup_status: { "state" => "fresh", "checked_at" => NOW.iso8601,
                                   "finished_at" => (NOW - 90.minutes).iso8601, "size_bytes" => 1024 })
    lines = DbBackupSweep.report_lines(apps: [ entry("turf-monster"), entry("cyvasse") ], now: NOW + 3.5.hours)

    assert_equal({ "turf-monster" => "Backup 02:00, 1 KB", "cyvasse" => "Backup not checked" }, lines)
  end
end
