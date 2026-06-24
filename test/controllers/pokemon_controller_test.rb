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

  test "type badges carry the seeded enumeral color + emoji (list + grid)" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "normal", label: "Normal",
                             color: "#A8A77A", position: 0, metadata: { "emoji" => "⚪" })
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                    hp: 160, attack: 110, defense: 65, special_attack: 65,
                    special_defense: 110, speed: 30, generation: 1,
                    avatar_url: "https://example.test/pokemon/143.png",
                    sprite_url: "https://example.test/pokemon/143-sprite.png")

    get pokemon_path
    assert_response :success

    # The badge is colored by an inline style from the enumeral; both the list
    # row and the grid card render one, so there are at least two.
    assert_select "span[data-type=normal][style*=?]", "#A8A77A", minimum: 2
    # …and prefixed with the type's emoji.
    assert_select "span[data-type=normal] [data-test=type-emoji]", text: "⚪", minimum: 2
  end

  test "a type with no enumeral falls back to the neutral chip" do
    Pokemon.create!(dex: 999, name: "Mysterymon", slug: "mysterymon", types: %w[mystery],
                    hp: 1, attack: 1, defense: 1, special_attack: 1,
                    special_defense: 1, speed: 1, generation: 1,
                    avatar_url: "https://example.test/pokemon/999.png",
                    sprite_url: "https://example.test/pokemon/999-sprite.png")

    get pokemon_path
    assert_response :success

    # No seeded color → the neutral surface chip (no inline color style).
    assert_select "span[data-type=mystery].bg-surface", minimum: 2
  end
end
