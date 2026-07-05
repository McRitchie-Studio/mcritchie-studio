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

  test "grid cards and list thumbnails flip to shiny art on click" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                    generation: 1,
                    avatar_url: "https://example.test/pokemon/143-cropped.png",
                    sprite_url: "https://example.test/pokemon/143-sprite.png",
                    shiny_avatar_url: "https://example.test/pokemon/143-shiny-cropped.png",
                    shiny_sprite_url: "https://example.test/pokemon/143-shiny-sprite.png")

    get pokemon_path
    assert_response :success

    # Grid: one toggle button wraps BOTH renditions; the shiny one starts cloaked
    # (hidden + lazy, so it isn't fetched until the first flip).
    assert_select "[data-test=pokemon-grid] button[data-test=shiny-toggle]" do
      assert_select "img[src=?]", "https://example.test/pokemon/143-cropped.png"
      assert_select "img[src=?][x-cloak]", "https://example.test/pokemon/143-shiny-cropped.png"
    end
    # List: the sprite thumbnail flips the same way.
    assert_select "[data-test=pokemon-list] button[data-test=list-shiny-toggle]" do
      assert_select "img[src=?]", "https://example.test/pokemon/143-sprite.png"
      assert_select "img[src=?][x-cloak]", "https://example.test/pokemon/143-shiny-sprite.png"
    end
  end

  test "grid cards wear their next evolutions as circles; single-stage cards wear none" do
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", types: %w[fire],
                    generation: 1, base: "charmander", evolution: ["charmeleon"],
                    avatar_url: "https://example.test/pokemon/4.png",
                    sprite_url: "https://example.test/pokemon/4-sprite.png")
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon", types: %w[fire],
                    generation: 1, base: "charmander", evolution: ["charizard"],
                    avatar_url: "https://example.test/pokemon/5.png",
                    sprite_url: "https://example.test/pokemon/5-sprite.png")
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                    generation: 1,
                    avatar_url: "https://example.test/pokemon/143.png",
                    sprite_url: "https://example.test/pokemon/143-sprite.png")

    get pokemon_path
    assert_response :success

    # Charmander's card carries Charmeleon's sprite as a circle…
    assert_select "[data-test=pokemon-grid] img[data-test=evolution-circle][src=?]",
                  "https://example.test/pokemon/5-sprite.png"
    # …and it's the only card wearing circles: Snorlax has no line ahead, and
    # Charmeleon's next step (Charizard) isn't seeded here so it renders none.
    assert_select "[data-test=pokemon-grid] [data-test=evolution-circles]", count: 1
  end

  test "index renders Johto rows alongside Kanto, ordered by dex" do
    Pokemon.create!(dex: 152, name: "Chikorita", slug: "chikorita", types: %w[grass],
                    hp: 45, attack: 49, defense: 65, special_attack: 49,
                    special_defense: 65, speed: 45, generation: 2,
                    avatar_url: "https://example.test/pokemon/152.png",
                    sprite_url: "https://example.test/pokemon/152-sprite.png")
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                    hp: 160, attack: 110, defense: 65, special_attack: 65,
                    special_defense: 110, speed: 30, generation: 1,
                    avatar_url: "https://example.test/pokemon/143.png",
                    sprite_url: "https://example.test/pokemon/143-sprite.png")

    get pokemon_path

    assert_response :success
    assert_select "td", "Chikorita"
    # Dex order puts Snorlax (#143) before Chikorita (#152) despite creation order.
    body_names = css_select("[data-test=pokemon-list] td.font-medium").map(&:text)
    assert_equal %w[Snorlax Chikorita], body_names
    # The Gen column distinguishes the generations.
    assert_select "[data-test=pokemon-list] td", "2"
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
