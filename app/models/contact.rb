# A mailing-list subscriber owned by Studio (imported from HubSpot or added
# manually). Holds the merge fields (first_name) and the unsubscribe state +
# token. Sending suppresses anyone not `subscribed`.
class Contact < ApplicationRecord
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

  def unsubscribe!
    update!(subscribed: false, unsubscribed_at: Time.current)
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def ensure_unsubscribe_token
    self.unsubscribe_token ||= SecureRandom.urlsafe_base64(24)
  end
end
