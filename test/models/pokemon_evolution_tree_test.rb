require "test_helper"

class PokemonEvolutionTreeTest < ActiveSupport::TestCase
  def create_charmander_family!
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander",
                    base: "charmander", evolution: ["charmeleon"])
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon",
                    base: "charmander", evolution: ["charizard"])
    Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", base: "charmander")
  end

  test "for returns the whole family from any member, base first" do
    create_charmander_family!
    %w[charmander charmeleon charizard].each do |slug|
      assert_equal %w[charmander charmeleon charizard], PokemonEvolutionTree.for(slug)
    end
  end

  test "for fans out over branching evolutions" do
    Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", evolution: %w[vaporeon jolteon])
    Pokemon.create!(dex: 134, name: "Vaporeon", slug: "vaporeon", base: "eevee")
    Pokemon.create!(dex: 135, name: "Jolteon", slug: "jolteon", base: "eevee")

    assert_equal %w[eevee vaporeon jolteon], PokemonEvolutionTree.for("jolteon")
  end

  test "for leaves babies out of the family, even when asked from the baby" do
    Pokemon.create!(dex: 35, name: "Clefairy", slug: "clefairy",
                    evolution: ["clefable"], baby: ["cleffa"])
    Pokemon.create!(dex: 36, name: "Clefable", slug: "clefable", base: "clefairy")
    Pokemon.create!(dex: 173, name: "Cleffa", slug: "cleffa",
                    base: "clefairy", evolution: ["clefairy"])

    assert_equal %w[clefairy clefable], PokemonEvolutionTree.for("clefairy")
    assert_equal %w[clefairy clefable], PokemonEvolutionTree.for("cleffa")
  end

  test "a single-stage Pokémon is a one-member family" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax")
    assert_equal ["snorlax"], PokemonEvolutionTree.for("snorlax")
  end

  test "for handles unknown and blank slugs" do
    assert_equal ["missingno"], PokemonEvolutionTree.for("missingno")
    assert_equal [], PokemonEvolutionTree.for("")
    assert_equal [], PokemonEvolutionTree.for(nil)
  end
end
