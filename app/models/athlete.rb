class Athlete < ApplicationRecord
  include Sluggable

  # WHAT A CACHED HEADSHOT IS, in one place, because it was in two and they
  # disagreed. Both writers built the same S3 key prefix from the same athlete
  # and only one of them survived contact with the data: Nflverse::SeedPlayers
  # defaulted the folder, and `nfl:upload_headshots` treated a missing team as a
  # reason to SKIP the athlete entirely. The team is a folder name, never a
  # precondition, and a constant plus a method is the only way to keep that true
  # for both callers at once.
  HEADSHOT_WIDTHS = [100, 400].freeze

  HEADSHOT_TEAMLESS_FOLDER = "free-agents".freeze

  belongs_to :person, foreign_key: :person_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true

  has_many :grades, class_name: "AthleteGrade", foreign_key: :athlete_slug, primary_key: :slug
  has_many :pff_stats, foreign_key: :athlete_slug, primary_key: :slug
  has_many :image_caches, as: :owner, class_name: "ImageCache"

  validates :person_slug, presence: true, uniqueness: true
  validates :sport, presence: true

  def name_slug
    "#{person_slug}-athlete"
  end

  def headshot_url(width: 400)
    cache = image_caches.detect { |c| c.purpose == "headshot" && c.variant == width.to_s }
    cache&.url
  end

  # WHERE THIS ATHLETE'S HEADSHOT VARIANTS LIVE IN S3. The folder is cosmetic —
  # it groups the objects by roster so a human can browse them — so a blank
  # team_slug falls back rather than stopping the upload. Reads team_slug, the
  # athlete's OWN column, and not a Contract: production carries 2,048 athletes
  # with a populated team_slug and ZERO rows in either `contracts` or `teams`
  # (measured 2026-09-26), so a contract-derived folder is not merely indirect,
  # it is unavailable.
  def headshot_key_prefix
    "headshots/nfl/#{team_slug.presence || HEADSHOT_TEAMLESS_FOLDER}/#{person_slug}"
  end

  # WHAT THIS BODY LOOKS LIKE, in the words an image generator works from.
  #
  # Lives here rather than being spelled out at each call site because it was
  # spelled out at two of them — Appearance#generation_brief and
  # Content::AssetsAgent#build_image_prompt — with the same three fields and the
  # same labels, and two copies of one sentence drift. The AssetsAgent copy was
  # the one that mattered: it is the text that actually reaches Higgsfield, so
  # anything added to the brief beside it would have been added to the version
  # nothing sends.
  #
  # Returns "" when the record carries none of the three, which lets a caller
  # `compact_blank` it away rather than test each field.
  def physical_brief
    [
      ("Build: #{build}" if build.present?),
      ("Skin tone: #{skin_tone}" if skin_tone.present?),
      ("Hair: #{hair_description}" if hair_description.present?)
    ].compact.join("\n")
  end
end
