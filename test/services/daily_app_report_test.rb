require "test_helper"
require_relative "../support/daily_app_report_fixtures"
require_relative "../support/report_destination_fixtures"

# [unit] DailyAppReport.run — which apps are read, how each answer becomes a
# line, the shared window and idempotency key, and the delivery outcome. The
# fetcher and Discord are fakes; nothing leaves the process.
class DailyAppReportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include DailyAppReportFixtures
  include ReportDestinationFixtures

  DENVER = Time.find_zone("America/Denver")
  ENDING = DENVER.local(2026, 10, 15, 7)

  setup do
    @hub = app_entry("mcritchie-studio", name: "McRitchie Studio", url: "https://mcritchie.studio")
    @turf = app_entry("turf-monster", name: "Turf Monster")
    @cyvasse = app_entry("cyvasse", name: "Cyvasse")
    @rantly = app_entry("rantly", name: "Rantly")
  end

  # Backup lines are their own test below; the rest see none.
  def run_report(apps, answers, env: {}, logger: Rails.logger, backups: {})
    fetcher = FakeFetcher.new(answers)
    result = DailyAppReport.stub(:apps, apps) do
      DailyAppReport.stub(:backup_lines, ->(_ending) { backups }) do
        DailyAppReport.run(ending: ENDING, fetcher: fetcher, env: env, logger: logger)
      end
    end
    [ result, fetcher ]
  end

  def capture_deliveries
    calls = []
    deliver = lambda do |key, content:, embeds:, idempotency_key:|
      calls << { key: key, content: content, embeds: embeds, idempotency_key: idempotency_key }
      ReportDestinations::Result.new(status: :posted, message_id: "1", url: "https://discord.com/channels/1/2/1")
    end
    ReportDestinations.stub(:deliver, deliver) { yield calls }
  end

  test "[unit] the window ends at the latest 07:00 Denver, across a late run and the UTC date line" do
    assert_equal DENVER.local(2026, 10, 15, 7), DailyAppReport.window_end(Time.utc(2026, 10, 15, 13, 0, 40))
    # 21:00 Denver on the 15th is already the 16th in UTC: still the 15th's report.
    assert_equal DENVER.local(2026, 10, 15, 7), DailyAppReport.window_end(Time.utc(2026, 10, 16, 3))
    # 06:59 Denver is still yesterday's window.
    assert_equal DENVER.local(2026, 10, 14, 7), DailyAppReport.window_end(Time.utc(2026, 10, 15, 12, 59))
  end

  test "[unit] the idempotency key is the Denver date of the window end" do
    assert_equal "daily_app_report:2026-10-15", DailyAppReport.idempotency_key(ENDING)
    assert_equal "daily_app_report:2026-10-15", DailyAppReport.idempotency_key(DailyAppReport.window_end(Time.utc(2026, 10, 16, 3)))
  end

  test "[unit] the apps are the live studio-engine apps with a production URL, minus unannounced ones" do
    slugs = DailyAppReport.apps.map(&:slug)

    assert_includes slugs, "mcritchie-studio"
    assert_includes slugs, "turf-monster" # showcase counts as live
    refute_includes slugs, "dads-app"     # engine: false
    refute_includes slugs, "tax-studio" # archived
    AppCatalog::UNANNOUNCED.each { |slug| refute_includes slugs, slug }
    assert_equal "HEALTH_TOKEN_TURF_MONSTER", DailyAppReport.token_env("turf-monster")
    assert_equal "HEALTH_TOKEN_10AND5", DailyAppReport.token_env("10and5")
  end

  test "[unit] one run: hub in-process, a wired app fetched, an unwired app listed and not fetched, one key" do
    capture_deliveries do |calls|
      _, fetcher = run_report([ @hub, @turf, @cyvasse ],
                              { @turf.production_url => health_body(signups: 3, errors: 12, groups: [ [ "Foo", "bar", 10 ], [ "Baz", "qux", 2 ] ]) },
                              env: { "HEALTH_TOKEN_TURF_MONSTER" => "turf-token" })

      assert_equal [ @turf.production_url ], fetcher.calls.map { |c| c[:url] }
      assert_equal "turf-token", fetcher.calls.sole[:token]
      assert_equal ENDING, fetcher.calls.sole[:ending]

      call = calls.sole
      assert_equal "daily_app_report", call[:key]
      assert_equal "daily_app_report:2026-10-15", call[:idempotency_key]
      # The hub's line depends on the fixture users' timestamps: quiet or activity.
      assert_match(/3 apps: 1 (quiet|with activity), 1 with errors, 1 not wired/, call[:content])
      assert_includes call[:content], "Not wired (no token): Cyvasse"
      assert_equal [ "Turf Monster", "McRitchie Studio" ], call[:embeds].map { |e| e[:title] }
      assert_includes call[:embeds].first[:description], "Signups 3 · Errors 12"
      assert_includes call[:embeds].first[:description], "`Foo` ×10: bar"
    end
  end

  test "[unit] an unreachable app (timeout, 401) gets its line and an ErrorLog row; the report still goes out" do
    capture_deliveries do |calls|
      assert_difference -> { ErrorLog.count }, 2 do
        run_report([ @hub, @turf, @rantly ],
                   { @turf.production_url => DailyAppReport::Fetcher::Error.new("timeout"),
                     @rantly.production_url => DailyAppReport::Fetcher::Error.new("HTTP 401 token mismatch") },
                   env: { "HEALTH_TOKEN_TURF_MONSTER" => "a", "HEALTH_TOKEN_RANTLY" => "b" })
      end

      call = calls.sole
      assert_match(/3 apps: 1 (quiet|with activity), 2 unreachable/, call[:content])
      assert_equal [ "Unreachable (timeout)", "Unreachable (HTTP 401 token mismatch)" ], call[:embeds].first(2).map { |e| e[:description] }
      assert_equal [ "daily-app-report turf-monster", "daily-app-report rantly" ], ErrorLog.order(:id).last(2).map(&:target_name)
      assert_includes ErrorLog.order(:id).last.message, "rantly health report unreachable: HTTP 401 token mismatch"
      turf_app = App.find_by!(slug: "turf-monster")
      assert_equal turf_app, ErrorLog.order(:id).last(2).first.target
    end
  end

  test "[unit] a body on an unknown schema is unreachable, not misread" do
    capture_deliveries do |calls|
      run_report([ @turf ], { @turf.production_url => { "schema" => 2 } }, env: { "HEALTH_TOKEN_TURF_MONSTER" => "a" })
      assert_equal "Unreachable (unknown schema 2)", calls.sole[:embeds].sole[:description]
    end
  end

  test "[unit] the hub's own report reads this database in-process for the same window" do
    travel_to ENDING - 2.hours do
      ErrorLog.capture!(RuntimeError.new("hub boom"))
    end
    travel_to ENDING + 1.hour do
      ErrorLog.capture!(RuntimeError.new("next day, not counted"))
    end

    capture_deliveries do |calls|
      run_report([ @hub ], {})
      embed = calls.sole[:embeds].sole
      assert_includes embed[:description], "Errors 1"
      assert_includes embed[:description], "`RuntimeError` ×1: hub boom"
      assert_equal "studio-engine #{Studio::VERSION}", embed.dig(:footer, :text)
    end
  end

  test "[unit] a destination with no channel is a logged skip, not an error, and not retried" do
    lines = []
    logger = Logger.new(nil)
    logger.define_singleton_method(:info) { |msg = nil, &_| lines << msg }
    result = nil
    assert_no_enqueued_jobs(only: ReportDeliveryJob) do
      assert_no_difference -> { ErrorLog.count } do
        result, = run_report([ @hub ], {}, logger: logger)
      end
    end

    assert_equal :not_configured, result.status
    assert_equal "not_configured", ReportDelivery.find_by!(idempotency_key: "daily_app_report:2026-10-15").status
    assert(lines.any? { |l| l.include?("daily_app_report:2026-10-15 status=not_configured") })
  end

  test "[unit] a Discord failure is handed to ReportDeliveryJob under the same key" do
    ReportDestination.create!(report_key: "daily_app_report", discord_channel: channel!)
    fake = fake_discord
    fake.overrides = { "/messages" => [ 502, { "message" => "bad gateway" } ] }

    with_fake_discord(fake) do
      assert_enqueued_with(job: ReportDeliveryJob, args: ->(args) { args.last[:idempotency_key] == "daily_app_report:2026-10-15" }) do
        result, = run_report([ @hub ], {})
        assert_equal :failed, result.status
      end
    end
  end

  test "[unit] a day already posted returns the receipt and fetches nothing" do
    ReportDelivery.create!(report_key: "daily_app_report", idempotency_key: "daily_app_report:2026-10-15", status: "posted",
                           guild_external_id: GUILD, channel_external_id: REPORTS, message_external_id: "777", posted_at: Time.current)
    result, fetcher = run_report([ @turf ], {}, env: { "HEALTH_TOKEN_TURF_MONSTER" => "a" })

    assert_equal :posted, result.status
    assert_equal "777", result.message_id
    assert_empty fetcher.calls
  end

  test "[unit] each backed-up app's embed carries last night's backup line, and the headline counts them" do
    App.where(slug: %w[turf-monster cyvasse]).delete_all
    App.create!(slug: "turf-monster", name: "Turf Monster",
                backup_status: { "state" => "fresh", "checked_at" => (ENDING - 210.minutes).iso8601,
                                 "finished_at" => (ENDING - 5.hours).iso8601, "size_bytes" => 48 * 1024 * 1024 })
    App.create!(slug: "cyvasse", name: "Cyvasse",
                backup_status: { "state" => "missing", "checked_at" => (ENDING - 210.minutes).iso8601, "capture" => "started" })
    lines = DailyAppReport.backup_lines(ENDING)
    assert_equal "Backup 02:00, 48 MB", lines.fetch("turf-monster")
    assert_equal "Backup MISSING (capture started)", lines.fetch("cyvasse")

    capture_deliveries do |calls|
      run_report([ @turf, @cyvasse, @rantly ],
                 { @turf.production_url => health_body, @cyvasse.production_url => health_body(app: "Cyvasse"),
                   @rantly.production_url => health_body(app: "Rantly") },
                 env: { "HEALTH_TOKEN_TURF_MONSTER" => "t", "HEALTH_TOKEN_CYVASSE" => "c", "HEALTH_TOKEN_RANTLY" => "r" },
                 backups: lines)
      call = calls.sole
      by_title = call[:embeds].to_h { |e| [ e[:title], e[:description] ] }
      assert_equal "Signups 0 · Errors 0\nBackup 02:00, 48 MB", by_title.fetch("Turf Monster")
      assert_equal "Signups 0 · Errors 0\nBackup MISSING (capture started)", by_title.fetch("Cyvasse")
      assert_equal "Signups 0 · Errors 0", by_title.fetch("Rantly"), "a basic app without backups gets no line"
      assert_match(/^Backups: \d+ fresh, 1 missing/, call[:content])
      refute_match(/commercial/i, call[:content])
    end
  end

  test "[unit] a backup-line failure costs the lines, never the report" do
    DbBackupSweep.stub(:report_lines, ->(**) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_equal({}, DailyAppReport.backup_lines(ENDING))
    end
  end
end
