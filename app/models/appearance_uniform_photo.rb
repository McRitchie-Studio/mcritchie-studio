# ONE GAME-ACTION PHOTO OF A LOOK'S UNIFORM, found by search and chosen (or not) by
# the operator (task player-sheet-uniform-and-build).
#
# THE SHEET COPIES THE UNIFORM FROM IT AND NOTHING ELSE: badges (team logo on both
# shoulders, NFL shield at the collar, a captain patch if one shows), number font,
# trim, pants and socks. Never a face: the prompt says so beside each image, and the
# photo lives in its own table so no face query (Appearances::ReferenceSet and the
# rest over appearance_reference_photos) can ever pick it up.
#
# Every search result is kept, chosen or not, for the reason AppearanceReferencePhoto
# gives: the operator judges the search by what it passed over too.
class AppearanceUniformPhoto < ApplicationRecord
  # AT MOST THIS MANY RIDE IN ONE SHEET BUILD: enough to show the jersey from the
  # front, the side and the back, few enough to leave the face the strongest signal.
  CHOSEN_LIMIT = 3

  belongs_to :appearance, foreign_key: :appearance_slug, primary_key: :slug, inverse_of: :uniform_photos

  validates :slug, presence: true, uniqueness: true
  validates :image_url, presence: true, uniqueness: { scope: :appearance_slug }
  validate :chosen_within_limit, if: -> { chosen? && will_save_change_to_chosen? }

  before_validation :generate_slug, on: :create

  scope :chosen, -> { where(chosen: true).order(:chosen_at, :id) }
  scope :candidates, -> { where(chosen: false).order(:position, :id) }

  def display_url = thumb_url.presence || image_url

  private

  def chosen_within_limit
    others = self.class.where(appearance_slug: appearance_slug, chosen: true).where.not(id: id).count
    return if others < CHOSEN_LIMIT

    errors.add(:base, "a look carries at most #{CHOSEN_LIMIT} uniform photos; remove one first")
  end

  def generate_slug
    self.slug ||= "uniform-#{SecureRandom.hex(6)}"
  end
end
