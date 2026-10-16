require "test_helper"
require_relative "../support/report_destination_fixtures"

# [integration] The whole path, against a stubbed Discord API: Refresh channels
# syncs the directory, the admin picks a channel for daily_app_report, deliver
# posts there once, and a second deliver with the same key posts nothing.
class ReportDestinationsFlowTest < ActionDispatch::IntegrationTest
  include ReportDestinationFixtures

  def admin
    @admin ||= User.find_by(role: "admin") || User.create!(email: "reports-flow@example.com", name: "Flow Admin", role: "admin")
  end

  test "[integration] sync from the stubbed API, pick a destination, deliver posts once, the same key never again" do
    fake = fake_discord
    log_in_as(admin)

    with_fake_discord(fake) do
      DiscordDirectory::Sync.stub(:guild_ids, [ GUILD ]) do
        post admin_refresh_report_destinations_path
      end
      follow_redirect!
      assert_match(/Channels refreshed: 1 guild\(s\), 9 channel\(s\) seen, 0 archived/, response.body)
      reports = DiscordChannel.find_by!(external_id: REPORTS)
      assert_select "option[value='#{reports.id}']"

      patch admin_report_destination_path(report_key: "daily_app_report"),
            params: { report_destination: { discord_channel_id: reports.id, enabled: "1" } }
      assert_redirected_to admin_report_destinations_path

      first = ReportDestinations.deliver("daily_app_report", content: "Morning: 4 apps green.", idempotency_key: "daily_app_report:2026-10-15")
      again = ReportDestinations.deliver("daily_app_report", content: "Morning: 4 apps green.", idempotency_key: "daily_app_report:2026-10-15")

      assert_equal [ :posted, :posted ], [ first.status, again.status ]
      assert_equal first.url, again.url
      assert_equal 1, fake.posts.size
      assert_equal "/channels/#{REPORTS}/messages", fake.posts.sole[:path]

      get admin_report_destinations_path
      assert_select "[data-report-key='daily_app_report'][data-state='on']"
      assert_select "[data-test='last-delivery-link'][href='#{first.url}']"
    end
  end

  test "[integration] each CTO report key has its own card, and a key with a colon saves through the page" do
    log_in_as(admin)
    reports = channel!

    get admin_report_destinations_path
    %w[cto_report:mcritchie_studio cto_report:turf_monster cto_report:cyvasse].each do |key|
      assert_select "[data-report-key='#{key}']"
    end

    patch admin_report_destination_path(report_key: "cto_report:turf_monster"),
          params: { report_destination: { discord_channel_id: reports.id, enabled: "1" } }
    assert_redirected_to admin_report_destinations_path
    destination = ReportDestination.find_by!(report_key: "cto_report:turf_monster")
    assert_equal [ reports, true ], [ destination.discord_channel, destination.enabled? ]
    assert_nil ReportDestination.find_by(report_key: "cto_report:cyvasse")
  end
end
