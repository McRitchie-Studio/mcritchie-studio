# Tells the operator a /contact submission arrived. Internal: one recipient,
# plain layout, reply goes straight to the visitor.
#
# Flagged submissions (ContactSubmission#spam_reason) are never sent one by one;
# they reach the operator once a day in #flagged_digest, so a real person the
# bot check caught by mistake is still seen.
class ContactMailer < ApplicationMailer
  NOTIFY = "alex@mcritchie.studio".freeze
  # A bot flood can flag hundreds a day. The digest lists this many, newest
  # first, and counts the rest.
  DIGEST_LIMIT = 50

  def submission(submission)
    @submission = submission
    mail(to: NOTIFY, reply_to: submission.email, subject: "Contact form: #{submission.name}")
  end

  # `since` is an ISO 8601 string: the outbox serializes mailer arguments.
  def flagged_digest(since)
    flagged = ContactSubmission.flagged.where(created_at: Time.iso8601(since)..).recent
    @total = flagged.count
    @submissions = flagged.limit(DIGEST_LIMIT).to_a
    @remaining = @total - @submissions.size
    mail(to: NOTIFY, subject: "Contact form: #{@total} flagged as spam in the last day")
  end
end
