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
end
