class DepthChartEntry < ApplicationRecord
  # Board primitive (studio-engine 0.29.0): the depth chart ranks by `depth`
  # (1 = starter, on top) while `position` holds the lane-code string, and pins
  # locked starters — DG1's configurable rank column + direction. reposition!
  # (via Studio::Board::Reorderable in DepthChartsController) writes `depth`.
  include Studio::Board::Rankable
  self.board_zone_attr  = :position
  self.board_rank_attr  = :depth
  self.board_rank_order = :asc

  belongs_to :depth_chart, foreign_key: :depth_chart_slug, primary_key: :slug
  belongs_to :person, foreign_key: :person_slug, primary_key: :slug

  validates :person_slug, :position, :side, :depth, presence: true
  validates :person_slug, uniqueness: { scope: [:depth_chart_slug, :position] }

  scope :offense,        -> { where(side: "offense") }
  scope :defense,        -> { where(side: "defense") }
  scope :special_teams,  -> { where(side: "special_teams") }
end
