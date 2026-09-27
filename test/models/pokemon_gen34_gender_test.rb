require "test_helper"

# [unit] The Gen 3–4 gender-gated branches (tasks/pokemon-gen-3-and-4), read off
# the committed seed rather than hand-built rows, so they prove the fetched data
# and the existing Pokemon#evolution_for machinery together: a male Kirlia may
# reach Gallade and a female may not; a female Snorunt may reach Froslass; Burmy
# splits by gender; a male Combee has no evolution at all.
class PokemonGen34GenderTest < ActiveSupport::TestCase
  setup do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }
  end

  def branches(slug, gender)
    Pokemon.find_by!(slug: slug).evolution_for(gender).sort
  end

  test "a male Kirlia may reach Gallade or Gardevoir; a female only Gardevoir" do
    assert_equal %w[gallade gardevoir], branches("kirlia", "male")
    assert_equal %w[gardevoir], branches("kirlia", "female")
  end

  test "a female Snorunt may reach Froslass or Glalie; a male only Glalie" do
    assert_equal %w[froslass glalie], branches("snorunt", "female")
    assert_equal %w[glalie], branches("snorunt", "male")
  end

  test "Burmy becomes Wormadam when female and Mothim when male" do
    assert_equal %w[wormadam], branches("burmy", "female")
    assert_equal %w[mothim], branches("burmy", "male")
  end

  test "a male Combee has no evolution; a female becomes Vespiquen" do
    assert_empty branches("combee", "male")
    assert_equal %w[vespiquen], branches("combee", "female")
  end

  test "a legacy draw with no gender keeps every branch" do
    assert_equal %w[gallade gardevoir], branches("kirlia", nil)
    assert_equal %w[vespiquen], branches("combee", nil)
  end

  test "the gated targets are single-gender species, so an evolved draw stays consistent" do
    assert Pokemon.find_by!(slug: "gallade").allows_gender?("male")
    assert_not Pokemon.find_by!(slug: "gallade").allows_gender?("female")
    %w[froslass wormadam vespiquen].each do |slug|
      assert_not Pokemon.find_by!(slug: slug).allows_gender?("male"), slug
    end
    assert_not Pokemon.find_by!(slug: "mothim").allows_gender?("female")
  end

  test "the evolution tree prunes the branch a gender cannot take" do
    assert_equal %w[ralts kirlia gardevoir], Pokemon.evolution_tree_for("ralts", gender: "female")
    assert_equal %w[ralts kirlia gardevoir gallade], Pokemon.evolution_tree_for("ralts", gender: "male")
    assert_equal %w[combee], Pokemon.evolution_tree_for("combee", gender: "male")
  end

  test "a female draw of a Gen 3-4 species with a female look wears the female sprite" do
    combee = Pokemon.find_by!(slug: "combee")
    assert combee.has_gender_differences?
    assert_equal combee.female_sprite_url, combee.display_sprite(gender: "female")
    assert_equal combee.shiny_female_sprite_url, combee.display_sprite(shiny: true, gender: "female")
    assert_equal combee.sprite_url, combee.display_sprite(gender: "male")
  end
end
