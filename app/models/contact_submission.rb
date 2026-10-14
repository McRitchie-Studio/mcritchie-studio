# One submission of the public /contact form, kept as proof of SMS consent.
#
# Carriers ask a sender to show, for any number it texts, what the person was
# shown and what they ticked. So a row stores the three consent answers, the
# disclosure exactly as it was on the page (text and version), the time, the IP
# and the user agent. It is separate from Contact, which is the email mailing
# list: one row per address, edited over time. A submission is one event and is
# read-only once saved.
#
# The consent rules, enforced here so no caller can skip them:
#   - Nothing is pre-ticked. A box left alone is "no consent".
#   - "No" cannot be combined with either "Yes".
#   - The mobile number is optional, and required only with a "Yes".
#
# A row the controller judged to be a bot carries a `spam_reason`. It is kept,
# so a person wrongly judged can still be found, but nobody is emailed about it.
class ContactSubmission < ApplicationRecord
  # Bump when CONSENT_LABELS or DISCLOSURE_PARAGRAPHS change, so old rows keep
  # pointing at the wording their visitor actually saw.
  DISCLOSURE_VERSION = "2026-09-30".freeze

  SMS_NUMBER = "(303) 222-2113".freeze
  PRIVACY_URL = "https://mcritchie.studio/privacy".freeze

  CONSENT_LABELS = {
    sms_care_consent: "Yes, I consent to receive customer care messages from McRitchie Studio",
    sms_marketing_consent: "Yes, I consent to receive marketing text messages from McRitchie Studio",
    sms_declined: "No, I do not want to receive any text messages from McRitchie Studio"
  }.freeze

  # Carrier-required wording. Copy changes here are compliance changes.
  DISCLOSURE_PARAGRAPHS = [
    "McRitchie Studio LLC (doing business as McRitchie Studio) would like your consent to send customer care " \
      "and/or marketing text message communications from #{SMS_NUMBER} to your mobile number listed above. " \
      "Customer care messages may include responses to messages you send us, as well as information relevant " \
      "to your relationship with us. Marketing messages may include discount codes, special deals or texts " \
      "promoting our products/services.",
    "Consent is not a condition of purchase. Message frequency varies. Message and data rates may apply. " \
      "Reply 'STOP' to unsubscribe at any time. Reply 'HELP' for assistance or more information.",
    "We do not share your mobile opt-in information with anyone. Our combined Privacy Policy and Messaging " \
      "Terms and Conditions are available at #{PRIVACY_URL}."
  ].freeze

  NAME_LIMIT = 120
  EMAIL_LIMIT = 254
  PHONE_LIMIT = 40
  MESSAGE_LIMIT = 5_000
  USER_AGENT_LIMIT = 1_000

  # Why the controller judged a submission to be a bot. See
  # ContactSubmissionsController#spam_reason for how each is measured.
  SPAM_REASONS = %w[no_browser_proof too_fast].freeze

  # Where a submission came from, when a link carried it (an /integrations
  # card: {page, item, intent}, plus `ref`, the page the visitor came from).
  # Only these keys are kept, each a short plain token or path; anything else a
  # visitor writes into the URL is dropped, so the column never grows a free-
  # text field.
  SOURCE_KEYS = %w[page item intent ref].freeze
  SOURCE_VALUE = %r{\A[\w\-/.]{1,100}\z}

  # Kept out of #inspect, so a logged or raised record does not carry them. The
  # request log's own filter is in config/initializers/filter_parameter_logging.rb.
  self.filter_attributes += %i[phone message]

  normalizes :name, :phone, with: ->(value) { value.to_s.squish.presence }
  normalizes :email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :message, with: ->(value) { value.to_s.strip.presence }
  normalizes :source, with: ->(value) { ContactSubmission.clean_source(value) }
  normalizes :user_agent, with: ->(value) { value.to_s[0, USER_AGENT_LIMIT].presence }

  before_validation :stamp_disclosure, on: :create

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :email, presence: true, length: { maximum: EMAIL_LIMIT },
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: "doesn't look like an email address" }
  validates :message, presence: true, length: { maximum: MESSAGE_LIMIT }
  validates :phone, length: { maximum: PHONE_LIMIT }
  validates :disclosure_version, :disclosure_text, presence: true
  validates :spam_reason, inclusion: { in: SPAM_REASONS }, allow_nil: true
  validate :phone_is_a_phone_number
  validate :phone_present_when_consenting
  validate :decline_excludes_consent

  scope :recent, -> { order(created_at: :desc) }
  scope :flagged, -> { where.not(spam_reason: nil) }
  scope :unflagged, -> { where(spam_reason: nil) }

  # Everything the visitor was shown beside the boxes: the three labels, then
  # the paragraphs under the form.
  def self.disclosure_text
    (CONSENT_LABELS.values + DISCLOSURE_PARAGRAPHS).join("\n\n")
  end

  # A source hash with only the known keys, each a short token or path.
  def self.clean_source(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    return {} unless value.is_a?(Hash)

    value.to_h.stringify_keys.slice(*SOURCE_KEYS)
         .transform_values { |v| v.to_s.strip }
         .select { |_, v| v.match?(SOURCE_VALUE) }
  end

  # One line for the notification email, or nil with no source:
  # "page: integrations · item: github · intent: connect · ref: /integrations".
  def source_summary
    return if source.blank?

    SOURCE_KEYS.filter_map { |key| "#{key}: #{source[key]}" if source[key].present? }.join(" · ")
  end

  def flagged?
    spam_reason.present?
  end

  # The "Contact messages" section of the daily health report (studio-engine's
  # Studio::HealthReport, wired in config/initializers/studio.rb): every row
  # created in the window, newest first. Flagged rows count too and say so in
  # their label, so a real visitor the bot check misjudged is not hidden.
  def self.health_report(window)
    where(created_at: window).recent
  end

  # One line per row in the health report: "Jordan Lee <jordan@example.com>",
  # with "(flagged: too_fast)" on a row the bot check judged.
  def health_report_label
    label = "#{name} <#{email}>"
    flagged? ? "#{label} (flagged: #{spam_reason})" : label
  end

  def sms_consent?
    sms_care_consent? || sms_marketing_consent?
  end

  # One line for the notification email and any later list.
  def consent_summary
    return "Declined all text messages" if sms_declined?

    kinds = []
    kinds << "customer care" if sms_care_consent?
    kinds << "marketing" if sms_marketing_consent?
    kinds.any? ? "Consented to #{kinds.to_sentence} text messages" : "No answer (no consent given)"
  end

  def readonly?
    persisted?
  end

  private

  # Set by the server, never taken from the form: the proof must not be
  # something a visitor can write.
  def stamp_disclosure
    self.disclosure_version = DISCLOSURE_VERSION
    self.disclosure_text = self.class.disclosure_text
  end

  def phone_digits
    phone.to_s.gsub(/\D/, "")
  end

  def phone_is_a_phone_number
    return if phone.blank?

    errors.add(:phone, "must be a phone number with 10 to 15 digits") unless phone_digits.length.between?(10, 15) && phone.match?(/\A[\d\s().+-]+\z/)
  end

  def phone_present_when_consenting
    errors.add(:phone, "is required to receive text messages") if sms_consent? && phone.blank?
  end

  def decline_excludes_consent
    return unless sms_declined? && sms_consent?

    errors.add(:base, "Choose either Yes or No for text messages, not both")
  end
end
