# A marketing email composed + sent from Studio. The branded shell lives in
# layouts/broadcast_email.html.erb; the swappable copy is a view under
# app/views/broadcasts/ keyed by `template_key`. Studio owns the contact list and
# the send (via BroadcastMailer); each recipient gets a BroadcastDelivery that
# tracks opens/clicks.
class Broadcast < ApplicationRecord
  include Sluggable

  STATUSES = %w[draft sent].freeze

  # Links available for click-tracking: key => the column holding the URL.
  # "hero" is the clickable header image.
  TRACKED_LINKS = { "hero" => :hero_url, "survivor" => :survivor_url, "turf_totals" => :turf_totals_url }.freeze

  # Registry of available copy templates: key => human label. Each key maps to
  # a view at app/views/broadcasts/<key>.html.erb.
  TEMPLATES = {
    "world_cup_kickoff"     => "World Cup Kickoff",
    "new_game_announcement" => "New Game Announcement",
  }.freeze

  has_many :deliveries, class_name: "BroadcastDelivery", dependent: :destroy

  validates :subject, presence: true
  validates :template_key, inclusion: { in: TEMPLATES.keys }
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(updated_at: :desc) }

  def template_label
    TEMPLATES[template_key] || template_key
  end

  def status_label
    status.titleize
  end

  def sent?
    status == "sent"
  end

  # Resolve a click-tracking link key to its destination URL (server-side, so the
  # click endpoint can't be turned into an open redirect).
  def link_for(key)
    col = TRACKED_LINKS[key.to_s]
    col && public_send(col)
  end

  # --- engagement ------------------------------------------------------------
  def delivered_count = deliveries.count
  def opened_count    = deliveries.where.not(opened_at: nil).count
  def clicked_count   = deliveries.where.not(clicked_at: nil).count

  def open_rate
    delivered_count.zero? ? nil : opened_count.to_f / delivered_count
  end

  def click_rate
    delivered_count.zero? ? nil : clicked_count.to_f / delivered_count
  end

  private

  # Stable random slug (Sluggable rewrites from name_slug on every save).
  def name_slug
    slug.presence || "bcast-#{SecureRandom.hex(6)}"
  end
end
