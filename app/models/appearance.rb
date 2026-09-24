# HOW A PERSON LOOKS in a generated image.
#
# The generalisation of "colorway". Anchored on Person rather than on a player
# because the hub models PEOPLE: a piece can cast Joe Burrow beside Jim Carrey
# and George Bush, and what differs between them is not who they are but how
# they are presented.
#
# Every person gets a DEFAULT, stamped by whichever write files their first
# look, so the common path never thinks about appearance at all. A variant —
# Burrow in a suit rather than a jersey — is an explicit later choice, and a
# look that is destroyed hands the default back rather than stranding it.
class Appearance < ApplicationRecord
  belongs_to :person, foreign_key: :person_slug, primary_key: :slug, inverse_of: :appearances, optional: true
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true
  has_many :artifact_subjects, foreign_key: :appearance_slug, primary_key: :slug, dependent: :nullify

  validates :slug, presence: true, uniqueness: true
  validates :person_slug, :descriptor, presence: true

  before_validation :generate_slug, on: :create
  before_validation :normalize_colorway
  after_create :become_default_if_first
  after_destroy :release_default_pointer

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

  # THE LOOK AN ATTACH FILES.
  #
  # Uploading an image for a named colorway is a STATEMENT about how this person
  # looks in it, so the attach files that look rather than leaving the row
  # unattributed. Filing nil instead is what made an attached artifact
  # unfindable: the row went in under "no look" while every read resolves nil to
  # the person's DEFAULT (ArtifactSubject#effective_appearance), so the reuse key
  # asked for `person@` and found `person@<default>`.
  #
  # IDEMPOTENT on the colorway, which is what lets the attach run on every
  # upload without accumulating looks. A RETIRED look in that colorway is not
  # revived — retiring it was a decision — so a fresh one is filed beside it.
  #
  # Returns nil when nothing names a colorway. There is then genuinely nothing
  # to file, and nil is the honest record: it means "no look was named AND the
  # person has none", which is exactly the state in which the read's nil
  # fallback agrees with it.
  def self.file_for_colorway!(person_slug:, colorway:)
    colorway = colorway.to_s.strip.downcase.presence
    return nil if colorway.blank? || person_slug.blank?

    live.find_by(person_slug: person_slug, colorway: colorway) ||
      create!(person_slug: person_slug, colorway: colorway,
              descriptor: available_descriptor(person_slug, colorway.titleize))
  end

  # `index_appearances_live_per_person` is UNIQUE on (person_slug, descriptor)
  # among live looks, so a person who already has a hand-named "Primary" in some
  # other colorway would make the create above raise RecordNotUnique rather than
  # file anything. Step past the taken names instead of failing the attach.
  def self.available_descriptor(person_slug, base)
    candidate = base
    suffix = 2
    while live.exists?(person_slug: person_slug, descriptor: candidate)
      candidate = "#{base} #{suffix}"
      suffix += 1
    end
    candidate
  end
  private_class_method :available_descriptor

  private

  # The FIRST look a person gets becomes their default. Doing it here rather
  # than at a call site means a person can never end up with looks and no
  # default, which is the state every lookup would have to special-case.
  #
  # RESOLVING rather than testing for a blank pointer keeps that promise on one
  # more path: a person whose default was left aimed at a look that is gone is
  # healed by their next look instead of staying stuck, because the old guard
  # read a dangling pointer as "already has one".
  def become_default_if_first
    person&.resolve_default_appearance!
  end

  # A LOOK THAT GOES AWAY MUST RELEASE THE SLOT IT HELD.
  #
  # Nothing else clears `people.default_appearance_slug` — there is no foreign
  # key on it and no dependent: on this side of the association — so without
  # this the pointer outlives the row and freezes the person in "has looks,
  # resolves no default" for good. Scoped by the COLUMN rather than through
  # #person because the column is a plain string that anyone could hold.
  def release_default_pointer
    Person.where(default_appearance_slug: slug).find_each do |holder|
      holder.resolve_default_appearance!
    end
  end

  def normalize_colorway
    self.colorway = colorway.to_s.strip.downcase.presence
  end

  def generate_slug
    self.slug ||= "look-#{SecureRandom.hex(6)}"
  end
end
