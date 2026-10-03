# Daily watch on the team@ inbound path (DeskCapture::Health), registered in
# config/recurring.yml for production. From 2026-09-29 to 2026-10-02 the
# in.mcritchie.studio MX was missing, nothing reached the desk, and nothing
# said so. A failed check now leaves an ErrorLog receipt in /error_logs.
#
# Best-effort, never crash: everything is rescued into ErrorLog and NOT
# re-raised, so ApplicationJob's retry cannot storm. Read-only and idempotent,
# so a swallowed run is covered by tomorrow's.
class DeskHealthJob < ApplicationJob
  def perform(health: DeskCapture::Health.new)
    # QA boots RAILS_ENV=production with no desk traffic of its own; the
    # production board is the one environment whose desk this check describes.
    return if Studio.qa_environment?

    result = health.check
    return if result.ok?

    begin
      raise DeskCapture::Health::HealthError, result.failures.join(" | ")
    rescue DeskCapture::Health::HealthError => e
      log = ErrorLog.capture!(e)
      log.target_name = "desk-health"
      log.save!
    end
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
