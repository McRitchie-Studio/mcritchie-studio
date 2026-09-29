# A mailing-list subscriber owned by Studio (imported from HubSpot or added
# manually). Holds the merge fields (first_name) and the unsubscribe state +
# token. Sending suppresses anyone not `subscribed`.
class Contact < ApplicationRecord
  has_many :deliveries, class_name: "BroadcastDelivery", dependent: :destroy

  before_validation :normalize_email
  before_validation :ensure_unsubscribe_token, on: :create

  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }

  scope :subscribed, -> { where(subscribed: true) }
  scope :with_tag,   ->(tag) { where("? = ANY(tags)", tag) }
  scope :recent,     -> { order(created_at: :desc) }

  # --- email verification (task verify-contacts-with-zerobounce) -------------
  # The statuses ZeroBounce reports, stored as it spells them.
  VERIFICATION_STATUSES = %w[valid invalid catch-all unknown spamtrap abuse do_not_mail].freeze
  # A result that says the address must never be mailed: the contact is
  # unsubscribed with reason "verification" when it is recorded. catch-all and
  # unknown stay subscribed, but a verified-only send skips them.
  UNDELIVERABLE_STATUSES = %w[invalid spamtrap abuse do_not_mail].freeze

  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }, allow_nil: true

  scope :verified,       -> { where.not(verified_at: nil) }
  scope :unverified,     -> { where(verified_at: nil) }
  scope :verified_valid, -> { where(verification_status: "valid") }

  def first_name_or_default
    first_name.presence || "there"
  end

  # Why a contact left the list; the first reason sticks.
  #   requested    — the unsubscribe page
  #   bounced      — a permanent bounce
  #   complained   — marked as spam
  #   verification — an email check said the address is undeliverable
  UNSUBSCRIBE_REASONS = %w[requested bounced complained verification].freeze

  # The reader changed their mind (the unsubscribe landing's button): back on
  # the list, the unsubscribe forgotten.
  def resubscribe!
    update!(subscribed: true, unsubscribed_at: nil, unsubscribe_reason: nil)
  end

  def unsubscribe!(reason: "requested")
    raise ArgumentError, "unknown unsubscribe reason #{reason.inspect}" unless UNSUBSCRIBE_REASONS.include?(reason.to_s)
    return if !subscribed? && unsubscribe_reason.present?

    update!(subscribed: false, unsubscribed_at: unsubscribed_at || Time.current,
            unsubscribe_reason: unsubscribe_reason.presence || reason)
  end

  # True when a verification said this address must never be mailed, whatever
  # its subscription says (a resubscribe does not make a spamtrap safe).
  def undeliverable?
    UNDELIVERABLE_STATUSES.include?(verification_status)
  end

  # Store one verification result, and take an undeliverable address off the
  # list in the same transaction.
  def record_verification!(status:, sub_status: nil, at: Time.current)
    status = status.to_s.strip.downcase
    raise ArgumentError, "unknown verification status #{status.inspect}" unless VERIFICATION_STATUSES.include?(status)

    transaction do
      update!(verification_status: status, verification_sub_status: sub_status.to_s.strip.presence, verified_at: at)
      unsubscribe!(reason: "verification") if undeliverable?
    end
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def ensure_unsubscribe_token
    self.unsubscribe_token ||= SecureRandom.urlsafe_base64(24)
  end
end
