class Game < ApplicationRecord
  include Sluggable

  belongs_to :slate, foreign_key: :slate_slug, primary_key: :slug
  belongs_to :home_team, class_name: "Team", foreign_key: :home_team_slug, primary_key: :slug
  belongs_to :away_team, class_name: "Team", foreign_key: :away_team_slug, primary_key: :slug

  has_many :team_total_projections, class_name: "NflTeamTotalProjection", foreign_key: :game_slug, primary_key: :slug, dependent: :destroy

  validates :slate_slug, presence: true
  validates :home_team_slug, presence: true
  validates :away_team_slug, presence: true

  # CSS gradient from away team color → home team color (diagonal — for hero cards)
  def hero_gradient_style
    away_color = away_team&.color_primary || "#6366f1"
    home_color = home_team&.color_primary || "#4BAF50"
    "background: linear-gradient(135deg, #{away_color} 0%, #{away_color} 40%, #{home_color} 60%, #{home_color} 100%);"
  end

  # CSS gradient for inline row rendering (horizontal home → away to match the
  # season view's home-on-left / away-on-right layout)
  def row_gradient_style
    away_color = away_team&.color_primary || "#6366f1"
    home_color = home_team&.color_primary || "#4BAF50"
    "background: linear-gradient(90deg, #{home_color} 0%, #{home_color} 30%, #{away_color} 70%, #{away_color} 100%);"
  end

  # True for neutral-site games (international, Super Bowl, etc.)
  def neutral_site?
    location.to_s.casecmp("neutral").zero?
  end

  def display_time
    return "TBD" unless kickoff_at
    kickoff_at.in_time_zone("Eastern Time (US & Canada)").strftime("%a %b %-d, %-I:%M %p ET")
  end

  def display_day
    return "TBD" unless kickoff_at
    kickoff_at.in_time_zone("Eastern Time (US & Canada)").strftime("%A, %B %-d")
  end

  def display_time_short
    return "TBD" unless kickoff_at
    kickoff_at.in_time_zone("Eastern Time (US & Canada)").strftime("%-I:%M %p ET")
  end

  def expected_total_for(team_or_slug)
    team_slug = team_or_slug.respond_to?(:slug) ? team_or_slug.slug : team_or_slug.to_s
    team_total_projections.find { |projection| projection.team_slug == team_slug } ||
      team_total_projections.find_by(team_slug: team_slug)
  end

  def home_expected_total
    expected_total_for(home_team_slug)&.expected_points
  end

  def away_expected_total
    expected_total_for(away_team_slug)&.expected_points
  end

  def name_slug
    "#{home_team_slug}-vs-#{away_team_slug}"
  end

  private

  # Override Sluggable — preserve custom slugs (e.g. "kc-at-bal")
  def set_slug
    self.slug = name_slug if slug.blank?
  end
end
