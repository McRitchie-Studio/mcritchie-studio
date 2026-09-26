# ONE PHOTOGRAPH WE FOUND OF A PERSON, chosen or rejected.
#
# The row survives the search that produced it so the operator can judge the
# SEARCH rather than only its result: a gallery showing just the winners cannot
# distinguish "the search found four good portraits and we took them all" from
# "the search found four stock logos and we took them for want of anything
# better". Both halves are on the page because both halves are the evidence.
class AppearanceReferencePhoto < ApplicationRecord
  belongs_to :appearance, foreign_key: :appearance_slug, primary_key: :slug,
                          inverse_of: :reference_photos, optional: true

  # WHO FOUND THE PHOTOGRAPH, in descending order of how far we trust it.
  #
  #   headshot — our own mirrored copy of the ESPN portrait. The only URL whose
  #              public reachability we control and have measured.
  #   operator — typed into the look form by a human who looked at it.
  #   search   — an image-search provider's answer. Nobody has seen it.
  #
  # The gallery prints this beside every photograph, because "the search found
  # this" and "you chose this" deserve different confidence from a reviewer.
  SOURCE_HEADSHOT = "headshot".freeze
  SOURCE_OPERATOR = "operator".freeze
  SOURCE_SEARCH = "search".freeze
  SOURCES = [SOURCE_HEADSHOT, SOURCE_OPERATOR, SOURCE_SEARCH].freeze

  # WHY A CANDIDATE WAS PASSED OVER. Enumerated rather than free text so the
  # gallery can style them and so a new reason has to be declared here, where
  # the reader of a reject list will find it.
  #
  #   unfetchable   — failed the SSRF/reachability guard. Never sent anywhere.
  #   duplicate     — the same photograph reached us at two different URLs.
  #                   ⚠ NOTHING IN THE APP STAMPS THIS YET, and that is a stated
  #                   gap rather than an oversight. The unique index is on
  #                   (appearance_slug, image_url), so the same image served from
  #                   two URLs is two rows and can occupy two slots in one
  #                   identity — a real case (Wikimedia serves every file from both
  #                   `upload.wikimedia.org/.../500px-X` and
  #                   `commons.wikimedia.org/wiki/Special:FilePath/X`). Catching it
  #                   needs a perceptual hash of the BYTES, which means fetching
  #                   them, which this lane deliberately never does. The value is
  #                   declared so the gallery can render the state and so the fix
  #                   has somewhere to land.
  #   face_obscured — something LOOKED at it and found no usable face (a helmet,
  #                   the back of a head, a document scan). Stamped only when
  #                   Appearances::FaceVisibility actually ran on this photograph:
  #                   a candidate nobody classified is `beyond_limit`, because a
  #                   reason the operator reads as a judgement must not be a guess.
  #   not_a_photo   — not a photograph of a person at all: a scanned book page, a
  #                   media-guide PDF, a diagram. NEVER chosen at any supply level,
  #                   which is what separates it from `face_obscured`: a helmeted
  #                   shot of the right person is a poor reference, a scan of an
  #                   1896 edition of The Rape of the Lock is not a reference at
  #                   all. Both were real hits for "Drew Lock" (measured 2026-09-26:
  #                   12 of 20 Wikimedia Commons results were scanned documents).
  #   beyond_limit  — good enough, but past the number we build an identity from.
  REJECTED_UNFETCHABLE = "unfetchable".freeze
  REJECTED_DUPLICATE = "duplicate".freeze
  REJECTED_FACE_OBSCURED = "face_obscured".freeze
  REJECTED_NOT_A_PHOTO = "not_a_photo".freeze
  REJECTED_BEYOND_LIMIT = "beyond_limit".freeze
  REJECTION_REASONS = [REJECTED_UNFETCHABLE, REJECTED_DUPLICATE, REJECTED_FACE_OBSCURED,
                       REJECTED_NOT_A_PHOTO, REJECTED_BEYOND_LIMIT].freeze

  # WHAT THE UNIQUE INDEX CAN PHYSICALLY HOLD, and the reason it is a validation
  # rather than a column limit.
  #
  # `index_reference_photos_unique_per_look` is a btree over (appearance_slug,
  # image_url). Postgres refuses a btree entry larger than about 2,704 bytes AT
  # INSERT TIME — not at migrate time — so without a cap here, one freakishly
  # long search hit would raise from inside the search action and lose the whole
  # batch. 2,048 is comfortably under the limit and comfortably over any real
  # image URL; a candidate longer than this is a data-URI or a tracking blob
  # rather than a photograph, so dropping it costs nothing.
  MAX_URL_LENGTH = 2_048

  validates :slug, presence: true, uniqueness: true
  validates :image_url, presence: true, length: { maximum: MAX_URL_LENGTH }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :appearance_slug, presence: true
  validates :rejection_reason, inclusion: { in: REJECTION_REASONS }, allow_blank: true

  before_validation :generate_slug, on: :create

  scope :chosen, -> { where(chosen: true) }
  scope :rejected, -> { where(chosen: false) }

  # GALLERY ORDER — OUR ranking, not the provider's.
  #
  # Chosen photographs lead, because the first question the page answers is "what
  # did the identity get built from".
  #
  # Within each half, FACE SCORE leads and the provider's `position` only breaks
  # ties. That order is the whole point of the ranking step: the provider ranks by
  # its own idea of relevance, which says nothing about whether you can see the
  # person's face — and on the operator's own labelled example the provider's hit 1
  # was the only bare-faced photograph in a set of four while hits 2 and 3 were
  # helmets. Sorting by `position` would put the gallery back in the order the
  # ranking exists to correct, and the operator would see no change.
  #
  # NULLS LAST ON BOTH KEYS, for two different absences: an unscored row (nobody
  # looked) and an unranked one (the headshot and the operator's URL have no
  # provider rank). Postgres sorts NULL HIGH in ascending order and FIRST in
  # descending, so without this an unscored row would lead the gallery.
  scope :gallery_order, -> {
    order(Arel.sql("chosen DESC, face_score DESC NULLS LAST, position ASC NULLS LAST, created_at ASC, id ASC"))
  }

  def to_param = slug

  # The photograph's own page, when the provider named one. Worth its own reader
  # because the gallery links the thumbnail to it: judging a search hit usually
  # means looking at where it came from, not only at the crop.
  def origin_url = page_url.presence || image_url

  def from_search? = source == SOURCE_SEARCH

  # Was this photograph actually LOOKED AT by the classifier? Distinct from
  # `face_score.zero?`, which means "looked at and saw nothing" — the opposite
  # judgement from "never looked", and the page prints them differently.
  def face_scored? = face_score.present?

  # 0.0..1.0 as a percentage for the chip, or nil when nobody looked.
  def face_score_percent = face_scored? ? (face_score * 100).round : nil

  private

  def generate_slug
    self.slug ||= "refphoto-#{SecureRandom.hex(6)}"
  end
end
