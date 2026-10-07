# Daily digest of /contact submissions the bot check flagged, registered in
# config/recurring.yml for production. A flagged row is stored but never
# emailed on arrival (ContactSubmissionsController#spam_reason), so without
# this a real visitor with JavaScript blocked would reach nobody.
#
# Quiet on a day with nothing flagged. Best-effort, like DeskHealthJob: a
# failure is an ErrorLog receipt, never a retry storm.
class ContactFlaggedDigestJob < ApplicationJob
  ZONE = "America/Denver"
  SEND_HOUR = 7 # the hour config/recurring.yml runs it

  # 07:00 Denver the day before the latest 07:00, on the wall clock: `1.day.ago`
  # in UTC would skip an hour on the fall-back day and drop rows a late run's
  # jitter leaves between two windows. Overlap only double-lists; it never hides.
  def self.window_start(now = Time.current)
    anchor = now.in_time_zone(ZONE).change(hour: SEND_HOUR)
    anchor -= 1.day if anchor > now
    anchor - 1.day
  end

  def perform
    # QA boots RAILS_ENV=production; only production's form has visitors.
    return if Studio.qa_environment?

    since = self.class.window_start
    return unless ContactSubmission.flagged.where(created_at: since..).exists?

    Studio::Email.deliver(ContactMailer, :flagged_digest, since.iso8601, to: ContactMailer::NOTIFY)
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
