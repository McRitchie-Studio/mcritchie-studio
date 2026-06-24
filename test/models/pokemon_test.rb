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

  # --- Type colors (shared Studio::Enumeral) ---

  test "type_colors maps each seeded type to its color in one query" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire",  color: "#EE8130", position: 0)
    Studio::Enumeral.create!(category: "pokemon_type", key: "water", color: "#6390F0", position: 1)
    assert_equal({ "fire" => "#EE8130", "water" => "#6390F0" }, Pokemon.type_colors)
  end

  test "type_color returns the color for a type, or nil" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire", color: "#EE8130")
    charizard = make(6, "charizard")
    assert_equal "#EE8130", charizard.type_color("fire")
    assert_nil charizard.type_color("ghost")
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
  end
end
