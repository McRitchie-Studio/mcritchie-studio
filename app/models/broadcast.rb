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

  # Links a template fixes in its copy rather than taking from a column:
  # template_key => { link key => URL }. Tracked like TRACKED_LINKS.
  TEMPLATE_LINKS = {
    "cyvasse_is_back" => {
      "play" => "https://cyvasse.mcritchie.studio/",
      "build" => "https://mcritchie.studio/build"
    }.freeze
  }.freeze

  # Registry of available copy templates: key => human label. Each key maps to
  # a view at app/views/broadcasts/<key>.html.erb.
  TEMPLATES = {
    "world_cup_kickoff"     => "World Cup Kickoff",
    "new_game_announcement" => "New Game Announcement",
    "cyvasse_is_back"       => "Cyvasse Is Back",
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
    return public_send(col) if col

    TEMPLATE_LINKS.fetch(template_key, {})[key.to_s]
  end

  # Every link key this broadcast's email can carry.
  def link_keys
    TRACKED_LINKS.keys + TEMPLATE_LINKS.fetch(template_key, {}).keys
  end

  # --- batch sends -----------------------------------------------------------
  # A broadcast can go out in batches (task broadcast-batch-send): each batch
  # takes N random subscribed contacts on the audience who have not yet been
  # sent this broadcast, so a list is worked down gradually and nobody gets it
  # twice. Sends are spaced BATCH_SPACING apart to stay under Resend's rate
  # limit (about 2 a second). A batch leaves the broadcast a draft; the editor's
  # full send still marks it sent.
  BATCH_SPACING = 0.6.seconds

  # Audiences whose sends go only to contacts an email check called valid
  # (task verify-contacts-with-zerobounce). The Cyvasse relaunch's first 101
  # sends hard-bounced 11.9%, so the old player list is mailed verified-only
  # unless a caller says otherwise; catch-all, unknown and unchecked contacts
  # wait. Verify with `contacts:verify`.
  VERIFIED_AUDIENCES = %w[cyvasse-legacy].freeze

  # Whether a send to `audience` is verified-only by default.
  def self.verification_required?(audience)
    VERIFIED_AUDIENCES.include?(audience.to_s)
  end

  # Contacts with a delivery this broadcast actually sent.
  def sent_contact_ids
    deliveries.where.not(sent_at: nil).select(:contact_id)
  end

  # Subscribed contacts on `audience` (a tag, or "all") still to be sent this.
  # `verified: true` keeps only contacts verified valid; nil takes the
  # audience's default (VERIFIED_AUDIENCES).
  def unsent_contacts(audience = target_list, verified: nil)
    verified = self.class.verification_required?(audience) if verified.nil?
    scope = audience.to_s == "all" ? Contact.subscribed : Contact.subscribed.with_tag(audience.to_s)
    scope = scope.verified_valid if verified
    scope.where.not(id: sent_contact_ids)
  end

  # Queue this broadcast to `size` random unsent contacts; returns their ids.
  def send_batch!(size:, audience: target_list, spacing: BATCH_SPACING, verified: nil)
    raise ArgumentError, "no audience: set the broadcast's target list or pass one" if audience.blank?
    raise ArgumentError, "batch size must be positive" unless size.to_i.positive?

    ids = unsent_contacts(audience, verified: verified).order(Arel.sql("RANDOM()")).limit(size.to_i).pluck(:id)
    ids.each_with_index { |contact_id, i| BroadcastSendJob.set(wait: spacing * i).perform_later(id, contact_id) }
    ids
  end

  # Where a batched send stands on `audience`. `remaining` counts only who a
  # batch would take (verified-only where that applies).
  def batch_status(audience = target_list, verified: nil)
    { sent: deliveries.where.not(sent_at: nil).count, remaining: unsent_contacts(audience, verified: verified).count,
      opened: opened_count, clicked: clicked_count }
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
