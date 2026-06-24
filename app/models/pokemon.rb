# The original 151 Pokémon, seeded as reference data (db/seeds/56_pokemon.rb,
# from the committed db/seeds/data/pokemon.json that `rake pokemon:fetch` writes).
# Carries types + base stats so it's reusable beyond its first job — the per-task
# mascot draw (Task#assign_mascot stamps metadata.devops.mascot). No behavior is
# attached to a Pokémon: it is pure identity/reference data.
class Pokemon < ApplicationRecord
  GEN1_RANGE = (1..151).freeze

  # The shared Studio::Enumeral category holding each type's display attributes —
  # color, emoji (in metadata), and commonality rank (seeded in
  # db/seeds/57_pokemon_type_colors.rb). Kept here so the "pokemon_type" key lives
  # with the model that owns types, not scattered across the controller and view.
  TYPE_ENUMERAL_CATEGORY = "pokemon_type".freeze

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

  # { type_key => Studio::Enumeral } for every seeded type, in ONE query — build
  # it once per page and look up each badge's color + emoji with no extra queries
  # (avoids an N+1 over the 151 rows). Empty when the enumeral table/gem isn't
  # installed yet, so badges fall back to the neutral chip.
  def self.type_enumerals
    Studio::Enumeral.catalog(TYPE_ENUMERAL_CATEGORY).index_by(&:key)
  end

  # { type_key => hex color } for every seeded type — the color-only convenience
  # over .type_enumerals.
  def self.type_colors
    Studio::Enumeral.color_map(TYPE_ENUMERAL_CATEGORY)
  end

  # The hex color for one of this Pokémon's types, or nil — convenience for a
  # one-off lookup. The index page uses .type_enumerals instead so it queries
  # once, not once per badge.
  def type_color(type)
    Studio::Enumeral.color_for(TYPE_ENUMERAL_CATEGORY, type)
  end

  # Among this Pokémon's types, the enumeral of its LEAST common one — the type
  # with the highest commonality rank (rank counts up as a type gets rarer). This
  # is the type that best identifies the Pokémon, so a dual-type wears the rarer
  # side: Dragonite (dragon/flying) → dragon, not flying. Pass a prebuilt
  # {key => Enumeral} map (Pokemon.type_enumerals) to rank many Pokémon without a
  # query each; falls back to one query for a single Pokémon. Nil when no type is
  # seeded.
  def signature_enumeral(by_key = nil)
    by_key ||= self.class.type_enumerals
    types.filter_map { |type| by_key[type] }.max_by { |enumeral| enumeral.rank || -1 }
  end

  # The least-common type key (e.g. "dragon" for Dragonite); the first listed type
  # when none is seeded.
  def signature_type(by_key = nil)
    signature_enumeral(by_key)&.key || types.first
  end

  # The color that represents this Pokémon — its least-common type's color. Nil
  # when no type is seeded, so callers fall back to their own default.
  def signature_color(by_key = nil)
    signature_enumeral(by_key)&.color
  end

  def to_param
    slug
  end
end
