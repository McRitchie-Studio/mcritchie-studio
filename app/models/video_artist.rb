# A credited artist on a music video: `primary` or `featured`, ordered by
# position within its role. A group (Migos) is credited as itself.
class VideoArtist < ApplicationRecord
  ROLES = %w[primary featured].freeze

  belongs_to :video, foreign_key: :video_slug, primary_key: :slug, inverse_of: :video_artists
  belongs_to :artist, foreign_key: :artist_slug, primary_key: :slug

  validates :role, inclusion: { in: ROLES }
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :artist_slug, uniqueness: { scope: :video_slug }
end
