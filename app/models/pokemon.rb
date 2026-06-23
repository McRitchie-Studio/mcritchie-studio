# The original 151 Pokémon, seeded as reference data (db/seeds/56_pokemon.rb,
# from the committed db/seeds/data/pokemon.json that `rake pokemon:fetch` writes).
# Carries types + base stats so it's reusable beyond its first job — the per-task
# mascot draw (Task#assign_mascot stamps metadata.devops.mascot). No behavior is
# attached to a Pokémon: it is pure identity/reference data.
class Pokemon < ApplicationRecord
  GEN1_RANGE = (1..151).freeze

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

  def to_param
    slug
  end
end
