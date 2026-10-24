# A public form's browser proof (the defence ContactSubmissionsController
# proved against the "RobertniB" form-spam bot, 2026-10-06): the page carries a
# signed render time in a data attribute, the page's own script writes it
# REVERSED into a hidden field, and a post without it, or faster than a person
# types, is flagged. A bot that reads the HTML and posts it back without running
# JavaScript sends it blank. Pair it with a rate limit and a honeypot field.
#
#   proof = BrowserProof.new(:build_chat, min_seconds: 2)
#   proof.issue                       # the data attribute's value
#   proof.reason(params[:form_proof]) # nil for a person; "no_browser_proof" | "too_fast"
class BrowserProof
  TTL = 1.day
  # Hidden from people, so only a script fills it in. The name matches no
  # browser autofill heuristic (see ContactSubmissionsController::HONEYPOT_FIELD).
  HONEYPOT_FIELD = :leave_blank
  PROOF_FIELD = :form_proof

  attr_reader :rendered_at

  def initialize(purpose, min_seconds: 3, now: Time.current)
    @purpose = purpose.to_sym
    @min_seconds = min_seconds
    @now = now
  end

  def issue(rendered_at = @now) = verifier.generate(rendered_at.to_f, purpose: @purpose, expires_in: TTL)

  # nil when `written` (the field as posted, reversed) proves a browser that
  # took long enough; otherwise why not.
  def reason(written)
    value = written.to_s.reverse
    stamp = verifier.verified(value, purpose: @purpose) if value.present?
    return "no_browser_proof" unless stamp.is_a?(Numeric)

    @rendered_at = Time.zone.at(stamp)
    return "too_fast" if @now.to_f - stamp < @min_seconds

    nil
  end

  private

  def verifier = Rails.application.message_verifier(@purpose)
end
