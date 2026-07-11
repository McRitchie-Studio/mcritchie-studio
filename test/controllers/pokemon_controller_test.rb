require "test_helper"

class PokemonControllerTest < ActionDispatch::IntegrationTest
  test "[component] pokedex renders two Pokémon cards, the header dex count, and a shiny sparkle" do
    charmander = Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", generation: 1,
                                 base: "charmander", evolution: ["charmeleon"],
                                 avatar_url: "https://example.test/charmander.png",
                                 sprite_url: "https://example.test/charmander-sprite.png")
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon", generation: 1,
                    base: "charmander", evolution: ["charizard"])
    charizard = Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", generation: 1,
                                base: "charmander", evolution: [],
                                avatar_url: "https://example.test/charizard.png",
                                sprite_url: "https://example.test/charizard-sprite.png")
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1,
                              avatar_url: "https://example.test/pikachu.png",
                              shiny_avatar_url: "https://example.test/pikachu-shiny.png",
                              sprite_url: "https://example.test/pikachu-sprite.png")

    # A shiny spawn (drives the shiny card + sparkle) and a plain spawn.
    SessionMascot.create!(session_id: "s-pika", mascot_slug: pikachu.slug, shiny: true,
                          created_at: 30.minutes.ago, updated_at: 30.minutes.ago)
    SessionMascot.create!(session_id: "s-char", mascot_slug: charmander.slug,
                          created_at: 2.hours.ago, updated_at: 2.hours.ago)

    # A shipped task catches the whole Charmander line (final form + pre-evolutions).
    ship = Task.create!(title: "Ship Charizard Line",
                        metadata: { "devops" => { "mascot" => charizard.slug } })
    TaskEvent.create!(task_slug: ship.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 10.minutes.ago, metadata: { "mascot" => { "slug" => charizard.slug } })

    get pokedex_path

    assert_response :success
    assert_select "[data-test=pokedex]"
    assert_select "h1", "Pokémon"
    assert_select "[data-test=pokedex-total]", "4"

    assert_select "[data-test=pokemon-card]" do
      assert_select "[data-test=pokemon-caught]", "3" # charmander + charmeleon + charizard
      assert_select "[data-test=pokemon-newest-caught]" do
        assert_select "a[href=?]", task_path(ship.slug), "Ship Charizard Line"
      end
    end

    assert_select "[data-test=shiny-card]" do
      assert_select "[data-test=shiny-seen]", "1"
      assert_select "[data-test=shiny-caught]", "0" # no shiny ship yet
      assert_select "[data-test=shiny-sparkle]"
      assert_select "img[src=?]", "https://example.test/pikachu-shiny.png"
    end
  end

  test "[integration] pokedex surfaces a first-time evolution as the newest seen" do
    larvitar = Pokemon.create!(dex: 246, name: "Larvitar", slug: "larvitar", generation: 2,
                               sprite_url: "https://example.test/larvitar-sprite.png")
    pupitar = Pokemon.create!(dex: 247, name: "Pupitar", slug: "pupitar", generation: 2,
                              avatar_url: "https://example.test/pupitar.png",
                              sprite_url: "https://example.test/pupitar-sprite.png")
    SessionMascot.create!(session_id: "s-lv", mascot_slug: larvitar.slug,
                          created_at: 2.hours.ago, updated_at: 2.hours.ago)
    task = Task.create!(title: "Order Session Filter Recency",
                        metadata: { "devops" => { "mascot" => larvitar.slug } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 20.minutes.ago, metadata: { "mascot" => { "slug" => pupitar.slug } })

    get pokedex_path

    assert_response :success
    assert_select "[data-test=pokemon-newest-seen]" do
      assert_select "a[href=?]", task_path(task.slug), "Order Session Filter Recency"
    end
  end

  test "[integration] pokemon path remains a compatibility alias" do
    get pokemon_path

    assert_response :success
    assert_select "[data-test=pokedex]"
    assert_select "h1", "Pokémon"
  end

  test "[component] empty pokedex renders stable empty states" do
    get pokedex_path

    assert_response :success
    assert_select "[data-test=pokemon-newest-seen-empty]", "None seen yet."
    assert_select "[data-test=pokemon-newest-caught-empty]", "None caught yet."
    assert_select "[data-test=shiny-newest-seen-empty]", "None seen yet."
    assert_select "[data-test=recent-pokemon-empty]", "No Pokémon actions yet."
  end
end
