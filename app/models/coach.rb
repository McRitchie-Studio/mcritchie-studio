class Coach < ApplicationRecord
  include Sluggable

  belongs_to :person, foreign_key: :person_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  has_many :coach_rankings, foreign_key: :coach_slug, primary_key: :slug
  has_many :image_caches, as: :owner, class_name: "ImageCache"

  ROLES = %w[head_coach offensive_coordinator defensive_coordinator special_teams_coordinator].freeze
  LEANS = %w[offense defense].freeze
  SPORTS = %w[football soccer].freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :sport, presence: true, inclusion: { in: SPORTS }
  validates :lean, inclusion: { in: LEANS }, allow_nil: true
  validates :person_slug, uniqueness: { scope: [:team_slug, :role] }

  # Ordering used by the /admin/models coaches table: grouped by team name,
  # then by coaching role (head coach first), then by person name.
  scope :ordered_for_admin, -> {
    role_order = <<~SQL.squish
      CASE coaches.role
      WHEN 'head_coach' THEN 1
      WHEN 'offensive_coordinator' THEN 2
      WHEN 'defensive_coordinator' THEN 3
      WHEN 'special_teams_coordinator' THEN 4
      ELSE 5
      END
    SQL
    order_sql = <<~SQL.squish
      LOWER(teams.name) ASC,
      #{role_order} ASC,
      LOWER(people.last_name) ASC,
      LOWER(people.first_name) ASC
    SQL

    joins(:person, :team)
      .includes(:person, :team)
      .order(Arel.sql(order_sql))
  }

  def name_slug
    "#{person_slug}-#{team_slug}-#{role.parameterize}"
  end

  def headshot_url(width: 400)
    cache = image_caches.detect { |c| c.purpose == "headshot" && c.variant == width.to_s }
    cache&.url
  end
end
