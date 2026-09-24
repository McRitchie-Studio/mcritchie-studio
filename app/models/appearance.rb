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
  # upload without accumulating looks. It rests on the find_by ALONE — there is
  # no unique index on (person_slug, colorway), only the partial one on
  # (person_slug, descriptor).
  #
  # SETS THE DEFAULT when this is the person's first look, because
  # `become_default_if_first` fires on the create. So an ATTACH can stamp a
  # person's default, and every nil-appearance row already on file for them
  # re-resolves to it. That is correct rather than incidental: with no colorway
  # named, the plan reads `person.default_appearance` and a nil row's fallback
  # reads the same expression, so the two move together. A read that NAMES a
  # colorway does not move with them — and should not, because it correctly
  # drops to :reskin rather than reusing a colorway-less artifact for a named
  # jersey.
  #
  # A retired look in that colorway is not revived; a fresh one is filed beside
  # it, and the partial index (`where retired_at IS NULL`) leaves the old name
  # free. Nothing in the app retires a look yet — this is the behaviour that
  # will be right when something does.
  #
  # Returns nil when nothing names a colorway. Nothing is filed, and the nil
  # write is still correct — not because the person has no looks (they may: the
  # default pointer can dangle) but because with no colorway named the plan
  # reads `person.default_appearance` and the row's fallback reads that same
  # expression. The two agree by construction.
  def self.file_for_colorway!(person_slug:, colorway:)
    colorway = colorway.to_s.strip.downcase.presence
    return nil if colorway.blank? || person_slug.blank?

    live.find_by(person_slug: person_slug, colorway: colorway) ||
      create!(person_slug: person_slug, colorway: colorway,
              descriptor: available_descriptor(person_slug, descriptor_base(colorway)))
  end

  # COLORWAY IS FREE TEXT — the jersey field at the inspection gate takes
  # whatever the operator types — so `titleize` is not safe to use bare here.
  # It returns "" for anything that is all punctuation ("_" and "-" both do),
  # which fails the descriptor presence validation and raises RecordInvalid
  # mid-attach; `rescue_and_log` re-raises, so the operator got an error page
  # rather than their image. Fall back to the raw colorway, which is already
  # known non-blank by the guard above.
  def self.descriptor_base(colorway)
    colorway.titleize.presence || colorway
  end
  private_class_method :descriptor_base

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
