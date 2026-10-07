class PffStat < ApplicationRecord
  include Sluggable
  # Its slug carries a snake_case word (a role, a stat or rank type), so a
  # rename accepts underscores between the words.
  self.slug_format = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/

  belongs_to :athlete, foreign_key: :athlete_slug, primary_key: :slug
  belongs_to :season, foreign_key: :season_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true

  validates :athlete_slug, presence: true
  validates :season_slug, presence: true
  validates :stat_type, presence: true
  validates :athlete_slug, uniqueness: { scope: [:season_slug, :stat_type] }

  scope :for_season, ->(slug) { where(season_slug: slug) }
  scope :of_type, ->(type) { where(stat_type: type) }

  def grade(field)
    data[field.to_s]&.to_f
  end

  def name_slug
    "#{athlete_slug}-#{season_slug}-#{stat_type}"
  end
end
