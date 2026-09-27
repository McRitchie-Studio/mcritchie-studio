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
  # athlete's OWN column, and not a Contract: production carries 2,051 athletes
  # with a populated team_slug and ZERO rows in either `contracts` or `teams`
  # (measured 2026-09-26; 2,048 of those 2,051 also carry an espn_id, which is the
  # candidate count `nfl:upload_headshots` prints and the number this comment used
  # to give here), so a contract-derived folder is not merely indirect, it is
  # unavailable.
  #
  # A CONTRACT-DERIVED FOLDER WAS TRIED ANYWAY, by hand, against production on the
  # day this method merged: every lookup returned nil against those empty tables
  # and all 2,043 athletes with a cached headshot were filed under `free-agents/`,
  # rostered players included. `nfl:rekey_headshots` re-files them by calling THIS
  # method, and `nfl:upload_headshots` cannot, because it grades completeness by
  # variant presence and never by key.
  def headshot_key_prefix
    "headshots/nfl/#{team_slug.presence || HEADSHOT_TEAMLESS_FOLDER}/#{person_slug}"
  end

  # THE VARIANTS A COMPLETE HEADSHOT HAS. "original" is in the list because
  # Studio::ImageCache.cache! stores the unmodified source under that name PLUS
  # one variant per width -- and leaving it out has already been paid for once:
  # a row set holding only 100 and 400 was read as complete, which both hid the
  # gap and inflated the denominator `nfl:upload_headshots` graded itself on.
  def self.headshot_variants
    ["original", *HEADSHOT_WIDTHS.map(&:to_s)]
  end

  # EVERY REQUIRED VARIANT IS ON FILE. Reads the LOADED `image_caches`, so a
  # caller that preloaded them pays no query per athlete -- which
  # `nfl:upload_headshots` depends on across ~2,000 rows.
  #
  # BLIND TO A WRONG KEY, DELIBERATELY. Presence is judged by VARIANT and never
  # by s3_key, so the 2,043 athletes filed under a stale folder read as complete
  # here. That is why `nfl:rekey_headshots` exists and why the upload task counts
  # that drift on its own line: a stale folder still serves every avatar
  # correctly, so it is a taxonomy defect rather than a missing headshot.
  def headshot_complete?
    have = image_caches.select { |c| c.purpose == "headshot" }.map(&:variant)
    (self.class.headshot_variants - have).empty?
  end

  # THE POPULATION A HEADSHOT LANE CAN BE HELD TO: still missing a variant, AND
  # carrying a source to fetch one from.
  #
  # A VERDICT MUST BE CLEARABLE BY FIXING WHAT IT ACCUSES, which is why this is a
  # statement about the DATA ON FILE rather than about a run, and why it lives
  # beside the other headshot facts rather than inline in the task that grades on
  # it. `nfl:upload_headshots` used to grade itself on every athlete short a
  # variant; eight of those have no espn_headshot_url and never will, so the
  # verdict accused the lane of declining work no run could ever have done and
  # fired on every healthy re-run for ever. An athlete with no source is a data
  # gap: reported by name, never counted against the lane.
  #
  # FALSE FOR A COMPLETE ATHLETE even when a source is on file, because there is
  # nothing left to fetch. Any caller asking this AFTER a completeness gate gets
  # the same answer as asking for the source alone; a caller asking it BEFORE one
  # must not read a false as "no source".
  def headshot_fetchable?
    espn_headshot_url.present? && !headshot_complete?
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
