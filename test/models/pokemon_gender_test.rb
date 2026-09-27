require "test_helper"

# [unit] Mascot gender (tasks/pokemon-mascot-gender): the roll weighted by the
# species' PokéAPI gender_rate, the evolution branches a gender allows, the
# Nidoran gender family's name and art, and the female pixel sprite.
class PokemonGenderTest < ActiveSupport::TestCase
  SPRITE = "https://img.test/%s.png".freeze

  def make(dex, slug, **attrs)
    Pokemon.where(slug: slug).first_or_initialize.tap do |pokemon|
      pokemon.update!({ dex: dex, name: slug.capitalize, slug: slug, types: %w[poison], generation: 1,
                        base: slug, evolution: [], baby: [] }.merge(attrs))
    end
  end

  # The Nidoran line as the committed seed data shapes it: two species rows (the
  # legacy nidoran-f / nidoran-m, each rooting its own line) plus the drawable
  # `nidoran` family row that shares dex 29 and branches by gender.
  def seed_nidoran!
    make(29, "nidoran-f", name: "Nidoran♀", gender_rate: 8, evolution: ["nidorina"],
                          avatar_url: format(SPRITE, "29-art"), sprite_url: format(SPRITE, "29-sprite"),
                          shiny_sprite_url: format(SPRITE, "29-shiny-sprite"))
    make(32, "nidoran-m", name: "Nidoran♂", gender_rate: 0, evolution: ["nidorino"],
                          avatar_url: format(SPRITE, "32-art"), sprite_url: format(SPRITE, "32-sprite"),
                          shiny_sprite_url: format(SPRITE, "32-shiny-sprite"))
    make(30, "nidorina", base: "nidoran", gender_rate: 8, evolution: ["nidoqueen"])
    make(31, "nidoqueen", base: "nidoran", gender_rate: 8)
    make(33, "nidorino", base: "nidoran", gender_rate: 0, evolution: ["nidoking"])
    make(34, "nidoking", base: "nidoran", gender_rate: 0)
    make(29, "nidoran", name: "Nidoran", gender_rate: 4, evolution: %w[nidorina nidorino],
                        avatar_url: format(SPRITE, "29-art"), sprite_url: format(SPRITE, "29-sprite"),
                        gender_forms: { "female" => "nidoran-f", "male" => "nidoran-m" },
                        evolution_genders: { "nidorina" => "female", "nidorino" => "male" })
  end

  # --- the roll ---------------------------------------------------------------

  test "a genderless species rolls no gender" do
    Pokemon.stub(:gender_die, 0) do
      assert_nil Pokemon.roll_gender(-1)
    end
    assert_nil Pokemon.roll_gender(nil), "an unrecorded rate is treated as genderless"
  end

  test "forced species always roll their only gender, whatever the die says" do
    (0..7).each do |face|
      Pokemon.stub(:gender_die, face) do
        assert_equal "male", Pokemon.roll_gender(0), "gender_rate 0 is always male (die #{face})"
        assert_equal "female", Pokemon.roll_gender(8), "gender_rate 8 is always female (die #{face})"
      end
    end
  end

  test "a mixed species is female exactly when the die lands under gender_rate" do
    # gender_rate n means an n/8 chance of female: the faces 0..n-1 of eight.
    (1..7).each do |rate|
      females = (0..7).count { |face| Pokemon.stub(:gender_die, face) { Pokemon.roll_gender(rate) } == "female" }
      assert_equal rate, females, "gender_rate #{rate} is female on #{rate} of 8 faces"
    end
  end

  test "the test env die is fixed, so a mixed roll is deterministically male" do
    assert_equal 7, Pokemon.gender_die
    assert_equal "male", Pokemon.roll_gender(4)
    assert_equal "male", Pokemon.roll_gender(7)
  end

  test "outside test the die is a real eight-sided roll" do
    Rails.env.stub(:test?, false) do
      faces = Array.new(400) { Pokemon.gender_die }.uniq.sort
      assert_equal (0..7).to_a, faces
    end
  end

  test "allows_gender? keeps a gender only the species can carry" do
    genderless = make(81, "magnemite", gender_rate: -1)
    male_only = make(106, "hitmonlee", gender_rate: 0)
    female_only = make(113, "chansey", gender_rate: 8)
    mixed = make(1, "bulbasaur", gender_rate: 1)

    assert genderless.allows_gender?(nil)
    refute genderless.allows_gender?("female")
    assert male_only.allows_gender?("male")
    refute male_only.allows_gender?("female")
    assert female_only.allows_gender?("female")
    refute female_only.allows_gender?("male")
    assert mixed.allows_gender?("female")
    assert mixed.allows_gender?("male")
  end

  # --- evolution branches ---------------------------------------------------------

  test "evolution_for keeps only the branches the gender allows" do
    seed_nidoran!
    nidoran = Pokemon.find_by!(slug: "nidoran")

    assert_equal ["nidorina"], nidoran.evolution_for("female")
    assert_equal ["nidorino"], nidoran.evolution_for("male")
    assert_equal %w[nidorina nidorino], nidoran.evolution_for(nil),
                 "a legacy draw with no gender keeps every branch"
    assert_equal ["nidorina"], nidoran.evolutions_for("female").pluck(:slug)
  end

  test "an ungated branch is open to every gender" do
    eevee = make(133, "eevee", gender_rate: 1, evolution: %w[vaporeon jolteon])

    assert_equal %w[vaporeon jolteon], eevee.evolution_for("female")
    assert_equal %w[vaporeon jolteon], eevee.evolution_for("male")
  end

  test "the evolution tree for a gender prunes the other gender's line" do
    seed_nidoran!

    assert_equal %w[nidoran nidorina nidoqueen], Pokemon.evolution_tree_for("nidoran", gender: "female")
    assert_equal %w[nidoran nidorino nidoking], Pokemon.evolution_tree_for("nidorino", gender: "male")
    assert_equal %w[nidoran nidorina nidorino nidoqueen nidoking], Pokemon.evolution_tree_for("nidoran")
  end

  # --- the Nidoran family ---------------------------------------------------------

  test "the deck draws the nidoran family and never its legacy species rows" do
    seed_nidoran!
    deck = Pokemon.deck.pluck(:slug)

    assert_includes deck, "nidoran"
    refute_includes deck, "nidoran-f"
    refute_includes deck, "nidoran-m"
  end

  test "nidoran is named and drawn by gender: dex-29 art female, dex-32 art male" do
    seed_nidoran!
    nidoran = Pokemon.find_by!(slug: "nidoran")

    assert_equal "Nidoran♀", nidoran.display_name(gender: "female")
    assert_equal "Nidoran♂", nidoran.display_name(gender: "male")
    assert_equal "Nidoran", nidoran.display_name

    assert_equal format(SPRITE, "29-art"), nidoran.display_avatar(gender: "female")
    assert_equal format(SPRITE, "32-art"), nidoran.display_avatar(gender: "male")
    assert_equal format(SPRITE, "29-sprite"), nidoran.display_sprite(gender: "female")
    assert_equal format(SPRITE, "32-sprite"), nidoran.display_sprite(gender: "male")
    assert_equal format(SPRITE, "32-shiny-sprite"), nidoran.display_sprite(shiny: true, gender: "male")
  end

  test "old nidoran-f and nidoran-m slugs still resolve to their name and art" do
    seed_nidoran!

    female = Pokemon.find_by!(slug: "nidoran-f")
    male = Pokemon.find_by!(slug: "nidoran-m")
    assert_equal "Nidoran♀", female.display_name
    assert_equal format(SPRITE, "29-sprite"), female.display_sprite
    assert_equal "Nidoran♂", male.display_name
    assert_equal format(SPRITE, "32-art"), male.display_avatar
    assert_equal ["nidorina"], female.evolution_for(nil), "an old nidoran-f task still evolves to Nidorina"
  end

  # --- the female sprite ------------------------------------------------------------

  test "a female draw of a species with gender differences wears the female sprite" do
    venusaur = make(3, "venusaur", gender_rate: 1, has_gender_differences: true,
                                   sprite_url: "normal.png", shiny_sprite_url: "shiny.png",
                                   female_sprite_url: "female.png", shiny_female_sprite_url: "shiny-female.png")

    assert_equal "female.png", venusaur.display_sprite(gender: "female")
    assert_equal "shiny-female.png", venusaur.display_sprite(shiny: true, gender: "female")
    assert_equal "normal.png", venusaur.display_sprite(gender: "male")
    assert_equal "shiny.png", venusaur.display_sprite(shiny: true, gender: "male")
    assert_equal "normal.png", venusaur.display_sprite
  end

  test "the female sprite falls back to the normal sprite when not provisioned" do
    venusaur = make(3, "venusaur", gender_rate: 1, has_gender_differences: true,
                                   sprite_url: "normal.png", shiny_sprite_url: "shiny.png")

    assert_equal "normal.png", venusaur.display_sprite(gender: "female")
    assert_equal "shiny.png", venusaur.display_sprite(shiny: true, gender: "female")
  end

  test "a species without gender differences ignores a stray female sprite" do
    pidgey = make(16, "pidgey", gender_rate: 4, has_gender_differences: false,
                                sprite_url: "normal.png", female_sprite_url: "female.png")

    assert_equal "normal.png", pidgey.display_sprite(gender: "female")
  end

  test "avatars stay official artwork for every gender" do
    venusaur = make(3, "venusaur", gender_rate: 1, has_gender_differences: true,
                                   avatar_url: "art.png", female_sprite_url: "female.png")

    assert_equal "art.png", venusaur.display_avatar(gender: "female")
  end
end
