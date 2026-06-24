# The original 151 Pokémon, seeded as reference data (db/seeds/56_pokemon.rb,
# from the committed db/seeds/data/pokemon.json that `rake pokemon:fetch` writes).
# Carries types + base stats so it's reusable beyond its first job — the per-task
# mascot draw (Task#assign_mascot stamps metadata.devops.mascot). No behavior is
# attached to a Pokémon: it is pure identity/reference data.
class Pokemon < ApplicationRecord
  GEN1_RANGE = (1..151).freeze

  # The shared Studio::Enumeral category holding each type's display color
  # (seeded in db/seeds/57_pokemon_type_colors.rb). Kept here so the
  # "pokemon_type" key lives with the model that owns types, not scattered across
  # the controller and view.
  TYPE_COLOR_CATEGORY = "pokemon_type".freeze

  validates :dex, presence: true,
                  uniqueness: true,
                  numericality: { only_integer: true, greater_than: 0 }
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :by_dex, -> { order(:dex) }
  scope :gen1, -> { where(generation: 1) }

  # The deck the mascot draw pulls from — the original 151.
  def self.deck
    gen1
  end

  # Draw one random Pokémon for a mascot, skipping any slug in `exclude` (the
  # mascots already held by live tasks). Deck-draw without replacement; if every
  # Pokémon is somehow taken (>151 live tasks) it falls back to the full deck
  # rather than returning nil, so a task always gets a face.
  def self.draw(exclude: [])
    taken = Array(exclude).compact_blank
    pool = deck.where.not(slug: taken)
    pool = deck unless pool.exists?
    pool.order(Arel.sql("RANDOM()")).first
  end

  # { type_key => hex color } for every seeded type, in ONE query — build it once
  # per page and look up each badge with no extra queries (avoids an N+1 over the
  # 151 rows). Empty when the enumeral table/gem isn't installed yet, so badges
  # fall back to the neutral chip.
  def self.type_colors
    Studio::Enumeral.color_map(TYPE_COLOR_CATEGORY)
  end

  # The hex color for one of this Pokémon's types, or nil — convenience for a
  # one-off lookup. The index page uses .type_colors instead so it queries once,
  # not once per badge.
  def type_color(type)
    Studio::Enumeral.color_for(TYPE_COLOR_CATEGORY, type)
  end

  def to_param
    slug
  end
end
