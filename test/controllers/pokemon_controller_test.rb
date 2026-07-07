require "test_helper"

class PokemonControllerTest < ActionDispatch::IntegrationTest
  test "[integration] pokedex renders latest spawn, stats, and recent actions" do
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", types: %w[electric],
                              generation: 1, avatar_url: "https://example.test/pikachu.png",
                              shiny_avatar_url: "https://example.test/pikachu-shiny.png",
                              sprite_url: "https://example.test/pikachu-sprite.png")
    SessionMascot.create!(session_id: "s-pika", mascot_slug: pikachu.slug, shiny: true,
                          created_at: 30.minutes.ago, updated_at: 30.minutes.ago)
    task = Task.create!(title: "Build Pokedex View",
                        metadata: { "devops" => { "session_id" => "s-pika" } })
    AgentAction.create!(session_id: "s-pika", mascot: pikachu.slug, task_slug: task.slug,
                        kind: "bash", summary: "ran focused tests", outcome: "ok",
                        occurred_at: 2.minutes.ago)

    get pokedex_path

    assert_response :success
    assert_select "[data-test=pokedex]"
    assert_select "h1", "Spawned Pokémon"
    assert_select "[data-test=latest-pokemon-card]" do
      assert_select "img[src=?]", "https://example.test/pikachu-shiny.png"
      assert_select "dd", "Pikachu"
      assert_select "a[href=?]", task_path(task.slug), "Build Pokedex View"
      assert_select "span", "Shiny"
    end
    assert_select "[data-test=pokemon-stats-card]" do
      assert_select "p", "Total Pokémon"
      assert_select "p", "Summoned Pokémon"
      assert_select "p", "Shiny Pokémon"
    end
    assert_select "[data-test=recent-pokemon-action]", count: 1 do
      assert_select "td", /Pikachu/
      assert_select "td", /ran focused tests/
      assert_select "a[href=?]", task_path(task.slug), "Build Pokedex View"
    end
  end

  test "[integration] pokemon path remains a compatibility alias" do
    get pokemon_path

    assert_response :success
    assert_select "[data-test=pokedex]"
    assert_select "h1", "Spawned Pokémon"
  end

  test "[component] empty pokedex renders stable empty states" do
    get pokedex_path

    assert_response :success
    assert_select "[data-test=latest-pokemon-empty]", "No spawned Pokémon yet."
    assert_select "[data-test=recent-pokemon-empty]", "No Pokémon actions yet."
  end
end
