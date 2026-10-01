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
             with: -> { redirect_to contact_path, alert: "Too many messages. Try again in a minute." }

  # Hidden from people, so only a script fills it in.
  HONEYPOT_FIELD = :company_url

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
    redirect_to_sent
  end

  private

  def submission_params
    params.fetch(:contact_submission, {}).permit(:name, :email, :phone, :message,
                                                 :sms_care_consent, :sms_marketing_consent, :sms_declined)
  end

  def redirect_to_sent
    flash[:contact_sent] = true
    redirect_to contact_path, status: :see_other
  end

  # The row is the proof and is already saved. A mail outage is logged for the
  # operator and must not turn a stored submission into an error page.
  def notify(submission)
    ContactMailer.submission(submission).deliver_later
  rescue StandardError => e
    create_error_log(e)
  end
end
