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

  test "deck is only generation 1" do
    g1 = make(143, "snorlax", generation: 1)
    make(152, "chikorita", generation: 2)
    assert_equal [g1.id], Pokemon.deck.pluck(:id)
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

  # --- Seed (idempotency from the committed JSON) ---

  test "seed loads the 151 and is idempotent and self-syncing" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s

    assert_difference -> { Pokemon.count }, 151 do
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

  test "seed populates both a cropped avatar_url and an uncropped fallback for all 151" do
    seed = Rails.root.join("db/seeds/56_pokemon.rb").to_s
    capture_io { load seed }

    pokemon = Pokemon.order(:dex).to_a
    assert_equal 151, pokemon.size
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

    # poison is the most common type across the original 151; water second.
    assert_equal 100, Studio::Enumeral.lookup("pokemon_type", "poison").rank
    assert_equal 200, Studio::Enumeral.lookup("pokemon_type", "water").rank
    # Dark is absent from the 151, so it ranks last.
    assert_equal 1800, Studio::Enumeral.lookup("pokemon_type", "dark").rank

    # Every rank is a distinct multiple of 100, 100..1800.
    ranks = Studio::Enumeral.in_category("pokemon_type").pluck(:rank).sort
    assert_equal (1..18).map { |i| i * 100 }, ranks

    # Each type also carries its emoji (in metadata) — the operator's chosen set.
    assert_equal "🔥", Studio::Enumeral.lookup("pokemon_type", "fire").emoji
    assert_equal "🔶", Studio::Enumeral.lookup("pokemon_type", "normal").emoji
    assert_equal "👊", Studio::Enumeral.lookup("pokemon_type", "fighting").emoji
    assert_equal "🏔", Studio::Enumeral.lookup("pokemon_type", "ground").emoji
  end
end
