# A generated image of one or more people.
#
# It carries NO person and NO colorway of its own — both live on its subjects.
# That is not tidiness: a mixed-cast image has three different looks in one
# frame, so an artifact-level uniform cannot describe it.
class Artifact < ApplicationRecord
  KINDS = %w[character_sheet pair group].freeze

  has_many :subjects, class_name: "ArtifactSubject", foreign_key: :artifact_slug,
                      primary_key: :slug, inverse_of: :artifact, dependent: :destroy
  has_many :people, through: :subjects, source: :person

  validates :slug, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  before_validation :generate_slug, on: :create

  scope :live, -> { where(retired_at: nil) }
  scope :approved, -> { where.not(approved_at: nil) }

  def to_param = slug
  def approved? = approved_at.present?
  def retired? = retired_at.present?

  def approve!(by: nil, at: Time.current) = update!(approved_at: at, approved_by: by)
  def retire!(at: Time.current) = update!(retired_at: at)

  def cast_label
    subjects.ordered.map(&:display_name).join(" + ")
  end

  # THE REUSE KEY: the exact set of (person, look) pairs. Two artifacts are the
  # same asset only when they show the same people wearing the same things.
  # Reads the association, NOT a fresh relation: `subjects.ordered` builds a new
  # query and discards any preload, so an includes() upstream was dead weight.
  def subject_key
    subjects.sort_by { |s| [s.ordinal, s.id] }.map { |s| "#{s.person_slug}@#{s.effective_appearance&.slug}" }.sort.join("|")
  end

  # Find a LIVE artifact showing exactly this cast in exactly these looks.
  # `pairs` is [[person_slug, appearance_slug], ...].
  #
  # `approved_only` defaults TRUE because reuse means "already signed off". The
  # inspection gate passes FALSE, and must: you attach an image and THEN approve
  # it, so a gate that could only see approved artifacts would never see the one
  # just attached — it would offer to generate a replacement for the image
  # sitting in front of you.
  #
  # `colorway` IS THE REQUEST'S OWN CONTEXT, and without it this comparison reads
  # two different facts as one. A nil appearance_slug means two things:
  #
  #   from an ARTIFACT — #subject_key emits "<person>@" when
  #   ArtifactSubject#effective_appearance is nil, i.e. NOBODY RECORDED what this
  #   person is wearing in the picture.
  #   from a REQUEST — Content::ArtifactPlan#appearance_for returns nil for a
  #   NAMED colorway when the person has no live look in it, i.e. NOTHING ON FILE
  #   SATISFIES this request.
  #
  # Both render as "<person>@", so a black-jersey request matched an artifact
  # whose jersey nobody had recorded and the gate said REUSE. Measured on this
  # code 2026-09-22 — a person with zero appearances, which is every person's
  # state until their first look is filed. The gate card still renders the real
  # image, so a human looking at the screen sees the picture; the DECISION LABEL
  # was wrong, and the label is what an operator trusts when skimming.
  #
  # THE TWO READERS DISAGREE ON PURPOSE and this does not make them agree.
  # #effective_appearance falls back to the person's default; #appearance_for
  # deliberately does not when a colorway is named, because falling back there
  # substitutes the jersey they happen to have for the one the game was played
  # in. What they now agree on is narrower and is the part that was broken: what
  # an ABSENT look means. Named colorway + unresolved look = not a match, ever.
  #
  # NO COLORWAY NAMED IS UNTOUCHED. There is then nothing for the artifact to
  # contradict, and refusing that match would make the gate offer to regenerate
  # an image it is already holding.
  def self.matching(pairs, kind:, approved_only: true, colorway: nil)
    return nil if colorway.present? && pairs.any? { |_person, appearance| appearance.blank? }

    want = pairs.map { |p, a| "#{p}@#{a}" }.sort.join("|")
    scope = approved_only ? live.approved : live
    scope.where(kind: kind).includes(subjects: :appearance).find { |a| a.subject_key == want }
  end

  private

  def generate_slug
    self.slug ||= "artifact-#{SecureRandom.hex(6)}"
  end
end
