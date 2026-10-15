# The morning CTO summary (DailyAppReport), registered in config/recurring.yml
# for production at 07:00 America/Denver. One run reads every live
# studio-engine app's health for the window ending at today's 07:00 Denver and
# posts one Discord message under the report key `daily_app_report`.
# Guide: docs/agents/system/daily-app-report.md.
#
# `ending` (an ISO 8601 string) pins the window; without it the run computes the
# latest 07:00 Denver, so a late run or a retry reports the same day.
#
# Best-effort, like DeskHealthJob: a failure is an ErrorLog receipt, never a
# retry storm (ReportDeliveryJob owns the Discord retries).
class DailyAppReportJob < ApplicationJob
  queue_as :default

  def perform(ending = nil)
    # QA boots RAILS_ENV=production; only production's board sends the report.
    return if Studio.qa_environment?

    ending = ending.present? ? Time.iso8601(ending.to_s) : DailyAppReport.window_end
    DailyAppReport.run(ending: ending)
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
