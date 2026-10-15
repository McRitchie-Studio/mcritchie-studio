require "application_system_test_case"
require_relative "../support/report_destination_fixtures"

# [system] The admin picks a channel for daily_app_report on
# /admin/report_destinations, saves, and the choice persists across a reload.
class ReportDestinationsSystemTest < ApplicationSystemTestCase
  include ReportDestinationFixtures

  test "[system] the admin picks a channel for daily_app_report and the choice persists" do
    reports = channel!
    channel!(external_id: NEWS, name: "news", kind: "announcement")

    visit admin_report_destinations_path
    card = find("[data-test='report-destination'][data-report-key='daily_app_report']")
    assert_equal "not_configured", card["data-state"]

    within(card) do
      find("[data-test='destination-channel']").select("#reports")
      click_on "Save"
    end

    assert_text "Daily application report: #reports, on."
    assert_selector "[data-report-key='daily_app_report'][data-state='on'] [data-test='destination-badge']", text: "Posting to #reports"

    visit admin_report_destinations_path
    assert_equal reports.id.to_s, find("[data-report-key='daily_app_report'] [data-test='destination-channel']").value
    assert_equal reports, ReportDestination.for("daily_app_report").discord_channel
  end
end
