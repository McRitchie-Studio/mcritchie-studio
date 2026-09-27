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

  def first_name_or_default
    first_name.presence || "there"
  end

  # reason: "requested" (the unsubscribe page), "bounced" (a permanent
  # bounce) or "complained" (marked as spam). The first reason sticks.
  # The reader changed their mind (the unsubscribe landing's button): back on
  # the list, the unsubscribe forgotten.
  def resubscribe!
    update!(subscribed: true, unsubscribed_at: nil, unsubscribe_reason: nil)
  end

  def unsubscribe!(reason: "requested")
    return if !subscribed? && unsubscribe_reason.present?

    update!(subscribed: false, unsubscribed_at: unsubscribed_at || Time.current,
            unsubscribe_reason: unsubscribe_reason.presence || reason)
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def ensure_unsubscribe_token
    self.unsubscribe_token ||= SecureRandom.urlsafe_base64(24)
  end
end
