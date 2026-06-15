class Team < ApplicationRecord
  include Sluggable

  belongs_to :home_arena, class_name: "Arena", foreign_key: :home_arena_slug, primary_key: :slug, optional: true

  has_many :contracts, foreign_key: :team_slug, primary_key: :slug
  has_many :people, through: :contracts
  has_many :rosters, foreign_key: :team_slug, primary_key: :slug
  has_one  :depth_chart, foreign_key: :team_slug, primary_key: :slug, dependent: :destroy
  has_many :home_games, class_name: "Game", foreign_key: :home_team_slug, primary_key: :slug
  has_many :away_games, class_name: "Game", foreign_key: :away_team_slug, primary_key: :slug
  has_many :pff_team_stats, foreign_key: :team_slug, primary_key: :slug
  has_many :coaches, foreign_key: :team_slug, primary_key: :slug
  has_many :team_rankings, foreign_key: :team_slug, primary_key: :slug

  validates :name, presence: true

  before_validation :set_default_mascot, if: -> { self[:mascot].blank? && name.present? }

  scope :nfl, -> { where(league: "nfl") }
  scope :ncaa, -> { where(league: "ncaa") }
  scope :fifa, -> { where(league: "fifa") }
  scope :football, -> { where(sport: "football") }
  scope :soccer, -> { where(sport: "soccer") }

  def current_roster
    rosters.joins(:slate).order("slates.sequence DESC").first
  end

  # Team nickname derived from name - location.
  # e.g. "Los Angeles Rams" - "Los Angeles" => "Rams"; "San Francisco 49ers" - "San Francisco" => "49ers"
  def mascot
    self[:mascot].presence || derived_mascot
  end

  def name_slug
    name.parameterize
  end

  private

  def set_default_mascot
    self[:mascot] = derived_mascot
  end

  def derived_mascot
    return name if location.blank?

    name.sub(/\A#{Regexp.escape(location)}\s*/, "").strip.presence || name
  end
end
