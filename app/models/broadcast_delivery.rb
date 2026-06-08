# One row per (broadcast, contact) recipient. Holds the send + engagement state
# (opens, clicks) and the opaque token embedded in the tracking pixel + click
# links, so every open/click is attributable to a specific contact.
class BroadcastDelivery < ApplicationRecord
  belongs_to :broadcast
  belongs_to :contact

  before_validation :ensure_token, on: :create
  validates :token, presence: true

  def record_open!
    now = Time.current
    update_columns(opened_at: opened_at || now, open_count: open_count + 1, updated_at: now)
  end

  def record_click!
    now = Time.current
    update_columns(clicked_at: clicked_at || now, click_count: click_count + 1, updated_at: now)
  end

  private

  def ensure_token
    self.token ||= SecureRandom.urlsafe_base64(16)
  end
end
