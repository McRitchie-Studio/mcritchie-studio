require "test_helper"

class PokemonTest < ActiveSupport::TestCase
  def make(dex, slug, generation: 1)
    Pokemon.create!(dex: dex, name: slug.capitalize, slug: slug, generation: generation)
  end

  # --- Validations ---

  test "requires dex, name, and slug" do
    assert Pokemon.new(dex: 1, name: "Bulbasaur", slug: "bulbasaur").valid?
    assert_not Pokemon.new(name: "X", slug: "x").valid?
    assert_not Pokemon.new(dex: 1, slug: "x").valid?
    assert_not Pokemon.new(dex: 1, name: "X").valid?
  end

  test "dex and slug are unique" do
    make(1, "bulbasaur")
    assert_not Pokemon.new(dex: 1, name: "Dupe", slug: "dupe").valid?
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

  test "deck excludes baby forms even when self-based (the Tyrogue case)" do
    hitmonlee = Pokemon.create!(dex: 106, name: "Hitmonlee", slug: "hitmonlee",
                                baby: ["tyrogue"])
    Pokemon.create!(dex: 236, name: "Tyrogue", slug: "tyrogue",
                    evolution: %w[hitmonlee hitmonchan hitmontop])
    # Tyrogue is self-based (three separate Hitmon families, no single heir)…
    assert Pokemon.find_by!(slug: "tyrogue").base_form?
    # …but the baby list keeps him out of the spawn pool.
    assert_equal [hitmonlee.id], Pokemon.deck.pluck(:id)
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

  # --- Committed data file (db/seeds/data/pokemon.json) ---

  test "data file carries all 251 Gen 1-2 rows with complete image URL sets" do
    rows = JSON.parse(File.read(Rails.root.join("db/seeds/data/pokemon.json")))

    assert_equal (1..251).to_a, rows.map { |r| r["dex"] }
    assert_equal 251, rows.map { |r| r["slug"] }.uniq.size
    assert(rows.all? { |r| r["generation"] == (r["dex"] <= 151 ? 1 : 2) })

    # Every row carries the six dex-slug-keyed image URLs (normal + shiny,
    # cropped primary + uncropped fallback + pixel sprite).
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
    # Tyrogue: the one self-based baby (three separate Hitmon families).
    assert_equal "tyrogue", by["tyrogue"]["base"]
    %w[hitmonlee hitmonchan hitmontop].each { |slug| assert_equal ["tyrogue"], by[slug]["baby"] }
    # Branching lines list every next step available within Gen 1–2.
    assert_equal %w[espeon flareon jolteon umbreon vaporeon], by["eevee"]["evolution"].sort
    assert_equal %w[slowbro slowking], by["slowpoke"]["evolution"].sort
    assert_equal %w[bellossom vileplume], by["gloom"]["evolution"].sort
    assert_equal %w[politoed poliwrath], by["poliwhirl"]["evolution"].sort
    # Johto retro-upgrades to Kanto lines.
    assert_equal ["steelix"], by["onix"]["evolution"]
    assert_equal ["scizor"], by["scyther"]["evolution"]
    assert_equal ["crobat"], by["golbat"]["evolution"]
    assert_equal ["blissey"], by["chansey"]["evolution"]
    assert_equal ["kingdra"], by["seadra"]["evolution"]
    # Out-of-range relatives don't exist: Marill roots itself (Azurill is Gen 3)
    # and Porygon2's Gen 4 successor is absent.
    assert_equal "marill", by["marill"]["base"]
    assert_empty by["porygon2"]["evolution"]

    babies = rows.flat_map { |r| r["baby"] }.uniq.sort
    assert_equal %w[cleffa elekid igglybuff magby pichu smoochum togepi tyrogue], babies

    spawnable = rows.select { |r| r["base"] == r["slug"] && !babies.include?(r["slug"]) }
    assert_equal 131, spawnable.size
  end

  # --- Seed (idempotency from the committed JSON) ---

  test "seed loads the 251 and is idempotent and self-syncing" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s

    assert_difference -> { Pokemon.count }, 251 do
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

  test "seed carries the family columns and shapes the 131-base deck" do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }

    charizard = Pokemon.find_by!(slug: "charizard")
    assert_equal "charmander", charizard.base
    assert_empty charizard.evolution

    deck = Pokemon.deck.pluck(:slug)
    assert_equal 131, deck.size
    assert_includes deck, "totodile"
    assert_includes deck, "snorlax"
    assert_not_includes deck, "tyrogue"   # baby, even though self-based
    assert_not_includes deck, "charizard" # evolved form
    assert_not_includes deck, "cleffa"    # baby
  end

  test "seed splits the generations at the Kanto/Johto boundary" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s
    capture_io { load seed }

    assert_equal 151, Pokemon.gen1.count
    assert_equal 100, Pokemon.gen2.count
    assert_equal (1..251).to_a, Pokemon.by_dex.pluck(:dex)

    chikorita = Pokemon.find_by!(slug: "chikorita")
    assert_equal 152, chikorita.dex
    assert_equal 2, chikorita.generation

    # Display-name special case new with Johto (title-casing would give "Ho Oh").
    assert_equal "Ho-Oh", Pokemon.find_by!(dex: 250).name
    assert_equal "Porygon2", Pokemon.find_by!(dex: 233).name
  end

  test "seed populates both a cropped avatar_url and an uncropped fallback for all 251" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s
    capture_io { load seed }

    pokemon = Pokemon.order(:dex).to_a
    assert_equal 251, pokemon.size
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

    # water is the most common type across Gen 1–2 (50 of 251); flying second (38).
    assert_equal 100, Studio::Enumeral.lookup("pokemon_type", "water").rank
    assert_equal 200, Studio::Enumeral.lookup("pokemon_type", "flying").rank
    # normal and poison tie at 37; the canonical type order breaks the tie.
    assert_equal 300, Studio::Enumeral.lookup("pokemon_type", "normal").rank
    assert_equal 400, Studio::Enumeral.lookup("pokemon_type", "poison").rank
    # dragon is the rarest across the 251 (Johto brought Dark six members).
    assert_equal 1800, Studio::Enumeral.lookup("pokemon_type", "dragon").rank

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

  test "primary type seed caches the identifying type for all 251" do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }
    capture_io { load Rails.root.join("db/seeds/57_pokemon_type_colors.rb").to_s }
    capture_io { load Rails.root.join("db/seeds/58_pokemon_primary_types.rb").to_s }

    pokemon = Pokemon.order(:dex).to_a
    assert_equal 251, pokemon.size
    assert pokemon.all? { |p| p.primary_type.present? }, "every Pokémon should have a cached primary_type"

    # Pidgeot is normal/flying; across Gen 1–2 flying (38) outnumbers normal (37),
    # so normal is now the rarer side and identifies it — the cache must agree
    # with the live computation over the full 251.
    pidgeot = Pokemon.find_by!(slug: "pidgeot")
    assert_equal "normal", pidgeot.primary_type
    assert_equal Studio::Enumeral.color_for("pokemon_type", "normal"), pidgeot.signature_color

    # A Johto row ranks with the same machinery: Tyranitar (rock/dark) wears dark.
    tyranitar = Pokemon.find_by!(slug: "tyranitar")
    assert_equal 2, tyranitar.generation
    assert_equal "dark", tyranitar.primary_type

    # Re-running the cache (the seed's class method) changes nothing.
    assert_equal 0, Pokemon.assign_primary_types!
  end
end
