require "test_helper"

# Unit tier: the shiny draw mechanics — odds per environment, the roll, and the
# shiny-aware display fallback chains. Shiny is a property of a DRAW, never of
# the Pokémon row, so none of this touches SessionMascot/Task (those adoption
# seams are covered in their own model tests).
class PokemonShinyTest < ActiveSupport::TestCase
  def make(dex, slug, **attrs)
    Pokemon.create!(dex: dex, name: slug.capitalize, slug: slug, generation: 1, **attrs)
  end

  def with_env(vars)
    saved = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # --- Odds ---

  test "shiny odds are 1-in-2 on development" do
    with_env("SHINY_ODDS" => nil, "QA_ENV" => nil) do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        assert_equal 2, Pokemon.shiny_odds
      end
    end
  end

  test "the test env never rolls shiny unless opted in" do
    with_env("SHINY_ODDS" => nil, "QA_ENV" => nil) do
      assert_equal 0, Pokemon.shiny_odds
      20.times { assert_not Pokemon.roll_shiny? }
    end
  end

  test "shiny odds are 1-in-25 on production" do
    with_env("SHINY_ODDS" => nil, "QA_ENV" => nil) do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
        assert_equal 25, Pokemon.shiny_odds
      end
    end
  end

  test "QA (production Rails env plus QA_ENV) keeps the 1-in-2 odds" do
    with_env("SHINY_ODDS" => nil, "QA_ENV" => "true") do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
        assert_equal 2, Pokemon.shiny_odds
      end
    end
  end

  test "SHINY_ODDS overrides the environment odds" do
    with_env("SHINY_ODDS" => "25") do
      assert_equal 25, Pokemon.shiny_odds
    end
  end

  test "roll_shiny? always hits at 1-in-1 odds" do
    with_env("SHINY_ODDS" => "1") do
      20.times { assert Pokemon.roll_shiny? }
    end
  end

  test "status_emoji adds the shiny glyph after type emojis" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire", metadata: { "emoji" => "🔥" })
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", metadata: { "emoji" => "💨" })
    pokemon = make(6, "charizard", types: %w[fire flying])

    assert_equal "🔥💨", pokemon.status_emoji
    assert_equal "🔥💨✨", pokemon.status_emoji(shiny: true)
    assert_equal "🔥💨✨", Pokemon.decorate_type_emoji("✨🔥💨", shiny: true)
  end

  # --- Display chains ---

  test "display_avatar prefers the shiny chain for a shiny draw" do
    pokemon = make(1, "bulbasaur", avatar_url: "n-crop.png", shiny_avatar_url: "s-crop.png",
                                   shiny_avatar_fallback_url: "s-orig.png", shiny_sprite_url: "s-sprite.png")
    assert_equal "n-crop.png", pokemon.display_avatar
    assert_equal "s-crop.png", pokemon.display_avatar(shiny: true)
  end

  test "shiny display_avatar walks the shiny chain then the normal one" do
    pokemon = make(2, "ivysaur", avatar_url: "n-crop.png", shiny_avatar_fallback_url: "s-orig.png")
    assert_equal "s-orig.png", pokemon.display_avatar(shiny: true)

    pokemon.shiny_avatar_fallback_url = nil
    # Unprovisioned shiny art falls back to the normal chain — never faceless.
    assert_equal "n-crop.png", pokemon.display_avatar(shiny: true)
  end

  test "display_sprite is shiny-aware with a normal fallback" do
    pokemon = make(3, "venusaur", sprite_url: "n-sprite.png", shiny_sprite_url: "s-sprite.png")
    assert_equal "n-sprite.png", pokemon.display_sprite
    assert_equal "s-sprite.png", pokemon.display_sprite(shiny: true)

    pokemon.shiny_sprite_url = nil
    assert_equal "n-sprite.png", pokemon.display_sprite(shiny: true)
  end
end
