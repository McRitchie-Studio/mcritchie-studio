# A REUSABLE BODY-BUILD REFERENCE for the player sheet (task
# player-sheet-uniform-and-build, the operator's review of a real sheet 2026-10-11:
# "most football players have the same bulky athletic build. Perhaps you can
# generate some general archetype models to help in the model generation").
#
# A look points at one (Appearance#body_archetype); the sheet build sends its image
# as a reference whose ONLY role is build and proportions (Appearances::SheetReferences).
# Its `description` also rides in the prompt text, so an archetype with no image yet
# still tells the model what body to draw.
#
# THE IMAGE IS BOUGHT ONLY ON THE OPERATOR'S CLICK (/body-archetypes, Generate):
# each generation is one paid GPT-5 image (BodyArchetypes::Generate). The three
# starting rows were inserted by their migration WITHOUT images.
class BodyArchetype < ApplicationRecord
  BUILDING = "building"
  DONE = "done"
  FAILED = "failed"
  STALE_AFTER = 15.minutes

  # THE DEFAULT FOR AN ATHLETE WITH NO POSITION ON FILE, or one no row's hints name.
  # A quarterback-sized athletic build is the middle of the three, and the sheet this
  # task was opened for was a quarterback's.
  FALLBACK_SLUG = "nfl-qb-skill"

  has_many :appearances, foreign_key: :body_archetype_slug, primary_key: :slug, inverse_of: :chosen_body_archetype,
                         dependent: nil

  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ }
  validates :name, presence: true
  validates :description, presence: true

  scope :ordered, -> { order(:position, :slug) }

  # THE ARCHETYPE A POSITION DEFAULTS TO: the first row (in order) whose hints name
  # it, else the fallback row, else nil when no rows exist at all.
  def self.default_for(position)
    rows = ordered.to_a
    code = position.to_s.strip.upcase
    rows.find { |row| code.present? && row.position_hints.include?(code) } ||
      rows.find { |row| row.slug == FALLBACK_SLUG }
  end

  def image? = image_url.present?

  def building?
    generation_state == BUILDING && generation_started_at.present? && generation_started_at > STALE_AFTER.ago
  end

  def failed? = generation_state == FAILED

  # Marked building, but older than STALE_AFTER: the run died without closing its
  # claim (a dyno restart, a discarded job). A new press may replace it.
  def stalled? = generation_state == BUILDING && !building?

  def position_hint_list = position_hints.join(", ")
end
