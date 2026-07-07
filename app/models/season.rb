class Season < ApplicationRecord
  include Sluggable

  has_many :slates, foreign_key: :season_slug, primary_key: :slug
  has_many :athlete_grades, foreign_key: :season_slug, primary_key: :slug
  has_many :coach_rankings, foreign_key: :season_slug, primary_key: :slug
  has_many :pff_stats, foreign_key: :season_slug, primary_key: :slug
  has_many :pff_team_stats, foreign_key: :season_slug, primary_key: :slug
  has_many :team_rankings, foreign_key: :season_slug, primary_key: :slug
  has_many :nfl_team_total_projections, foreign_key: :season_slug, primary_key: :slug

  validates :year, presence: true
  validates :sport, presence: true
  validates :league, presence: true
  validates :name, presence: true
  validates :year, uniqueness: { scope: :league }

  scope :active, -> { where(active: true) }
  scope :nfl, -> { where(league: "nfl") }

  def self.active_nfl
    active.nfl.first
  end

  def name_slug
    "#{year}-#{league}"
  end
end
