require "test_helper"

class PokemonTest < ActiveSupport::TestCase
  def make(dex, slug, generation: 1)
    Pokemon.create!(dex: dex, name: slug.capitalize, slug: slug, generation: generation)
  end

  # A full three-stage line rooted at Charmander (base → evolves → evolves again).
  def three_stage_line!
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander",
                    base: "charmander", evolution: ["charmeleon"])
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon",
                    base: "charmander", evolution: ["charizard"])
    Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", base: "charmander")
  end

  # A two-stage line rooted at Diglett (base evolves once, then stops).
  def two_stage_line!
    Pokemon.create!(dex: 50, name: "Diglett", slug: "diglett",
                    base: "diglett", evolution: ["dugtrio"])
    Pokemon.create!(dex: 51, name: "Dugtrio", slug: "dugtrio", base: "diglett")
  end

  # --- Validations ---

  test "requires dex, name, and slug" do
    assert Pokemon.new(dex: 1, name: "Bulbasaur", slug: "bulbasaur").valid?
    assert_not Pokemon.new(name: "X", slug: "x").valid?
    assert_not Pokemon.new(dex: 1, slug: "x").valid?
    assert_not Pokemon.new(dex: 1, name: "X").valid?
  end

  # slug is the identity; dex may repeat, because the nidoran gender-family row
  # shares dex 29 with the Nidoran♀ species row it wears.
  test "slug is unique and dex may repeat" do
    make(1, "bulbasaur")
    assert Pokemon.new(dex: 1, name: "Family", slug: "bulbasaur-family").valid?
    assert_not Pokemon.new(dex: 2, name: "Dupe", slug: "bulbasaur").valid?
  end

  test "to_param is the slug" do
    assert_equal "snorlax", make(143, "snorlax").to_param
  end

  # --- Deck / draw ---

  test "deck spans both generations' base forms" do
    g1 = make(143, "snorlax", generation: 1)
    g2 = make(152, "chikorita", generation: 2)
    assert_equal [g1.id, g2.id].sort, Pokemon.deck.pluck(:id).sort
  end

  test "deck excludes evolved forms — only each family's base spawns" do
    charmander = Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander",
                                 base: "charmander", evolution: ["charmeleon"])
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon",
                    base: "charmander", evolution: ["charizard"])
    Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", base: "charmander")

    assert_equal [charmander.id], Pokemon.deck.pluck(:id)
  end

  test "deck excludes a self-based baby via its baby list (defensive guard)" do
    # No live Gen 1–4 form is a self-based baby after Togepi/Tyrogue were
    # reclassified as ordinary bases, but the guard stays for a future branching
    # baby (base == slug yet on a baby list). Synthetic family: a baby root whose
    # branch carries it, so the union of baby lists keeps the root out.
    branch = Pokemon.create!(dex: 901, name: "Branchmon", slug: "branchmon",
                             baby: ["rootmon"])
    Pokemon.create!(dex: 902, name: "Rootmon", slug: "rootmon",
                    evolution: %w[branchmon])
    # Rootmon is self-based (no single heir to hand the crown to)…
    assert Pokemon.find_by!(slug: "rootmon").base_form?
    # …but its baby list keeps it out of the spawn pool.
    assert_equal [branch.id], Pokemon.deck.pluck(:id)
  end

  test "deck excludes a baby based on its family base (the Cleffa case)" do
    clefairy = Pokemon.create!(dex: 35, name: "Clefairy", slug: "clefairy",
                               evolution: ["clefable"], baby: ["cleffa"])
    Pokemon.create!(dex: 173, name: "Cleffa", slug: "cleffa",
                    base: "clefairy", evolution: ["clefairy"])

    assert_equal [clefairy.id], Pokemon.deck.pluck(:id)
  end

  test "a Pokémon with no seeded family is its own base" do
    assert make(143, "snorlax").base_form?
    assert_equal "snorlax", Pokemon.find_by!(slug: "snorlax").base
  end

  test "draw_from_slugs reaches evolved forms outside the deck" do
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon", base: "charmander")
    assert_equal "charmeleon", Pokemon.draw_from_slugs(%w[charmeleon]).slug
  end

  test "draw returns a Pokemon from the deck" do
    make(143, "snorlax")
    assert_equal "snorlax", Pokemon.draw.slug
  end

  test "draw skips excluded slugs" do
    make(1, "bulbasaur")
    make(143, "snorlax")
    100.times { assert_equal "snorlax", Pokemon.draw(exclude: ["bulbasaur"]).slug }
  end

  test "draw falls back to the full deck when every Pokemon is taken" do
    snorlax = make(143, "snorlax")
    assert_equal snorlax, Pokemon.draw(exclude: ["snorlax"])
  end

  test "draw returns nil when the deck is empty" do
    assert_nil Pokemon.draw
  end

  # --- Three-stage draw weighting ---

  test "three_stage_base_slugs picks only the fully-evolving roots" do
    three_stage_line!    # charmander → charmeleon → charizard
    two_stage_line!      # diglett → dugtrio
    make(143, "snorlax") # single-stage

    assert_equal ["charmander"], Pokemon.three_stage_base_slugs
  end

  test "three_stage_base_slugs is the base root, not the mid-stage that also evolves" do
    three_stage_line!
    # Charmeleon evolves too, but it is not a base form (base != slug), so it is
    # never a spawn root — only Charmander is.
    slugs = Pokemon.three_stage_base_slugs
    assert_includes slugs, "charmander"
    assert_not_includes slugs, "charmeleon"
  end

  test "draw_bag enters three-stage lines twice and shorter lines once" do
    three_stage_line!    # 3-stage
    two_stage_line!      # 2-stage
    make(143, "snorlax") # single-stage

    counts = Pokemon.draw_bag.map(&:slug).tally
    assert_equal Pokemon::THREE_STAGE_DRAW_WEIGHT, counts["charmander"]
    assert_equal 1, counts["diglett"]
    assert_equal 1, counts["snorlax"]
    # deck is 3 bases; the three-stage one is doubled → 4 draw slots.
    assert_equal 4, Pokemon.draw_bag.size
  end

  test "draw_bag honours exclude and keeps weighting on the full-deck fallback" do
    three_stage_line!
    make(143, "snorlax")

    # Snorlax excluded → only the doubled Charmander remains.
    assert_equal %w[charmander charmander], Pokemon.draw_bag(exclude: ["snorlax"]).map(&:slug)
    # Everything excluded → fall back to the whole deck, still weighted.
    assert_equal 3, Pokemon.draw_bag(exclude: Pokemon.deck.pluck(:slug)).size # charmander×2 + snorlax
  end

  test "draw only ever returns a deck member from the weighted bag" do
    three_stage_line!
    make(143, "snorlax")
    deck = Pokemon.deck.pluck(:slug).to_set
    50.times { assert_includes deck, Pokemon.draw.slug }
  end

  test "the seeded deck weights the 49 three-stage roots into the draw bag" do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }

    # Three-stage roots are a fixed 49 across Gen 1–4 — independent of the spawn
    # base count, which siblings legitimately move. It was 24 over Gen 1–2 until
    # pokemon-mascot-gender folded Nidoran♀ and Nidoran♂ into the ONE drawable
    # nidoran family (23); pokemon-gen-3-and-4 added 21 Hoenn–Sinnoh roots and
    # gave five Gen 1–2 roots a Gen 4 third stage (Magnezone, Rhyperior,
    # Porygon-Z, Togekiss, Mamoswine).
    assert_equal 49, Pokemon.three_stage_base_slugs.size
    assert_includes Pokemon.three_stage_base_slugs, "nidoran"
    # Derive the expected bag from the deck rather than hardcode a base count: every
    # base is one slot, and each of the 49 three-stage roots adds one more
    # (246 + 49 = 295).
    assert_equal Pokemon.deck.count + 49, Pokemon.draw_bag.size

    deep = Pokemon.three_stage_base_slugs.to_set
    assert_includes deep, "charmander"  # charmander → charmeleon → charizard
    assert_includes deep, "dratini"     # dratini → dragonair → dragonite
    assert_includes deep, "magnemite"   # magneton → magnezone (Gen 4) makes it three-stage
    assert_includes deep, "togepi"      # togetic → togekiss (Gen 4); NOT_BABY keeps togepi the root
    assert_includes deep, "ralts"       # kirlia → gardevoir / gallade
    assert_includes deep, "gible"       # a Sinnoh root
    assert_not_includes deep, "diglett" # diglett → dugtrio (two-stage)
    assert_not_includes deep, "snorlax" # single-stage (Munchlax is its baby, not a stage)
    assert_not_includes deep, "electabuzz" # elekid is a baby; electabuzz → electivire is two stages
    assert_not_includes deep, "eevee"   # branches, but every branch is terminal
  end

  # --- Committed data file (db/seeds/data/pokemon.json) ---

  test "data file carries all 493 Gen 1-4 rows with complete image URL sets" do
    all_rows = JSON.parse(File.read(Rails.root.join("db/seeds/data/pokemon.json")))
    # The one gender-family row (nidoran) rides beside the 493 species and wears
    # Nidoran♀'s dex and art; the male art comes through its gender_forms.
    families, rows = all_rows.partition { |r| r["gender_forms"].present? }
    assert_equal ["nidoran"], families.map { |r| r["slug"] }
    nidoran = families.first
    assert_equal 29, nidoran["dex"]
    assert_equal({ "female" => "nidoran-f", "male" => "nidoran-m" }, nidoran["gender_forms"])
    assert nidoran["avatar_url"].end_with?("/29-nidoran-f-cropped.png")

    assert_equal (1..493).to_a, rows.map { |r| r["dex"] }
    assert_equal 493, rows.map { |r| r["slug"] }.uniq.size
    ranges = { 1 => Pokemon::GEN1_RANGE, 2 => Pokemon::GEN2_RANGE, 3 => Pokemon::GEN3_RANGE, 4 => Pokemon::GEN4_RANGE }
    assert(rows.all? { |r| ranges.fetch(r["generation"]).cover?(r["dex"]) })

    # Every row carries the six dex-slug-keyed image URLs (normal + shiny,
    # cropped primary + uncropped fallback + pixel sprite). All six were live in
    # S3 for every Gen 3–4 row when pokemon-gen-3-and-4 ran prune_missing_art
    # (1,550 URLs, none blanked); a species whose art is missing upstream would
    # carry nil here and wear the model's fallback instead.
    rows.each do |r|
      key = "#{r['dex']}-#{r['slug']}"
      assert r["avatar_url"].end_with?("/#{key}-cropped.png"), "##{r['dex']} avatar_url"
      assert r["avatar_fallback_url"].end_with?("/#{key}.png"), "##{r['dex']} avatar_fallback_url"
      assert r["sprite_url"].end_with?("/#{key}-sprite.png"), "##{r['dex']} sprite_url"
      assert r["shiny_avatar_url"].end_with?("/#{key}-shiny-cropped.png"), "##{r['dex']} shiny_avatar_url"
      assert r["shiny_avatar_fallback_url"].end_with?("/#{key}-shiny.png"), "##{r['dex']} shiny_avatar_fallback_url"
      assert r["shiny_sprite_url"].end_with?("/#{key}-shiny-sprite.png"), "##{r['dex']} shiny_sprite_url"
      assert r["types"].present? && r["hp"].present?, "##{r['dex']} types/stats"
    end
  end

  test "data file family fields match the operator's evolution model" do
    rows = JSON.parse(File.read(Rails.root.join("db/seeds/data/pokemon.json")))
    by = rows.index_by { |r| r["slug"] }

    assert(rows.all? { |r| r["base"].present? && r["evolution"].is_a?(Array) && r["baby"].is_a?(Array) })

    # A three-stage line points down to its base; the middle form knows the next step.
    assert_equal "charmander", by["charizard"]["base"]
    assert_equal ["charizard"], by["charmeleon"]["evolution"]
    # Single-stage forms are their own base with nowhere to go.
    assert_equal "snorlax", by["snorlax"]["base"]
    assert_empty by["snorlax"]["evolution"]
    # Babies point at the family base; the base carries them.
    assert_equal "clefairy", by["cleffa"]["base"]
    assert_equal ["cleffa"], by["clefairy"]["baby"]
    assert_equal "magmar", by["magby"]["base"]
    # Togepi/Tyrogue: reclassified as non-babies, so each roots its own family.
    # Togepi is its family's base (Togetic evolves from it); Tyrogue roots the
    # merged Hitmon family — the three Hitmons are its branch evolutions, no baby.
    assert_equal "togepi", by["togepi"]["base"]
    assert_equal ["togetic"], by["togepi"]["evolution"]
    assert_empty by["togetic"]["baby"]
    assert_equal "tyrogue", by["tyrogue"]["base"]
    assert_equal %w[hitmonchan hitmonlee hitmontop], by["tyrogue"]["evolution"].sort
    %w[hitmonlee hitmonchan hitmontop].each do |slug|
      assert_equal "tyrogue", by[slug]["base"]
      assert_empty by[slug]["baby"]
    end
    # Branching lines list every next step available within Gen 1–4.
    assert_equal %w[slowbro slowking], by["slowpoke"]["evolution"].sort
    assert_equal %w[bellossom vileplume], by["gloom"]["evolution"].sort
    assert_equal %w[politoed poliwrath], by["poliwhirl"]["evolution"].sort
    # Johto and Sinnoh retro-upgrades to older lines — derived from PokéAPI's
    # evolves_from_species, never typed by hand.
    assert_equal ["steelix"], by["onix"]["evolution"]
    assert_equal ["scizor"], by["scyther"]["evolution"]
    assert_equal ["crobat"], by["golbat"]["evolution"]
    assert_equal ["blissey"], by["chansey"]["evolution"]
    assert_equal ["kingdra"], by["seadra"]["evolution"]
    {
      "electabuzz" => ["electivire"], "magmar" => ["magmortar"], "rhydon" => ["rhyperior"],
      "magneton" => ["magnezone"], "togetic" => ["togekiss"], "sneasel" => ["weavile"],
      "piloswine" => ["mamoswine"], "tangela" => ["tangrowth"], "lickitung" => ["lickilicky"],
      "porygon2" => ["porygon-z"], "yanma" => ["yanmega"], "gligar" => ["gliscor"],
      "murkrow" => ["honchkrow"], "misdreavus" => ["mismagius"], "aipom" => ["ambipom"],
      "roselia" => ["roserade"]
    }.each { |from, into| assert_equal into, by[from]["evolution"], from }
    assert_equal %w[espeon flareon glaceon jolteon leafeon umbreon vaporeon], by["eevee"]["evolution"].sort
    assert_equal "electabuzz", by["electivire"]["base"]
    assert_equal "togepi", by["togekiss"]["base"]

    # Every baby sits on its heir's baby list: Gen 3–4 babies join older bases
    # (Azurill on Marill, Munchlax on Snorlax) and Budew roots on Roselia.
    babies = rows.flat_map { |r| r["baby"] }.uniq.sort
    assert_equal %w[azurill bonsly budew chingling cleffa elekid happiny igglybuff magby mantyke
                    mime-jr munchlax pichu riolu smoochum wynaut], babies
    assert_equal ["azurill"], by["marill"]["baby"]
    assert_equal ["munchlax"], by["snorlax"]["baby"]
    assert_equal ["happiny"], by["chansey"]["baby"]
    assert_equal ["budew"], by["roselia"]["baby"]
    assert_equal "roselia", by["roserade"]["base"]
    assert_equal "lucario", by["riolu"]["base"]

    # The gender-gated Gen 3–4 branches, as PokéAPI's evolution chains gate them.
    assert_equal({ "gallade" => "male" }, by["kirlia"]["evolution_genders"])
    assert_equal %w[gallade gardevoir], by["kirlia"]["evolution"].sort
    assert_equal({ "froslass" => "female" }, by["snorunt"]["evolution_genders"])
    assert_equal({ "wormadam" => "female", "mothim" => "male" }, by["burmy"]["evolution_genders"])
    assert_equal({ "vespiquen" => "female" }, by["combee"]["evolution_genders"])

    # Nidoran is one family: both lines root on it, the gate branch is per gender,
    # and the two species rows keep their own lines for old tasks.
    assert_equal "nidoran", by["nidoqueen"]["base"]
    assert_equal "nidoran", by["nidorino"]["base"]
    assert_equal({ "nidorina" => "female", "nidorino" => "male" }, by["nidoran"]["evolution_genders"])
    assert_equal ["nidorina"], by["nidoran-f"]["evolution"]
    assert_equal 8, by["nidorina"]["gender_rate"]
    assert_equal(-1, by["magnemite"]["gender_rate"])

    # 23 Gen 1 + 22 Gen 2 + 18 Gen 3 + 31 Gen 4 species have a distinct female sprite.
    differs = rows.select { |r| r["has_gender_differences"] }
    assert_equal({ 1 => 23, 2 => 22, 3 => 18, 4 => 31 }, differs.map { |r| r["generation"] }.tally)
    differs.each do |r|
      key = "#{r['dex']}-#{r['slug']}"
      assert r["female_sprite_url"].end_with?("/#{key}-female-sprite.png"), "##{r['dex']} female_sprite_url"
      assert r["shiny_female_sprite_url"].end_with?("/#{key}-shiny-female-sprite.png"), "##{r['dex']} shiny female"
    end

    forms = rows.flat_map { |r| Array(r["gender_forms"]&.values) } + %w[nidoran-f nidoran-m]
    spawnable = rows.select { |r| r["base"] == r["slug"] && !babies.include?(r["slug"]) && !forms.include?(r["slug"]) }
    assert_equal 246, spawnable.size
  end

  # --- Seed (idempotency from the committed JSON) ---

  test "seed loads the 493 and is idempotent and self-syncing" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s

    # 493 species plus the nidoran gender-family row.
    assert_difference -> { Pokemon.count }, 494 do
      capture_io { load seed }
    end

    assert_no_difference -> { Pokemon.count } do
      capture_io { load seed }
    end

    snorlax = Pokemon.find_by!(slug: "snorlax")
    assert_equal 160, snorlax.hp
    snorlax.update!(hp: 1)
    capture_io { load seed }
    assert_equal 160, snorlax.reload.hp
  end

  # --- Avatars (cropped primary + uncropped fallback) ---

  test "carries a separate cropped primary and uncropped fallback avatar" do
    p = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax",
                        avatar_url: "https://s3/pokemon/143-snorlax-cropped.png",
                        avatar_fallback_url: "https://s3/pokemon/143-snorlax.png",
                        sprite_url: "https://s3/pokemon/143-snorlax-sprite.png")
    p.reload
    assert_equal "https://s3/pokemon/143-snorlax-cropped.png", p.avatar_url
    assert_equal "https://s3/pokemon/143-snorlax.png", p.avatar_fallback_url
  end

  test "display_avatar prefers the cropped primary" do
    p = make(143, "snorlax")
    p.update!(avatar_url: "cropped.png", avatar_fallback_url: "orig.png", sprite_url: "sprite.png")
    assert_equal "cropped.png", p.display_avatar
  end

  test "display_avatar falls back to the uncropped original, then the sprite" do
    p = make(143, "snorlax")
    p.update!(avatar_url: nil, avatar_fallback_url: "orig.png", sprite_url: "sprite.png")
    assert_equal "orig.png", p.display_avatar

    p.update!(avatar_fallback_url: nil)
    assert_equal "sprite.png", p.display_avatar
  end

  test "seed carries the family columns and shapes the 246-base deck" do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }

    charizard = Pokemon.find_by!(slug: "charizard")
    assert_equal "charmander", charizard.base
    assert_empty charizard.evolution

    deck = Pokemon.deck.pluck(:slug)
    assert_equal 246, deck.size
    assert_includes deck, "nidoran"       # the one Nidoran family…
    assert_not_includes deck, "nidoran-f" # …never its legacy species rows
    assert_not_includes deck, "nidoran-m"
    assert_includes deck, "totodile"
    assert_includes deck, "snorlax"
    assert_includes deck, "togepi"        # reclassified base (Togetic is its evolution)
    assert_not_includes deck, "togetic"   # now Togepi's evolution
    assert_includes deck, "tyrogue"       # reclassified base of the merged Hitmon family
    assert_not_includes deck, "hitmonlee" # now a Tyrogue branch evolution
    assert_not_includes deck, "charizard" # evolved form
    assert_not_includes deck, "cleffa"    # baby
    # Gen 3–4 babies never spawn; their heir does.
    %w[munchlax happiny mime-jr bonsly mantyke budew chingling azurill wynaut riolu].each do |baby|
      assert_not_includes deck, baby
    end
    assert_includes deck, "lucario"       # Riolu's heir roots the line
    assert_includes deck, "treecko"
    assert_includes deck, "burmy"
    assert_not_includes deck, "electivire" # Gen 4 extension of the Electabuzz line
    assert_not_includes deck, "gallade"
  end

  test "seed splits the generations at the Kanto/Johto/Hoenn/Sinnoh boundaries" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s
    capture_io { load seed }

    assert_equal 151, Pokemon.species.gen1.count
    assert_equal 100, Pokemon.species.gen2.count
    assert_equal({ 1 => 151, 2 => 100, 3 => 135, 4 => 107 }, Pokemon.species.group(:generation).count)
    assert_equal (1..493).to_a, Pokemon.species.by_dex.pluck(:dex)

    chikorita = Pokemon.find_by!(slug: "chikorita")
    assert_equal 152, chikorita.dex
    assert_equal 2, chikorita.generation

    # Display-name special case new with Johto (title-casing would give "Ho Oh").
    assert_equal "Ho-Oh", Pokemon.find_by!(dex: 250).name
    assert_equal "Porygon2", Pokemon.find_by!(dex: 233).name
    # …and with Sinnoh.
    assert_equal "Mime Jr.", Pokemon.find_by!(dex: 439).name
    assert_equal "Porygon-Z", Pokemon.find_by!(dex: 474).name
    # Gen 4's named default forms seed under their species slug.
    assert_equal %w[deoxys giratina shaymin wormadam], Pokemon.where(dex: [386, 413, 487, 492]).order(:slug).pluck(:slug)
  end

  test "seed populates both a cropped avatar_url and an uncropped fallback for all 493" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s
    capture_io { load seed }

    pokemon = Pokemon.species.order(:dex).to_a
    assert_equal 493, pokemon.size
    pokemon.each do |p|
      assert p.avatar_url.present?, "##{p.dex} #{p.slug} missing avatar_url"
      assert p.avatar_fallback_url.present?, "##{p.dex} #{p.slug} missing avatar_fallback_url"
      # Primary is the crop; fallback is the original it was cropped from.
      assert p.avatar_url.end_with?("-cropped.png"), "##{p.dex} avatar_url not the crop: #{p.avatar_url}"
      assert_not p.avatar_fallback_url.end_with?("-cropped.png"), "##{p.dex} fallback should be the original"
      assert_equal p.avatar_url.sub("-cropped.png", ".png"), p.avatar_fallback_url
    end
  end

  # --- Type colors (shared Studio::Enumeral) ---

  test "type_colors maps each seeded type to its color in one query" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire",  color: "#EE8130", position: 0)
    Studio::Enumeral.create!(category: "pokemon_type", key: "water", color: "#6390F0", position: 1)
    assert_equal({ "fire" => "#EE8130", "water" => "#6390F0" }, Pokemon.type_colors)
  end

  test "type_enumerals returns the enumeral records keyed by type" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire", color: "#EE8130",
                             metadata: { "emoji" => "🔥" })
    enumerals = Pokemon.type_enumerals
    assert_equal "#EE8130", enumerals["fire"].color
    assert_equal "🔥", enumerals["fire"].emoji
    assert_nil enumerals["ghost"]
  end

  test "signature picks the least common (highest rank) type" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "dragon", color: "#6F35FC", rank: 1500)
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", color: "#A98FF3", rank: 400)
    dragonite = Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", types: %w[dragon flying])
    # Dragon is rarer than Flying, so Dragonite wears Dragon.
    assert_equal "dragon",  dragonite.signature_type
    assert_equal "#6F35FC", dragonite.signature_color
  end

  test "signature falls back to the first type / nil color when unseeded" do
    bulbasaur = Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", types: %w[grass poison])
    assert_nil bulbasaur.signature_color
    assert_equal "grass", bulbasaur.signature_type
  end

  test "signature recovers types from seed data for sparse rows" do
    capture_io { load Rails.root.join("db/seeds/57_pokemon_type_colors.rb").to_s }
    lugia = Pokemon.create!(dex: 249, name: "Lugia", slug: "lugia", types: [])

    assert_equal %w[psychic flying], lugia.type_keys
    assert_equal "psychic", lugia.signature_type
    assert_equal "#F95587", lugia.signature_color
    assert_equal "👁️💨", lugia.type_emoji
  end

  test "type_color returns the color for a type, or nil" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire", color: "#EE8130")
    charizard = make(6, "charizard")
    assert_equal "#EE8130", charizard.type_color("fire")
    assert_nil charizard.type_color("ghost")
  end

  test "type_emoji concatenates the types' emojis in type order" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire",   metadata: { "emoji" => "🔥" })
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", metadata: { "emoji" => "💨" })
    charizard = Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", types: %w[fire flying])
    assert_equal "🔥💨", charizard.type_emoji
    # an unseeded type contributes nothing (blank, not a crash)
    assert_equal "", Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", types: %w[grass]).type_emoji
  end

  test "type color seed loads the 18 canonical types idempotently" do
    seed = Rails.root.join("db/seeds/57_pokemon_type_colors.rb").to_s

    assert_difference -> { Studio::Enumeral.in_category("pokemon_type").count }, 18 do
      capture_io { load seed }
    end
    assert_no_difference -> { Studio::Enumeral.in_category("pokemon_type").count } do
      capture_io { load seed }
    end

    assert_equal "#EE8130", Studio::Enumeral.color_for("pokemon_type", "fire")
  end

  test "type color seed ranks types by commonality in steps of 100" do
    seed = Rails.root.join("db/seeds/57_pokemon_type_colors.rb").to_s
    capture_io { load seed }

    # water is the most common type across Gen 1–4 (92 of 493); normal second (72),
    # flying third (64).
    assert_equal 100, Studio::Enumeral.lookup("pokemon_type", "water").rank
    assert_equal 200, Studio::Enumeral.lookup("pokemon_type", "normal").rank
    assert_equal 300, Studio::Enumeral.lookup("pokemon_type", "flying").rank
    # fighting and steel tie at 25; the canonical type order breaks the tie.
    assert_equal 1200, Studio::Enumeral.lookup("pokemon_type", "fighting").rank
    assert_equal 1300, Studio::Enumeral.lookup("pokemon_type", "steel").rank
    # ghost is the rarest across the 493 (18); dragon (19) next.
    assert_equal 1700, Studio::Enumeral.lookup("pokemon_type", "dragon").rank
    assert_equal 1800, Studio::Enumeral.lookup("pokemon_type", "ghost").rank

    # Every rank is a distinct multiple of 100, 100..1800.
    ranks = Studio::Enumeral.in_category("pokemon_type").pluck(:rank).sort
    assert_equal (1..18).map { |i| i * 100 }, ranks

    # Each type also carries its emoji (in metadata) — the operator's chosen set.
    assert_equal "🔥", Studio::Enumeral.lookup("pokemon_type", "fire").emoji
    assert_equal "🔶", Studio::Enumeral.lookup("pokemon_type", "normal").emoji
    assert_equal "👊", Studio::Enumeral.lookup("pokemon_type", "fighting").emoji
    assert_equal "🏔", Studio::Enumeral.lookup("pokemon_type", "ground").emoji
  end

  # --- Primary type cache (assign_primary_types!) ---

  test "assign_primary_types! caches each Pokémon's identifying (least-common) type" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "dragon",   color: "#6F35FC", rank: 1500)
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying",   color: "#A98FF3", rank: 400)
    Studio::Enumeral.create!(category: "pokemon_type", key: "electric", color: "#F7D02C", rank: 300)
    dragonite = Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", types: %w[dragon flying])
    electrode = Pokemon.create!(dex: 101, name: "Electrode", slug: "electrode", types: %w[electric])

    assert_equal 2, Pokemon.assign_primary_types!
    assert_equal "dragon",   dragonite.reload.primary_type # rarer of dragon/flying
    assert_equal "electric", electrode.reload.primary_type # single-type → itself
  end

  test "assign_primary_types! is idempotent — a second run writes nothing" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "dragon", color: "#6F35FC", rank: 1500)
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", color: "#A98FF3", rank: 400)
    Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", types: %w[dragon flying])

    assert_equal 1, Pokemon.assign_primary_types!
    assert_equal 0, Pokemon.assign_primary_types!
  end

  test "assign_primary_types! no-ops (returns 0) without seeded type ranks" do
    Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", types: %w[dragon flying])
    assert_equal 0, Pokemon.assign_primary_types!
    assert_nil Pokemon.find_by!(slug: "dragonite").primary_type
  end

  test "signature reads the cached primary_type over re-ranking" do
    # normal is the more common (lower rank) type; live ranking would pick flying.
    Studio::Enumeral.create!(category: "pokemon_type", key: "normal", color: "#A8A77A", rank: 100)
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", color: "#A98FF3", rank: 400)
    pidgeot = Pokemon.create!(dex: 18, name: "Pidgeot", slug: "pidgeot", types: %w[normal flying])

    # Force the cache to disagree with the live computation to prove it is read.
    pidgeot.update_column(:primary_type, "normal")
    assert_equal "normal",  pidgeot.signature_type
    assert_equal "#A8A77A", pidgeot.signature_color
    assert_equal "normal",  pidgeot.signature_enumeral.key

    # Clearing the cache falls back to the live least-common pick (flying).
    pidgeot.update_column(:primary_type, nil)
    assert_equal "flying",  pidgeot.signature_type
    assert_equal "#A98FF3", pidgeot.signature_color
  end

  test "primary type seed caches the identifying type for all 493" do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }
    capture_io { load Rails.root.join("db/seeds/57_pokemon_type_colors.rb").to_s }
    capture_io { load Rails.root.join("db/seeds/58_pokemon_primary_types.rb").to_s }

    pokemon = Pokemon.species.order(:dex).to_a
    assert_equal 493, pokemon.size
    assert pokemon.all? { |p| p.primary_type.present? }, "every Pokémon should have a cached primary_type"

    # Pidgeot is normal/flying; across Gen 1–4 normal (72) outnumbers flying (64),
    # so flying is the rarer side and identifies it — the cache must agree with the
    # live computation over the full 493. (Over Gen 1–2 it was the other way round:
    # adding generations re-ranks types, so some older Pokémon change color.)
    pidgeot = Pokemon.find_by!(slug: "pidgeot")
    assert_equal "flying", pidgeot.primary_type
    assert_equal Studio::Enumeral.color_for("pokemon_type", "flying"), pidgeot.signature_color

    # A Johto row ranks with the same machinery: Tyranitar (rock/dark) wears dark.
    tyranitar = Pokemon.find_by!(slug: "tyranitar")
    assert_equal 2, tyranitar.generation
    assert_equal "dark", tyranitar.primary_type

    # Re-running the cache (the seed's class method) changes nothing.
    assert_equal 0, Pokemon.assign_primary_types!
  end
end
