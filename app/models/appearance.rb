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

  # THE PHOTOGRAPHS WE FOUND OF THIS PERSON, chosen and rejected both. DESTROYED
  # with the look rather than nullified, unlike the artifacts above: an artifact is
  # a picture that outlives the look it was filed under, while a candidate
  # photograph means nothing without the look whose identity it was judged for.
  has_many :reference_photos, class_name: "AppearanceReferencePhoto",
           foreign_key: :appearance_slug, primary_key: :slug,
           inverse_of: :appearance, dependent: :destroy

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
    [descriptor, person&.athlete_profile&.physical_brief, generation_notes]
      .compact_blank.join("\n")
  end

  # MAY A GENERATION NAME THIS LOOK'S HIGGSFIELD IDENTITY YET?
  #
  # An identity is minted `not_ready` and walks `queued` → `in_progress` →
  # `completed` (measured 2026-09-24 by creating a real one and polling it to
  # rest). Pinning a generation to one that is still training spends money on a
  # face nobody waited for, so the question has to be asked before every pin.
  #
  # POSITIVE FORM DELIBERATELY: this is true only for the one status we have
  # OBSERVED to mean success. The tempting inverse — "not one of the pending
  # words" — reads every status we have never seen, including whatever the API
  # says when the reference FAILS, as ready. `fail_reason` is a second signal
  # and this needs neither of them: an unrecognised word is not a yes.
  def higgsfield_reference_ready?
    higgsfield_reference_id.present? &&
      higgsfield_reference_status == Appearances::CreateCharacterReference::READY_STATUS
  end

  # Still becoming one. Distinct from "never asked for" (no id at all) and from
  # "the vendor said something we do not recognise", because only this state is
  # worth polling again.
  def higgsfield_reference_pending?
    higgsfield_reference_id.present? &&
      Appearances::CreateCharacterReference::PENDING_STATUSES.include?(higgsfield_reference_status)
  end

  # HOW MANY PHOTOGRAPHS THE IDENTITY WOULD BE BUILT FROM RIGHT NOW.
  #
  # Asked through Appearances::ReferenceSet rather than counted off
  # `reference_photos`, because the floor — the cached headshot and the operator's
  # URL — is derived rather than filed. Counting the table alone would report 0 for
  # every look that has never been searched, which is exactly the look the operator
  # opens first.
  def reference_photo_count = Appearances::ReferenceSet.call(self).length

  # ONE WORD FOR THE PAGE'S STATUS CHIP, and it is not the raw column.
  #
  # The column is nil for a look nobody has minted, and may hold a word the vendor
  # invented that we have never seen. Both are real states the page must name, and
  # neither has a value in the column to name it with — so the mapping lives here
  # instead of as a chain of conditionals in the view.
  def higgsfield_reference_state
    return :none if higgsfield_reference_id.blank?
    return :ready if higgsfield_reference_ready?
    return :pending if higgsfield_reference_pending?

    :unknown
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
  # will be right when something does. Whoever builds that inherits one more
  # thing, so do not read the sentence above as "the ground has been checked":
  # retiring a look does NOT release the artifacts filed under it, because
  # ArtifactSubject#effective_appearance reads the association rather than
  # `live`. The row keeps naming the retired look while the plan moves on to a
  # surviving one, and the artifact goes unfindable — the same write/read skew
  # this method exists to close, reached through a different door.
  #
  # Returns nil when nothing names a colorway. Nothing is filed, and the nil
  # write is still correct — not because the person has no looks (they may, and
  # a pointer a RAW delete orphaned still reads as none until their next look
  # resolves it; the destroy and merge routes now release it themselves) but
  # because with no colorway named the plan reads `person.default_appearance`
  # and the row's fallback reads that same expression. The two agree by
  # construction.
  #
  # THAT AGREEMENT IS NOT PERMANENT, and reading this as "nil is always safe"
  # is how the second half of the defect survived. The two nils mean the same
  # thing only while nothing names a colorway. Confirm the jersey afterwards —
  # ContentsController#set_colorway, one click — and the request's nil starts
  # meaning "nothing on file satisfies this" while the row's still means
  # "nobody recorded it", and both render `person@`. This IS the only route
  # left to an unattributed row, so it is where Artifact.matching's colorway
  # refusal earns its place; a reader who concludes that refusal is now dead
  # code would be wrong.
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
