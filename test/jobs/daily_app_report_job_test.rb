require "test_helper"
require_relative "../support/daily_app_report_fixtures"
require_relative "../support/report_destination_fixtures"

# [integration] DailyAppReportJob end to end: a satellite answers over a real
# socket (127.0.0.1), the hub reads itself in-process, and the message goes
# through ReportDestinations to a FAKE Discord transport, leaving the receipt in
# report_deliveries. Nothing reaches a real app or Discord.
class DailyAppReportJobTest < ActiveJob::TestCase
  include DailyAppReportFixtures
  include ReportDestinationFixtures

  ENDING = Time.find_zone("America/Denver").local(2026, 10, 15, 7)

  test "[integration] the job is scheduled at 07:00 Denver in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "daily_app_report")

    assert_equal "DailyAppReportJob", entry["class"]
    assert_equal "0 7 * * * America/Denver", entry["schedule"]
    assert_equal [], entry["args"]
    assert DailyAppReport::REPORT_KEY.then { |key| ReportDestinations.registered?(key) }
  end

  test "[integration] one run posts one message, pings nobody, and records the posted receipt" do
    ReportDestination.create!(report_key: "daily_app_report", discord_channel: channel!)
    turf = TinyServer.new("/_studio/health_report" => [ 200, JSON.generate(health_body(errors: 4, groups: [ [ "Foo", "boom", 4 ] ])) ])
    down = TinyServer.new("/_studio/health_report" => [ 401, "{}" ])
    apps = [ app_entry("mcritchie-studio", name: "McRitchie Studio"), app_entry("turf-monster", name: "Turf Monster", url: turf.url),
             app_entry("rantly", name: "Rantly", url: down.url), app_entry("cyvasse", name: "Cyvasse") ]
    fake = fake_discord

    with_fake_discord(fake) do
      with_env("HEALTH_TOKEN_TURF_MONSTER", "turf-token") do
        with_env("HEALTH_TOKEN_RANTLY", "stale-token") do
          DailyAppReport.stub(:apps, apps) do
            DailyAppReportJob.perform_now(ENDING.iso8601)
            DailyAppReportJob.perform_now(ENDING.iso8601) # a retry or late run: same window, nothing re-posted
          end
        end
      end
    end

    assert_equal "Bearer turf-token", turf.requests.sole[:headers]["authorization"]
    assert_equal ENDING.iso8601, turf.requests.sole[:query]["ending"]
    post = fake.posts.sole
    assert_equal({ "parse" => [] }, post[:body]["allowed_mentions"])
    assert_match(/4 apps: 1 (quiet|with activity), 1 with errors, 1 unreachable, 1 not wired/, post[:body]["content"])
    assert_equal [ "Rantly", "Turf Monster", "McRitchie Studio" ], post[:body]["embeds"].map { |e| e["title"] }
    assert_equal "Unreachable (HTTP 401 token mismatch)", post[:body]["embeds"].first["description"]
    receipt = ReportDelivery.sole
    assert_equal [ "daily_app_report:2026-10-15", "posted" ], [ receipt.idempotency_key, receipt.status ]
    assert_equal 1, down.requests.size # the second run found the day posted and fetched nothing
  ensure
    turf&.close
    down&.close
  end

  test "[integration] with no ending it reports the latest 07:00 Denver window" do
    seen = nil
    run = ->(ending:) { seen = ending }
    travel_to Time.utc(2026, 10, 16, 3) do
      DailyAppReport.stub(:run, run) { DailyAppReportJob.perform_now }
    end
    assert_equal ENDING, seen
  end

  test "[integration] a crash is an ErrorLog receipt, not a retry" do
    DailyAppReport.stub(:run, ->(**) { raise "probe" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_no_enqueued_jobs(only: DailyAppReportJob) { DailyAppReportJob.perform_now(ENDING.iso8601) }
      end
    end
  end

  test "[integration] QA sends nothing" do
    called = false
    Studio.stub(:qa_environment?, true) do
      DailyAppReport.stub(:run, ->(**) { called = true }) { DailyAppReportJob.perform_now }
    end
    refute called, "QA must not run the report"
  end
end
