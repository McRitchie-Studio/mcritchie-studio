# Tells the operator a /contact submission arrived. Internal: one recipient,
# plain layout, reply goes straight to the visitor.
class ContactMailer < ApplicationMailer
  NOTIFY = "alex@mcritchie.studio".freeze

  def submission(submission)
    @submission = submission
    mail(to: NOTIFY, reply_to: submission.email, subject: "Contact form: #{submission.name}")
  end
end
