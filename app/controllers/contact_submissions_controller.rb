# /contact — the public contact form, and the SMS opt-in page a carrier reviews.
#
#   GET  /contact   the form, the three consent boxes, the disclosure under it
#   POST /contact   store the submission as proof of consent, then tell Alex
#
# The consent rules live in ContactSubmission. This controller adds what only a
# request knows (IP, user agent) and keeps bots out with a rate limit, a
# honeypot and a browser proof.
#
# The rate limit and honeypot alone did not hold: a form-spam bot ("RobertniB",
# 2,000+ notices by 2026-10-06) rotates IPs and skips an off-screen field. It
# reads the HTML and posts it back without running JavaScript, and it posts
# within a second or two of loading the page. So the page carries a signed
# render time that only the page's JavaScript writes into the form, and a
# submission without it, or faster than a person types, is flagged.
class ContactSubmissionsController < ApplicationController
  helper_method :form_proof

  # A public form that writes a row and sends an email: bounded per IP.
  rate_limit to: 5, within: 1.minute, only: :create,
             with: -> { redirect_to contact_form_path, alert: "Too many messages. Try again in a minute." }

  # Hidden from people, so only a script fills it in. The name must match no
  # browser autofill heuristic (name, email, tel, url, company, address, ...):
  # autofill ignores autocomplete="off", and a visitor whose trap is filled for
  # them sees the thank-you while nothing is stored or sent.
  HONEYPOT_FIELD = :leave_blank

  # The browser proof. The page renders a signed render time in a data
  # attribute, and Alpine writes it, reversed, into this hidden field, so a
  # client that does not run the page's script submits it blank.
  PROOF_FIELD = :form_proof
  PROOF_PURPOSE = :contact_form
  # Name, email and a message take a person longer than this.
  MIN_FILL_SECONDS = 3
  # A tab left open overnight still counts as a browser.
  PROOF_TTL = 1.day

  # The signed render time a page carries, as the server issues it.
  def self.proof_for(rendered_at)
    verifier.generate(rendered_at.to_f, purpose: PROOF_PURPOSE, expires_in: PROOF_TTL)
  end

  def self.verifier
    Rails.application.message_verifier(PROOF_PURPOSE)
  end

  def new
    @submission = ContactSubmission.new
  end

  def create
    # A bot gets the same answer a person gets, and nothing is stored or sent.
    return redirect_to_sent if params.dig(:contact_submission, HONEYPOT_FIELD).present?

    @submission = ContactSubmission.new(submission_params)
    @submission.ip_address = request.remote_ip
    @submission.user_agent = request.user_agent
    @submission.spam_reason = spam_reason

    saved = rescue_and_log(target: @submission) { @submission.save }
    return render(:new, status: :unprocessable_entity) unless saved

    # A flagged row is kept for the record, and only an unflagged one reaches Alex.
    notify(@submission) unless @submission.flagged?
    redirect_to_sent(sms: @submission.sms_consent?)
  end

  private

  def form_proof
    self.class.proof_for(Time.current)
  end

  # nil for a person; otherwise why the submission looks like a bot.
  def spam_reason
    written = params.dig(:contact_submission, PROOF_FIELD).to_s.reverse
    rendered_at = self.class.verifier.verified(written, purpose: PROOF_PURPOSE) if written.present?
    return "no_browser_proof" unless rendered_at.is_a?(Numeric)
    return "too_fast" if Time.current.to_f - rendered_at < MIN_FILL_SECONDS

    nil
  end

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
