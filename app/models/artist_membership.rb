# One stint of a member in a group. Years are nil when the source has none.
class ArtistMembership < ApplicationRecord
  belongs_to :member, class_name: "Artist", foreign_key: :member_artist_slug, primary_key: :slug,
             inverse_of: :group_memberships
  belongs_to :group, class_name: "Artist", foreign_key: :group_artist_slug, primary_key: :slug,
             inverse_of: :member_memberships

  validates :start_year, uniqueness: { scope: [:member_artist_slug, :group_artist_slug] }
  validate :distinct_ends

  scope :current, -> { where(end_year: nil) }

  private

  def distinct_ends
    errors.add(:group_artist_slug, "cannot be the member itself") if member_artist_slug == group_artist_slug
  end
end
