require "test_helper"
require_relative "../../support/report_destination_fixtures"

# [component] /admin/report_destinations — admin only; one card per registered
# key; the select offers only postable, unarchived channels grouped by category;
# a save persists the channel and toggle; a refused pick says why; Refresh
# channels is refused plainly without a token.
class Admin::ReportDestinationsControllerTest < ActionDispatch::IntegrationTest
  include ReportDestinationFixtures

  def admin
    @admin ||= User.find_by(role: "admin") || User.create!(email: "reports-admin@example.com", name: "Reports Admin", role: "admin")
  end

  test "[component] anonymous and non-admin visitors are turned away" do
    get admin_report_destinations_path
    assert_response :redirect

    log_in_as(User.create!(email: "reports-member@example.com", name: "Member"))
    get admin_report_destinations_path
    assert_response :redirect
  end

  test "[component] the page lists each key and offers only postable, unarchived channels by category" do
    reports = channel!
    channel!(external_id: NEWS, name: "news", kind: "announcement", category_name: "Announcements")
    channel!(external_id: LOCKED, name: "read-only", postable: false)
    channel!(external_id: HIDDEN, name: "gone", archived_at: 1.hour.ago)
    channel!(external_id: VOICE, name: "Lounge", kind: "voice", postable: true)

    log_in_as(admin)
    get admin_report_destinations_path
    assert_response :success
    assert_select "[data-test='report-destination'][data-report-key='daily_app_report'][data-state='not_configured']" do
      assert_select "h2", "Daily application report"
      assert_select "optgroup[label='Ops'] option[value='#{reports.id}']", "#reports"
      assert_select "optgroup[label='Announcements'] option", "#news"
      assert_select "option", text: "#read-only", count: 0
      assert_select "option", text: "#gone", count: 0
      assert_select "option", text: "#Lounge", count: 0
      assert_select "[data-test='last-delivery']", /No delivery yet/
    end
    assert_select "[data-test='refresh-channels']"
  end

  test "[component] saving persists the channel, the toggle and who set it; the last delivery links to Discord" do
    reports = channel!
    log_in_as(admin)

    patch admin_report_destination_path(report_key: "daily_app_report"),
          params: { report_destination: { discord_channel_id: reports.id, enabled: "1" } }
    assert_redirected_to admin_report_destinations_path
    destination = ReportDestination.for("daily_app_report")
    assert_equal [ reports, true, admin.email ], [ destination.discord_channel, destination.enabled, destination.updated_by ]

    patch admin_report_destination_path(report_key: "daily_app_report"),
          params: { report_destination: { discord_channel_id: reports.id, enabled: "0" } }
    assert_not destination.reload.enabled

    ReportDelivery.create!(report_key: "daily_app_report", idempotency_key: "k1", status: "posted", posted_at: Time.current,
                           guild_external_id: GUILD, channel_external_id: REPORTS, message_external_id: "777")
    get admin_report_destinations_path
    assert_select "[data-report-key='daily_app_report'][data-state='disabled']"
    assert_select "[data-test='last-delivery-link'][href='https://discord.com/channels/#{GUILD}/#{REPORTS}/777']"
  end

  test "[component] an unpostable channel or an unknown key is refused" do
    locked = channel!(external_id: LOCKED, name: "read-only", postable: false)
    log_in_as(admin)

    patch admin_report_destination_path(report_key: "daily_app_report"),
          params: { report_destination: { discord_channel_id: locked.id, enabled: "1" } }
    follow_redirect!
    assert_match(/not saved: Discord channel is archived or not postable/, response.body)
    assert_nil ReportDestination.for("daily_app_report")

    patch admin_report_destination_path(report_key: "nope"), params: { report_destination: { enabled: "1" } }
    assert_response :not_found
  end

  test "[component] Refresh channels without a token says so and reads nothing" do
    log_in_as(admin)
    with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
      post admin_refresh_report_destinations_path
    end
    follow_redirect!
    assert_match(/Channels not refreshed: DISCORD_AGENT_BOT_TOKEN is unset/, response.body)
  end
end
