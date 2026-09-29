# The Gen 1–4 Pokémon (dex 1–493), seeded as reference data (db/seeds/56_pokemon.rb,
# from the committed db/seeds/data/pokemon.json that `rake pokemon:fetch` writes).
# Carries types + base stats so it's reusable beyond its first job — the per-task
# mascot draw (Task#assign_mascot stamps metadata.devops.mascot). No behavior is
# attached to a Pokémon: it is pure identity/reference data.
class Pokemon < ApplicationRecord
  GEN1_RANGE = (1..151).freeze
  GEN2_RANGE = (152..251).freeze
  GEN3_RANGE = (252..386).freeze
  GEN4_RANGE = (387..493).freeze

  # The shared Studio::Enumeral category holding each type's display attributes —
  # color, emoji (in metadata), and commonality rank (seeded in
  # db/seeds/57_pokemon_type_colors.rb). Kept here so the "pokemon_type" key lives
  # with the model that owns types, not scattered across the controller and view.
  TYPE_ENUMERAL_CATEGORY = "pokemon_type".freeze
  SHINY_EMOJI = "✨".freeze

  # How many times a three-stage line (base → evolves → evolves again) enters the
  # mascot draw bag relative to shorter lines. The fully-evolving roots
  # (Charmander, Dratini, Larvitar, Gible, …) felt too rare at flat one-in-the-deck odds,
  # so they draw at this multiple — every other base stays at weight 1. See .draw_bag.
  THREE_STAGE_DRAW_WEIGHT = 2

  # A mascot's gender, rolled once per session draw beside shiny (.roll_gender)
  # and adopted by its tasks as devops.mascot_gender. nil = genderless (Magnemite,
  # Staryu, the legendaries) or a legacy draw that predates the roll.
  GENDERS = %w[female male].freeze
  GENDER_SYMBOLS = { "female" => "♀", "male" => "♂" }.freeze
  # A genderless species is not a gender a draw records (GENDERS stays the
  # stored vocabulary); it is a DISPLAY value — the session marker carries it so
  # bin/statusline can show ⚥ rather than a bare pre-gender name.
  GENDERLESS = "genderless".freeze
  DISPLAY_SIGNS = GENDER_SYMBOLS.merge(GENDERLESS => "⚥").freeze
  # A display sign at the end of a name, with any space before it (Nidoran♀).
  TRAILING_SIGN = /\s*([#{DISPLAY_SIGNS.values.join}])\z/
  # PokéAPI's gender_rate is in EIGHTHS female: -1 genderless, 0 always male,
  # 8 always female, n in between = an n/8 chance of female.
  GENDER_RATE_EIGHTHS = 8
  GENDERLESS_RATE = -1

  # dex is NOT unique: a gender FAMILY row (nidoran) shares dex 29 with the
  # Nidoran♀ species row it wears. slug is the identity.
  validates :dex, presence: true,
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
  # The real species — every row but the gender FAMILY rows (nidoran), which are a
  # mascot-draw device over two species rows, not a species of their own. The
  # Pokédex and the reference index list these.
  scope :species, -> { where(gender_forms: {}) }

  # Every baby form's slug — babies live on their base's `baby` list (pikachu
  # carries ["pichu"]), so the set is the union of those lists.
  def self.baby_slugs
    where.not(baby: []).pluck(:baby).flatten.uniq
  end

  # The spawnable roots: each family's base form, minus baby forms (reference
  # data only — they never spawn). The baby-list exclusion guards a self-based
  # baby (base == slug yet on a baby list); no Gen 1–4 form is one today — Togepi
  # and Tyrogue are reclassified as ordinary bases (lib/tasks/pokemon.rake
  # NOT_BABY) — but the guard stays for any future branching baby with no heir.
  def self.spawnable
    where(arel_table[:base].eq(arel_table[:slug])).where.not(slug: baby_slugs)
  end

  # The deck the mascot draw pulls from — every Gen 1–4 base form. Sessions and
  # tasks spawn at the bottom of an evolutionary line; the task's copy of the
  # mascot can then evolve at pipeline gates (tasks/task-mascot-evolution-gates).
  #
  # A gender family's FORM rows (nidoran-f, nidoran-m) are left out: the family
  # row (nidoran) is what draws, and its rolled gender picks the form it wears.
  # The form rows stay seeded so old tasks and sessions still carrying them
  # resolve to a name and art.
  def self.deck
    spawnable.where.not(slug: gender_form_slugs)
  end

  # Every slug a gender family wears (nidoran-f, nidoran-m) — read off the data,
  # so a later family needs no code.
  def self.gender_form_slugs
    where.not(gender_forms: {}).pluck(:gender_forms).flat_map { |forms| Array(forms&.values) }.uniq
  end

  # The base slugs whose evolutionary line runs a full three stages — the base
  # evolves, and that evolution itself evolves again (the "2 evolutions off base"
  # roots; 49 across Gen 1–4). Two set-based queries, no N+1: `evolvers` is every
  # form that can evolve into something, and a base is three-stage exactly when one
  # of its own evolutions is itself an evolver. These draw at THREE_STAGE_DRAW_WEIGHT.
  # (The jsonb `where.not(evolution: [])` predicate over-selects, so empties are
  # dropped in Ruby — the same reason .baby_slugs flattens.)
  def self.three_stage_base_slugs
    evolvers = pluck(:slug, :evolution).filter_map { |slug, evolution| slug if Array(evolution).present? }.to_set
    deck.pluck(:slug, :evolution).filter_map do |slug, evolution|
      slug if Array(evolution).any? { |next_slug| evolvers.include?(next_slug) }
    end
  end

  # The weighted bag the mascot draw samples: the deck minus mascots already
  # `exclude`d (falling back to the whole deck when everything is spoken for), with
  # every three-stage line entered THREE_STAGE_DRAW_WEIGHT times so the
  # fully-evolving families surface that much more often. Over the seeded deck the
  # 49 three-stage roots are counted twice (246 bases → a 295-slot bag).
  def self.draw_bag(exclude: [])
    taken = Array(exclude).compact_blank
    pool = deck.where.not(slug: taken)
    pool = deck unless pool.exists?

    deep = three_stage_base_slugs.to_set
    pool.flat_map do |pokemon|
      deep.include?(pokemon.slug) ? Array.new(THREE_STAGE_DRAW_WEIGHT, pokemon) : [pokemon]
    end
  end

  # Draw one random Pokémon for a mascot, skipping any slug in `exclude` (the
  # mascots already held by live tasks). Deck-draw without replacement; if every
  # base form is somehow taken it falls back to the full deck rather than
  # returning nil, so a task always gets a face. Three-stage lines are weighted
  # (see .draw_bag / THREE_STAGE_DRAW_WEIGHT), so the draw is no longer uniform.
  def self.draw(exclude: [])
    draw_bag(exclude: exclude).sample
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

  def self.evolution_tree_for(slug, gender: nil)
    PokemonEvolutionTree.for(slug, gender: gender)
  end

  # Roll ONE gender for a draw, weighted by the species' gender_rate: nil for a
  # genderless (or unrecorded) species, the only gender for a forced one, else
  # female with an n/8 chance. Called once per mascot draw, like .roll_shiny? —
  # gender belongs to the DRAW (the session's mascot), never to the species row.
  def self.roll_gender(gender_rate)
    return nil if gender_rate.nil? || gender_rate.to_i <= GENDERLESS_RATE
    return "male" if gender_rate.to_i.zero?
    return "female" if gender_rate.to_i >= GENDER_RATE_EIGHTHS

    gender_die < gender_rate.to_i ? "female" : "male"
  end

  # One eight-sided die, 0..7 — female when it lands under the gender_rate. Under
  # test it always lands on 7, so a mixed species deterministically rolls male and
  # every task-creating test stays stable (the same idea as .shiny_odds being 0 in
  # test); a gender spec opts in by stubbing this. Forced and genderless species
  # never read it.
  def self.gender_die
    return GENDER_RATE_EIGHTHS - 1 if Rails.env.test?

    rand(GENDER_RATE_EIGHTHS)
  end

  # Canonical gender string, or nil for anything else ("", "unknown", junk).
  def self.normalize_gender(value)
    gender = value.to_s.strip.downcase
    GENDERS.include?(gender) ? gender : nil
  end

  # Is this form the bottom of its evolutionary line?
  def base_form?
    base == slug
  end

  # The rows this form can evolve into next (Eevee has five; Snorlax none).
  def evolutions
    self.class.where(slug: Array(evolution))
  end

  # The evolution slugs a mascot of `gender` may take: every branch whose
  # evolution_genders requirement is absent or matches. A nil gender (a legacy
  # draw from before the roll) is unconstrained, so an old task never loses a
  # branch it could always take. Nidoran: female → ["nidorina"], male → ["nidorino"].
  def evolution_for(gender)
    gender = self.class.normalize_gender(gender)
    requirements = evolution_genders || {}
    Array(evolution).select do |slug|
      required = requirements[slug].presence
      required.nil? || gender.nil? || required == gender
    end
  end

  # The rows a mascot of `gender` may evolve into next — the gates' pool.
  def evolutions_for(gender)
    self.class.where(slug: evolution_for(gender))
  end

  # This draw's own gender roll, from the species' gender_rate.
  def roll_gender
    self.class.roll_gender(gender_rate)
  end

  # Whether a draw of this species may carry `gender`: a genderless species only
  # nil, a forced species only its one gender, a mixed one either (and nil, for
  # a legacy draw). Used to inherit a parent session's gender safely.
  def allows_gender?(gender)
    gender = self.class.normalize_gender(gender)
    rate = gender_rate
    return gender.nil? if rate.nil? || rate.to_i <= GENDERLESS_RATE
    return gender.nil? || gender == "male" if rate.to_i.zero?
    return gender.nil? || gender == "female" if rate.to_i >= GENDER_RATE_EIGHTHS

    true
  end

  # A gender family's species row for `gender` (nidoran + female → Nidoran♀'s
  # row), or nil for an ordinary species or an unknown gender. Memoized per
  # gender — one query the first time a face renders.
  def gender_form(gender)
    gender = self.class.normalize_gender(gender)
    slug = gender && (gender_forms || {})[gender].presence
    return nil unless slug

    (@gender_forms_by_gender ||= {})[gender] ||= self.class.find_by(slug: slug)
  end

  # The name to show for a draw of this Pokémon — THE one rule every surface
  # shares (board, crew, release faces, activity feed, Pokédex; bin/statusline and
  # bin/agent-marker mirror it): a gendered draw wears its sign (Mawile♂,
  # Gardevoir♀); a GENDERLESS species (gender_rate -1: Magnemite, Staryu, the
  # legendaries) always wears ⚥; a species that has genders but whose draw
  # recorded none (a pre-gender task or session) stays bare. Genderless is read
  # off the species, never off a nil gender — nil means pre-gender too. A family
  # wears its form's name (Nidoran♀ / Nidoran♂), which already carries the sign,
  # so Nidoran never doubles it.
  def display_name(gender: nil)
    base = gender_form(gender)&.name.presence || name
    self.class.gendered_name(base, genderless? ? GENDERLESS : gender)
  end

  # A species PokéAPI records as having no gender (gender_rate -1). An
  # unrecorded rate (nil → 0) is not genderless — it is unknown.
  def genderless?
    gender_rate.to_i <= GENDERLESS_RATE
  end

  # The gender a DISPLAY surface carries for a draw: the recorded gender, else
  # "genderless" for a genderless species, else nil (pre-gender). What the
  # session marker's mascot_gender holds, so bin/statusline can tell ⚥ from bare.
  def display_gender(gender)
    genderless? ? GENDERLESS : self.class.normalize_gender(gender)
  end

  # Slugs of every genderless species — one query, for a surface that holds only
  # a baked name + slug (an event snapshot) and must still show ⚥.
  def self.genderless_slugs
    where(gender_rate: ..GENDERLESS_RATE).pluck(:slug).to_set
  end

  # `name`, a space, then the sign for `gender`: ♂ male, ♀ female, ⚥ "genderless"
  # (Mawile ♂). nil, blank or junk leaves it bare. A name that already ends in a
  # sign (the Nidoran♀ species name, or a snapshot baked before the space) keeps
  # its own sign and gains the space, so it is idempotent and never doubles.
  def self.gendered_name(name, gender)
    name = name.to_s
    return name if name.empty?
    return name.sub(TRAILING_SIGN, ' \\1') if name.match?(TRAILING_SIGN)

    sign = DISPLAY_SIGNS[gender.to_s.strip.downcase]
    sign ? "#{name} #{sign}" : name
  end

  # { type_key => Studio::Enumeral } for every seeded type, in ONE query — build
  # it once per page and look up each badge's color + emoji with no extra queries
  # (avoids an N+1 over the 493 rows). Empty when the enumeral table/gem isn't
  # installed yet, so badges fall back to the neutral chip.
  def self.type_enumerals
    Studio::Enumeral.catalog(TYPE_ENUMERAL_CATEGORY).index_by(&:key)
  end

  def self.seed_data_by_slug
    @seed_data_by_slug ||= begin
      path = Rails.root.join("db/seeds/data/pokemon.json")
      JSON.parse(path.read).index_by { |row| row["slug"].to_s }
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
  end

  def self.seed_data_for(slug)
    seed_data_by_slug[slug.to_s]
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

  # Prefer the row's JSON types, but recover from sparse legacy/demo rows by
  # reading the committed seed data for the same slug.
  def type_keys
    Array(types).presence || Array(self.class.seed_data_for(slug)&.fetch("types", []))
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
    keys = type_keys
    keys.filter_map { |type| by_key[type] }.max_by { |enumeral| enumeral.rank || -1 }&.key ||
      keys.first
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
    type_keys.filter_map { |type| by_key[type]&.emoji }.join
  end

  def status_emoji(shiny: false, by_key: nil)
    self.class.decorate_type_emoji(type_emoji(by_key), shiny: shiny)
  end

  def self.decorate_type_emoji(emoji, shiny:)
    raw = emoji.to_s.delete(SHINY_EMOJI)
    shiny ? "#{raw.presence}#{SHINY_EMOJI}" : raw.presence
  end

  # Shiny odds for ONE mascot draw — 1-in-N. Production runs 1-in-25; dev and QA
  # run 1-in-2 so shinies actually show up while working.
  # QA runs the production Rails env, so it's told apart by QA_ENV=true (set by
  # bin/qa-server on every QA app — same signal as Studio.qa_environment?).
  # SHINY_ODDS overrides everything for tuning/demo ("SHINY_ODDS=1" = always shiny).
  # 0 (never) under test so every task-creating test stays deterministic — shiny
  # specs opt in by stubbing roll_shiny? (or setting SHINY_ODDS).
  def self.shiny_odds
    explicit = ENV["SHINY_ODDS"].to_i
    return explicit if explicit.positive?
    return 0 if Rails.env.test?

    qa = ENV["QA_ENV"].to_s.strip.downcase == "true"
    Rails.env.production? && !qa ? 25 : 2
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
  #
  # Official artwork has no female variants, so gender only matters here for a
  # gender FAMILY, which wears its form's art (a male nidoran → the dex-32 art),
  # and on the last-resort sprite fallback (a female draw lands on her sprite).
  def display_avatar(shiny: false, gender: nil)
    if (form = gender_form(gender))
      return form.display_avatar(shiny: shiny)
    end

    (shiny ? shiny_display_avatar : nil) ||
      avatar_url.presence || avatar_fallback_url.presence || female_sprite(false, gender) || sprite_url
  end

  # The pixel sprite for small chips (board crew circles, heartbeat rows) —
  # shiny- AND gender-aware with the same never-faceless fallback. A female draw of
  # a species with a distinct female look wears the female sprite (shiny female →
  # shiny → normal; female → normal); a gender family wears its form's sprite.
  def display_sprite(shiny: false, gender: nil)
    if (form = gender_form(gender))
      return form.display_sprite(shiny: shiny)
    end

    female_sprite(shiny, gender) || (shiny_sprite_url.presence if shiny) || sprite_url
  end

  def to_param
    slug
  end

  private

  # The female sprite for a female draw, nil when this species has no distinct
  # female look (or the draw is not female) so the caller falls through.
  def female_sprite(shiny, gender)
    return nil unless has_gender_differences? && self.class.normalize_gender(gender) == "female"

    (shiny ? shiny_female_sprite_url : female_sprite_url).presence
  end

  def shiny_display_avatar
    shiny_avatar_url.presence || shiny_avatar_fallback_url.presence || shiny_sprite_url.presence
  end
end
