class Slate < ApplicationRecord
  include Sluggable

  belongs_to :season, foreign_key: :season_slug, primary_key: :slug

  has_many :rosters, foreign_key: :slate_slug, primary_key: :slug
  has_many :games, foreign_key: :slate_slug, primary_key: :slug
  has_many :nfl_team_total_projections, foreign_key: :slate_slug, primary_key: :slug

  validates :season_slug, presence: true
  validates :sequence, presence: true, uniqueness: { scope: :season_slug }
  validates :label, presence: true
  validates :slate_type, presence: true

  scope :ordered, -> { order(:sequence) }

  def name_slug
    "#{season_slug}-#{label.parameterize}"
  end
end
