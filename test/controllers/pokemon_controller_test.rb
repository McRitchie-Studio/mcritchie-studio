require "test_helper"

class PokemonControllerTest < ActionDispatch::IntegrationTest
  test "[integration] pokedex renders newest unique, stats, and recent actions" do
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
      assert_select "dt", "Obtained"
      assert_select "a[href=?]", task_path(task.slug), "Build Pokedex View"
      assert_select "span", "Shiny"
    end
    assert_select "[data-test=latest-shiny-card]" do
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

  test "[integration] pokedex surfaces a first-time evolution as the newest unique" do
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
    assert_select "[data-test=latest-pokemon-card]" do
      assert_select "dd", "Pupitar"
      assert_select "dt", "Obtained"
      assert_select "a[href=?]", task_path(task.slug), "Order Session Filter Recency"
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
    assert_select "[data-test=latest-shiny-empty]", "No shiny Pokémon yet."
    assert_select "[data-test=recent-pokemon-empty]", "No Pokémon actions yet."
  end
end
