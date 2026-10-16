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
            CtoReport.stub(:run, ->(**) {}) do # the per-app reports have their own test below
              DailyAppReportJob.perform_now(ENDING.iso8601)
              DailyAppReportJob.perform_now(ENDING.iso8601) # a retry or late run: same window, nothing re-posted
            end
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
    seen = []
    run = ->(ending:, healths:) { seen << ending }
    travel_to Time.utc(2026, 10, 16, 3) do
      DailyAppReport.stub(:run, run) { CtoReport.stub(:run, run) { DailyAppReportJob.perform_now } }
    end
    assert_equal [ ENDING, ENDING ], seen
  end

  test "[integration] the CTO reports: one post per configured app key, once per Denver date; the rest skip" do
    turf_channel = channel!
    hub_channel = channel!(external_id: ReportDestinationFixtures::NEWS, name: "news", kind: "announcement")
    ReportDestination.create!(report_key: "cto_report:turf_monster", discord_channel: turf_channel)
    ReportDestination.create!(report_key: "cto_report:mcritchie_studio", discord_channel: hub_channel)
    # daily_app_report and cto_report:cyvasse have no channel; cyvasse also has no token.
    turf = TinyServer.new("/_studio/health_report" => [ 200, JSON.generate(health_body(signups: 2)) ])
    apps = [ app_entry("mcritchie-studio", name: "McRitchie Studio"), app_entry("turf-monster", name: "Turf Monster", url: turf.url),
             app_entry("cyvasse", name: "Cyvasse"), app_entry("rantly", name: "Rantly") ]
    fake = fake_discord

    with_fake_discord(fake) do
      with_env("HEALTH_TOKEN_TURF_MONSTER", "turf-token") do
        with_env("HEALTH_TOKEN_CYVASSE", nil) do
          DailyAppReport.stub(:apps, apps) do
            DailyAppReportJob.perform_now(ENDING.iso8601)
            # One read of Turf Monster served the combined report and Turf's own.
            assert_equal 1, turf.requests.size
            DailyAppReportJob.perform_now(ENDING.iso8601) # the same day again: nothing re-posted
          end
        end
      end
    end

    posts = fake.posts
    assert_equal 2, posts.size
    by_channel = posts.to_h { |p| [ p[:path], p[:body] ] }
    turf_post = by_channel.fetch("/channels/#{ReportDestinationFixtures::REPORTS}/messages")
    hub_post = by_channel.fetch("/channels/#{ReportDestinationFixtures::NEWS}/messages")
    assert_match(/\A\*\*Turf Monster · CTO report · Thu, Oct 15, 2026\*\*/, turf_post["content"])
    assert_includes turf_post["content"], "2 signups, and zero errors. Clean game."
    assert_includes hub_post["content"], "On the board:"
    assert hub_post["content"].end_with?("— Avi")
    posts.each { |p| assert_equal({ "parse" => [] }, p[:body]["allowed_mentions"]) }

    receipts = ReportDelivery.order(:idempotency_key).pluck(:idempotency_key, :status)
    assert_equal [ %w[cto_report:mcritchie_studio:2026-10-15 posted], %w[cto_report:turf_monster:2026-10-15 posted],
                   %w[daily_app_report:2026-10-15 not_configured] ], receipts
    refute ReportDelivery.exists?(report_key: "cto_report:cyvasse"), "an unwired app is skipped before delivery"
    refute ReportDelivery.where("report_key LIKE ?", "%rantly%").exists?, "an app with no CTO gets no CTO report"
  ensure
    turf&.close
  end

  test "[integration] a crash in the combined report still sends the CTO reports" do
    cto_ran = false
    DailyAppReport.stub(:run, ->(**) { raise "probe" }) do
      CtoReport.stub(:run, ->(**) { cto_ran = true }) do
        assert_difference -> { ErrorLog.count }, 1 do
          DailyAppReportJob.perform_now(ENDING.iso8601)
        end
      end
    end
    assert cto_ran
  end

  test "[integration] a crash is an ErrorLog receipt, not a retry" do
    DailyAppReport.stub(:run, ->(**) { raise "probe" }) do
      CtoReport.stub(:run, ->(**) { raise "probe" }) do
        assert_difference -> { ErrorLog.count }, 2 do
          assert_no_enqueued_jobs(only: DailyAppReportJob) { DailyAppReportJob.perform_now(ENDING.iso8601) }
        end
      end
    end
  end

  test "[integration] QA sends nothing" do
    called = false
    Studio.stub(:qa_environment?, true) do
      DailyAppReport.stub(:run, ->(**) { called = true }) { CtoReport.stub(:run, ->(**) { called = true }) { DailyAppReportJob.perform_now } }
    end
    refute called, "QA must not run the report"
  end
end
