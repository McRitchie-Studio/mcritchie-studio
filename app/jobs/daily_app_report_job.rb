# The morning CTO reports, registered in config/recurring.yml for production at
# 07:00 America/Denver. One run reads every live studio-engine app's health for
# the window ending at today's 07:00 Denver, then posts:
#
#   1. the combined summary (DailyAppReport), one Discord message under the
#      report key `daily_app_report`;
#   2. each app's own CTO report (CtoReport, config/cto_reports.yml), one message
#      per app under `cto_report:<domain>`, in its CTO's voice.
#
# Both share one health memo, so each app is read at most once per run. Each is
# idempotent per Denver date and rescued on its own: a crash in one is an
# ErrorLog receipt and never stops the other.
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
    healths = {}
    safely { DailyAppReport.run(ending: ending, healths: healths) }
    safely { CtoReport.run(ending: ending, healths: healths) }
  rescue StandardError => e
    ErrorLog.capture!(e)
  end

  private

  def safely
    yield
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
