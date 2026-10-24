# Retention for csp_reports: deletes rows whose last_seen_at is older than
# CspReport::RETENTION (30 days). A violation still being reported keeps its row,
# with its first_seen_at, because each repeat moves last_seen_at forward.
#
# The table holds one row per distinct violation, so it stays small; one
# delete_all is enough. A failure is rescued into an ErrorLog and not re-raised,
# so ApplicationJob's retry_on cannot storm: the next nightly run covers it.
class CspReportRetentionJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    deleted = CspReport.expired(now).delete_all
    Rails.logger.info("[CspReportRetentionJob] deleted #{deleted} csp_reports row(s) not seen for #{CspReport::RETENTION.inspect}")
    deleted
  rescue StandardError => e
    Rails.logger.error("[CspReportRetentionJob] failed: #{e.class}")
    ErrorLog.capture!(e)
    nil
  end
end
