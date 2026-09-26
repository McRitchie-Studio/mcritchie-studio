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
  #   unfetchable  — failed the SSRF/reachability guard. Never sent anywhere.
  #   duplicate    — the same image already on file under a better source.
  #   beyond_limit — good enough, but past the number we build an identity from.
  REJECTED_UNFETCHABLE = "unfetchable".freeze
  REJECTED_DUPLICATE = "duplicate".freeze
  REJECTED_BEYOND_LIMIT = "beyond_limit".freeze
  REJECTION_REASONS = [REJECTED_UNFETCHABLE, REJECTED_DUPLICATE, REJECTED_BEYOND_LIMIT].freeze

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

  # GALLERY ORDER, and it is deliberately not `created_at`.
  #
  # Chosen photographs lead, because the first question the page answers is
  # "what did the identity get built from". Within each half, the provider's own
  # rank leads: hit 1 being wrong says something different about a search than
  # hit 18 being wrong, and that signal is destroyed by any other sort.
  # NULLS LAST keeps the headshot and the operator's URL — which have no rank —
  # from sorting ahead of the ranked hits on Postgres, where NULL sorts high by
  # default in ascending order.
  scope :gallery_order, -> {
    order(Arel.sql("chosen DESC, position ASC NULLS LAST, created_at ASC, id ASC"))
  }

  def to_param = slug

  # The photograph's own page, when the provider named one. Worth its own reader
  # because the gallery links the thumbnail to it: judging a search hit usually
  # means looking at where it came from, not only at the crop.
  def origin_url = page_url.presence || image_url

  def from_search? = source == SOURCE_SEARCH

  private

  def generate_slug
    self.slug ||= "refphoto-#{SecureRandom.hex(6)}"
  end
end
