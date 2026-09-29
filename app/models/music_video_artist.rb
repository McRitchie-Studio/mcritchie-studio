# A credited artist on a music video: `primary` or `featured`, ordered by
# position within its role. A group (Migos) is credited as itself.
class MusicVideoArtist < ApplicationRecord
  ROLES = %w[primary featured].freeze

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :music_video_artists
  belongs_to :artist, foreign_key: :artist_slug, primary_key: :slug

  validates :role, inclusion: { in: ROLES }
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :artist_slug, uniqueness: { scope: :music_video_slug }
end
