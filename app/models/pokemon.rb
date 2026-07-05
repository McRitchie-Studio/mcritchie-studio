# The Gen 1–2 Pokémon (dex 1–251), seeded as reference data (db/seeds/56_pokemon.rb,
# from the committed db/seeds/data/pokemon.json that `rake pokemon:fetch` writes).
# Carries types + base stats so it's reusable beyond its first job — the per-task
# mascot draw (Task#assign_mascot stamps metadata.devops.mascot). No behavior is
# attached to a Pokémon: it is pure identity/reference data.
class Pokemon < ApplicationRecord
  GEN1_RANGE = (1..151).freeze
  GEN2_RANGE = (152..251).freeze

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

  # A Pokémon with no seeded family is its own base (a single-stage form), so
  # ad-hoc rows are spawnable without ceremony. Babies and evolved forms get
  # their real base from the seed data.
  before_validation { self.base = slug if base.blank? }

  scope :by_dex, -> { order(:dex) }
  scope :gen1, -> { where(generation: 1) }
  scope :gen2, -> { where(generation: 2) }

  # Every baby form's slug — babies live on their base's `baby` list (pikachu
  # carries ["pichu"]), so the set is the union of those lists.
  def self.baby_slugs
    where.not(baby: []).pluck(:baby).flatten.uniq
  end

  # The spawnable roots: each family's base form, minus baby forms (reference
  # data only — they never spawn). The baby-list exclusion guards a self-based
  # baby (base == slug yet on a baby list); no Gen 1–2 form is one today — Togepi
  # and Tyrogue are reclassified as ordinary bases (lib/tasks/pokemon.rake
  # NOT_BABY) — but the guard stays for any future branching baby with no heir.
  def self.spawnable
    where(arel_table[:base].eq(arel_table[:slug])).where.not(slug: baby_slugs)
  end

  # The deck the mascot draw pulls from — every Gen 1–2 base form. Sessions and
  # tasks spawn at the bottom of an evolutionary line; the task's copy of the
  # mascot can then evolve at pipeline gates (tasks/task-mascot-evolution-gates).
  def self.deck
    spawnable
  end

  # Draw one random Pokémon for a mascot, skipping any slug in `exclude` (the
  # mascots already held by live tasks). Deck-draw without replacement; if every
  # base form is somehow taken it falls back to the full deck rather than
  # returning nil, so a task always gets a face.
  def self.draw(exclude: [])
    taken = Array(exclude).compact_blank
    pool = deck.where.not(slug: taken)
    pool = deck unless pool.exists?
    pool.order(Arel.sql("RANDOM()")).first
  end

  # Draw from a caller-curated slug pool (e.g. a parent session's evolution
  # family). Deliberately NOT restricted to the deck: evolved forms aren't
  # spawnable roots, but a subagent drawing from its parent's family may wear one.
  def self.draw_from_slugs(slugs, exclude: [])
    candidates = Array(slugs).compact_blank
    return nil if candidates.empty?

    available = candidates - Array(exclude).compact_blank
    available = candidates if available.empty?
    where(slug: available).order(Arel.sql("RANDOM()")).first
  end

  def self.evolution_tree_for(slug)
    PokemonEvolutionTree.for(slug)
  end

  # Is this form the bottom of its evolutionary line?
  def base_form?
    base == slug
  end

  # The rows this form can evolve into next (Eevee has five; Snorlax none).
  def evolutions
    self.class.where(slug: Array(evolution))
  end

  # True when this form can evolve once, then that evolved form can evolve again.
  # Babies do not count as a prior form here: Pikachu has Pichu as a baby, but only
  # one forward evolution (Raichu), so this returns false for Pikachu.
  def second_evolution_form?
    evolutions.any? { |pokemon| Array(pokemon.evolution).present? }
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

  # The RAW primary type — this Pokémon's LEAST common one, the type with the
  # highest commonality rank (rank counts up as a type gets rarer). This is the
  # type that best identifies the Pokémon, so a dual-type wears the rarer side:
  # Dragonite (dragon/flying) → dragon, not flying. Computed live from the seeded
  # ranks (ignores the primary_type cache); the first listed type when none is
  # seeded. This is the source of truth .assign_primary_types! persists; the reader
  # methods below prefer that cache. Pass a prebuilt {key => Enumeral} map
  # (Pokemon.type_enumerals) to rank many Pokémon without a query each.
  def computed_primary_type(by_key = nil)
    by_key ||= self.class.type_enumerals
    types.filter_map { |type| by_key[type] }.max_by { |enumeral| enumeral.rank || -1 }&.key ||
      types.first
  end

  # Compute and CACHE every Pokémon's primary_type (its identifying least-common
  # type) onto the column, so color lookups read a value instead of re-ranking on
  # each call. Idempotent and re-runnable: call it again after adding Pokémon (or
  # changing the type ranks) to refresh the cache — only rows whose value actually
  # changes are written. Requires the pokemon_type enumerals (ranks) to be seeded;
  # without them every Pokémon would fall back to its first-listed type, so it
  # no-ops (returns 0) when the enumeral table is empty. Returns the rows updated.
  def self.assign_primary_types!
    by_key = type_enumerals
    return 0 if by_key.empty?

    updated = 0
    find_each do |pokemon|
      key = pokemon.computed_primary_type(by_key)
      next if key.blank? || pokemon.primary_type == key

      pokemon.update_column(:primary_type, key)
      updated += 1
    end
    updated
  end

  # The enumeral representing this Pokémon — its primary (identifying) type's
  # enumeral, the one its color + emoji come from. Reads the cached primary_type
  # when present (a single lookup, no ranking); falls back to the live least-common
  # computation for rows not yet backfilled. Pass Pokemon.type_enumerals to avoid a
  # query per Pokémon. Nil when the primary type has no seeded enumeral.
  def signature_enumeral(by_key = nil)
    by_key ||= self.class.type_enumerals
    by_key[primary_type.presence || computed_primary_type(by_key)]
  end

  # The least-common ("identifying") type key — the cached primary_type, or the
  # live computation when not yet backfilled.
  def signature_type(by_key = nil)
    primary_type.presence || computed_primary_type(by_key)
  end

  # The color that represents this Pokémon — its primary type's color. Nil when
  # that type has no seeded enumeral, so callers fall back to their own default.
  def signature_color(by_key = nil)
    signature_enumeral(by_key)&.color
  end

  # This Pokémon's type emoji(s) — each of its types' enumeral emoji, in type
  # order, concatenated (1-2): Dugtrio → "🏔", Charizard → "🔥💨". "" when no type
  # is seeded. bin/statusline shows this in place of the 🛠 ⊙ glyphs.
  def type_emoji(by_key = nil)
    by_key ||= self.class.type_enumerals
    types.filter_map { |type| by_key[type]&.emoji }.join
  end

  # Shiny odds for ONE mascot draw — 1-in-N. Production runs the canonical
  # 1-in-100; dev and QA run 1-in-10 so shinies actually show up while working.
  # QA runs the production Rails env, so it's told apart by QA_ENV=true (set by
  # bin/qa-server on every QA app — same signal as ApplicationHelper#qa_environment?).
  # SHINY_ODDS overrides everything for tuning/demo ("SHINY_ODDS=1" = always shiny).
  # 0 (never) under test so every task-creating test stays deterministic — shiny
  # specs opt in by stubbing roll_shiny? (or setting SHINY_ODDS).
  def self.shiny_odds
    explicit = ENV["SHINY_ODDS"].to_i
    return explicit if explicit.positive?
    return 0 if Rails.env.test?

    qa = ENV["QA_ENV"].to_s.strip.downcase == "true"
    Rails.env.production? && !qa ? 100 : 10
  end

  # Roll ONE shiny check at the current odds. Called once per mascot draw — shiny
  # is a property of the DRAW (the session/task's mascot instance), never of the
  # Pokémon row itself.
  def self.roll_shiny?
    odds = shiny_odds
    odds.positive? && rand(odds).zero?
  end

  # The image to render for this Pokémon: the tightly-cropped primary
  # (avatar_url), falling back to the original uncropped artwork
  # (avatar_fallback_url) and finally the pixel sprite. Callers that want the
  # explicit backup read avatar_fallback_url directly (e.g. an <img onerror>).
  # A shiny draw prefers the shiny chain but still lands on the normal art when
  # the shiny mirror isn't provisioned — a shiny mascot never goes faceless.
  def display_avatar(shiny: false)
    (shiny ? shiny_display_avatar : nil) ||
      avatar_url.presence || avatar_fallback_url.presence || sprite_url
  end

  # The pixel sprite for small chips (board crew circles, heartbeat rows) —
  # shiny-aware with the same never-faceless fallback.
  def display_sprite(shiny: false)
    (shiny_sprite_url.presence if shiny) || sprite_url
  end

  def to_param
    slug
  end

  private

  def shiny_display_avatar
    shiny_avatar_url.presence || shiny_avatar_fallback_url.presence || shiny_sprite_url.presence
  end
end
