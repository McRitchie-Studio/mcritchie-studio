class CoachRanking < ApplicationRecord
  include Sluggable
  # Its slug carries a snake_case word (a role, a stat or rank type), so a
  # rename accepts underscores between the words.
  self.slug_format = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/

  belongs_to :coach, foreign_key: :coach_slug, primary_key: :slug
  belongs_to :season, foreign_key: :season_slug, primary_key: :slug

  RANK_TYPES = %w[pass_first pass_heavy].freeze

  validates :rank_type, presence: true, inclusion: { in: RANK_TYPES }
  validates :rank, presence: true, inclusion: { in: 1..32 }
  validates :coach_slug, uniqueness: { scope: [:rank_type, :season_slug] }

  scope :pass_first, -> { where(rank_type: "pass_first") }
  scope :pass_heavy, -> { where(rank_type: "pass_heavy") }
  scope :for_season, ->(slug) { where(season_slug: slug) }

  def name_slug
    "#{coach_slug}-#{rank_type}-#{season_slug}"
  end
end
