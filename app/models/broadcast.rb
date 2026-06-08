# A marketing email composed in Studio. The branded shell lives in
# layouts/broadcast_email.html.erb; the swappable copy is a view under
# app/views/broadcasts/ keyed by `template_key`. Studio is the system-of-record
# (history + status); the actual send is done by pasting the rendered HTML into
# HubSpot (which owns the list, unsubscribe + compliance footer).
class Broadcast < ApplicationRecord
  include Sluggable

  STATUSES = %w[draft sent].freeze

  # Registry of available copy templates: key => human label. Each key maps to
  # a view at app/views/broadcasts/<key>.html.erb.
  TEMPLATES = {
    "world_cup_kickoff"     => "World Cup Kickoff",
    "new_game_announcement" => "New Game Announcement",
  }.freeze

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

  private

  # Stable random slug (Sluggable rewrites from name_slug on every save).
  def name_slug
    slug.presence || "bcast-#{SecureRandom.hex(6)}"
  end
end
