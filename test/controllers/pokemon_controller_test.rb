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

  test "index offers a list/grid toggle with both views rendered" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                    hp: 160, attack: 110, defense: 65, special_attack: 65,
                    special_defense: 110, speed: 30, generation: 1,
                    avatar_url: "https://example.test/pokemon/143.png",
                    sprite_url: "https://example.test/pokemon/143-sprite.png")

    get pokemon_path
    assert_response :success

    # Alpine view state + the two toggle buttons
    assert_select "section[x-data*=?]", "view"
    assert_select "button[data-test=view-list]", "List"
    assert_select "button[data-test=view-grid]", "Grid"

    # List view is the data table (small sprite thumbnail)
    assert_select "[data-test=pokemon-list] table"
    assert_select "[data-test=pokemon-list] img[src=?]", "https://example.test/pokemon/143-sprite.png"

    # Grid view is cards using the high-res avatar
    assert_select "[data-test=pokemon-grid] img[src=?]", "https://example.test/pokemon/143.png"
    assert_select "[data-test=pokemon-grid]", text: /Snorlax/
  end
end
