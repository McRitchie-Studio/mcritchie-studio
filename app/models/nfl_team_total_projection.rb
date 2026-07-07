class NflTeamTotalProjection < ApplicationRecord
  belongs_to :season, foreign_key: :season_slug, primary_key: :slug
  belongs_to :slate, foreign_key: :slate_slug, primary_key: :slug
  belongs_to :game, foreign_key: :game_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :opponent_team, class_name: "Team", foreign_key: :opponent_team_slug, primary_key: :slug
  belongs_to :favorite_team, class_name: "Team", foreign_key: :favorite_team_slug, primary_key: :slug

  validates :season_slug, :slate_slug, :game_slug, :team_slug, :opponent_team_slug, :week, presence: true
  validates :expected_points, :game_total, :home_spread, :favorite_team_slug, :favorite_spread, :source, :cached_at, presence: true
  validates :team_slug, uniqueness: { scope: :game_slug }
  validates :home, inclusion: { in: [true, false] }
  validates :week, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 18 }
  validate :team_participates_in_game

  scope :for_season, ->(season_slug) { where(season_slug: season_slug) }
  scope :for_week, ->(week) { where(week: week) }
  scope :for_team, ->(team_slug) { where(team_slug: team_slug) }
  scope :ordered, -> { order(:week, :game_slug, home: :desc) }

  private

  def team_participates_in_game
    return unless game

    participants = [game.home_team_slug, game.away_team_slug]
    errors.add(:team_slug, "must be one of the game's teams") unless participants.include?(team_slug)
    errors.add(:opponent_team_slug, "must be the opposing team") unless participants.include?(opponent_team_slug) && opponent_team_slug != team_slug
    errors.add(:favorite_team_slug, "must be one of the game's teams") unless participants.include?(favorite_team_slug)
    errors.add(:home, "does not match game home team") if !home.nil? && home != (team_slug == game.home_team_slug)
  end
end
