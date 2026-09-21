# HOW A PERSON LOOKS in a generated image.
#
# The generalisation of "colorway". Anchored on Person rather than on a player
# because the hub models PEOPLE: a piece can cast Joe Burrow beside Jim Carrey
# and George Bush, and what differs between them is not who they are but how
# they are presented.
#
# Every person gets a DEFAULT, stamped when their first model is created, so
# the common path never thinks about appearance at all. A variant — Burrow in a
# suit rather than a jersey — is an explicit later choice.
class Appearance < ApplicationRecord
  belongs_to :person, foreign_key: :person_slug, primary_key: :slug, inverse_of: :appearances, optional: true
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true
  has_many :artifact_subjects, foreign_key: :appearance_slug, primary_key: :slug, dependent: :nullify

  validates :slug, presence: true, uniqueness: true
  validates :person_slug, :descriptor, presence: true

  before_validation :generate_slug, on: :create
  before_validation :normalize_colorway
  after_create :become_default_if_first

  scope :live, -> { where(retired_at: nil) }

  def to_param = slug
  def retired? = retired_at.present?

  def default?
    person&.default_appearance_slug == slug
  end

  def make_default!
    person&.update!(default_appearance_slug: slug)
  end

  # What an image generator works from. An athlete's physical description comes
  # free off the Athlete record; for anyone with no role record the notes are
  # the only source, which is why they live here rather than on Person — the
  # same face in two eras is two looks, not one.
  def generation_brief
    athlete = person&.athlete_profile
    parts = [descriptor]
    if athlete
      parts << "Build: #{athlete.build}" if athlete.build.present?
      parts << "Skin tone: #{athlete.skin_tone}" if athlete.skin_tone.present?
      parts << "Hair: #{athlete.hair_description}" if athlete.hair_description.present?
    end
    parts << generation_notes if generation_notes.present?
    parts.compact_blank.join("\n")
  end

  def display_label
    [descriptor, (default? ? "(default)" : nil)].compact.join(" ")
  end

  private

  # The FIRST look a person gets becomes their default. Doing it here rather
  # than at a call site means a person can never end up with looks and no
  # default, which is the state every lookup would have to special-case.
  def become_default_if_first
    person&.update!(default_appearance_slug: slug) if person && person.default_appearance_slug.blank?
  end

  def normalize_colorway
    self.colorway = colorway.to_s.strip.downcase.presence
  end

  def generate_slug
    self.slug ||= "look-#{SecureRandom.hex(6)}"
  end
end
