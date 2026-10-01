# /contact — the public contact form, and the SMS opt-in page a carrier reviews.
#
#   GET  /contact   the form, the three consent boxes, the disclosure under it
#   POST /contact   store the submission as proof of consent, then tell Alex
#
# The consent rules live in ContactSubmission. This controller adds what only a
# request knows (IP, user agent) and keeps bots out with a rate limit and a
# honeypot, the same shape as BuildController's public form.
class ContactSubmissionsController < ApplicationController
  skip_before_action :require_authentication

  # A public form that writes a row and sends an email: bounded per IP.
  rate_limit to: 5, within: 1.minute, only: :create,
             with: -> { redirect_to contact_form_path, alert: "Too many messages. Try again in a minute." }

  # Hidden from people, so only a script fills it in. The name must match no
  # browser autofill heuristic (name, email, tel, url, company, address, ...):
  # autofill ignores autocomplete="off", and a visitor whose trap is filled for
  # them sees the thank-you while nothing is stored or sent.
  HONEYPOT_FIELD = :leave_blank

  def new
    @submission = ContactSubmission.new
  end

  def create
    # A bot gets the same answer a person gets, and nothing is stored or sent.
    return redirect_to_sent if params.dig(:contact_submission, HONEYPOT_FIELD).present?

    @submission = ContactSubmission.new(submission_params)
    @submission.ip_address = request.remote_ip
    @submission.user_agent = request.user_agent

    saved = rescue_and_log(target: @submission) { @submission.save }
    return render(:new, status: :unprocessable_entity) unless saved

    notify(@submission)
    redirect_to_sent(sms: @submission.sms_consent?)
  end

  private

  def submission_params
    params.fetch(:contact_submission, {}).permit(:name, :email, :phone, :message,
                                                 :sms_care_consent, :sms_marketing_consent, :sms_declined)
  end

  # The app sends no text itself: the phone provider sends the opt-in
  # confirmation. `sms` only adds the program reminder to the thank-you.
  def redirect_to_sent(sms: false)
    flash[:contact_sent] = sms ? "sms" : "sent"
    redirect_to contact_form_path, status: :see_other
  end

  # Sent through the engine's outbox, like every other app email. The row is
  # the proof and is already saved, so a mail outage is logged for the operator
  # and must not turn a stored submission into an error page.
  def notify(submission)
    Studio::Email.deliver(ContactMailer, :submission, submission, to: ContactMailer::NOTIFY)
  rescue StandardError => e
    create_error_log(e)
  end
end
