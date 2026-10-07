# Daily digest of /contact submissions the bot check flagged, registered in
# config/recurring.yml for production. A flagged row is stored but never
# emailed on arrival (ContactSubmissionsController#spam_reason), so without
# this a real visitor with JavaScript blocked would reach nobody.
#
# Quiet on a day with nothing flagged. Best-effort, like DeskHealthJob: a
# failure is an ErrorLog receipt, never a retry storm.
class ContactFlaggedDigestJob < ApplicationJob
  WINDOW = 1.day

  def perform
    # QA boots RAILS_ENV=production; only production's form has visitors.
    return if Studio.qa_environment?

    since = WINDOW.ago
    return unless ContactSubmission.flagged.where(created_at: since..).exists?

    Studio::Email.deliver(ContactMailer, :flagged_digest, since.iso8601, to: ContactMailer::NOTIFY)
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
