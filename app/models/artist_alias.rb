# An alternate name for an artist (stage name, birth name, earlier name).
class ArtistAlias < ApplicationRecord
  belongs_to :artist, foreign_key: :artist_slug, primary_key: :slug, inverse_of: :aliases

  validates :name, :locale, presence: true
  validates :name, uniqueness: { scope: [:artist_slug, :locale] }
end
