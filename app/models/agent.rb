class Agent < ApplicationRecord
  include Sluggable

  has_many :tasks, foreign_key: :agent_slug, primary_key: :slug, dependent: :nullify
  has_many :activities, foreign_key: :agent_slug, primary_key: :slug, dependent: :destroy
  has_many :usages, foreign_key: :agent_slug, primary_key: :slug, dependent: :destroy
  has_many :skill_assignments, foreign_key: :agent_slug, primary_key: :slug, dependent: :destroy
  has_many :skills, through: :skill_assignments

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :active, -> { where(status: "active") }

  AVATAR_COLORS = %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899].freeze

  # Deterministic single-letter initial for any seed string — the fallback face
  # for an avatar with no image. Shared so a non-Agent (e.g. an unresolved
  # TaskEvent actor) can borrow the same rule.
  def self.initials_for(seed)
    seed.to_s.strip.first.presence&.upcase || "?"
  end

  # Deterministic AVATAR_COLORS hue for any seed string. Shared so a non-Agent
  # stand-in renders in the same palette as a real soul.
  def self.avatar_color_for(seed)
    AVATAR_COLORS[Digest::MD5.hexdigest(seed.to_s).hex % AVATAR_COLORS.size]
  end

  def name_slug
    name.parameterize
  end

  def avatar_initials
    self.class.initials_for(name)
  end

  def avatar_color
    self.class.avatar_color_for(slug)
  end

  # Status-line persona identity. When a session "acts as" a soul (a task with a
  # persona), bin/statusline shows the agent's emoji + name + color in place of the
  # session's Pokémon — see Task#sync_app_identity / #persona_identity. `emoji` is
  # the agent's glyph (seeded in db/seeds/02_agents.rb); `status_color` falls back
  # to the deterministic avatar hue when an explicit color isn't seeded.
  def emoji
    metadata&.dig("emoji").presence
  end

  def status_color
    metadata&.dig("color").presence || avatar_color
  end
end
