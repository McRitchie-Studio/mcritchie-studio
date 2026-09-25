class Athlete < ApplicationRecord
  include Sluggable

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
