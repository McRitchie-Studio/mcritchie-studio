require "test_helper"

class PokemonControllerTest < ActionDispatch::IntegrationTest
  test "index renders the seeded Pokemon for anonymous visitors" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                    hp: 160, attack: 110, defense: 65, special_attack: 65,
                    special_defense: 110, speed: 30, generation: 1,
                    avatar_url: "https://example.test/pokemon/143.png",
                    sprite_url: "https://example.test/pokemon/143-sprite.png")

    get pokemon_path

    assert_response :success
    assert_select "td", "Snorlax"
    assert_select "img[src=?]", "https://example.test/pokemon/143-sprite.png"
    assert_select "a[href=?]", "https://example.test/pokemon/143.png"
  end
end
