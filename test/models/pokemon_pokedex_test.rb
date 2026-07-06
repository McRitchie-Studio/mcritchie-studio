require "test_helper"

class PokemonPokedexTest < ActiveSupport::TestCase
  test "[unit] computes spawned stats, latest spawn, and recent Pokemon actions" do
    snorlax = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                              generation: 1, sprite_url: "https://example.test/snorlax-sprite.png")
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", types: %w[electric],
                              generation: 1, avatar_url: "https://example.test/pikachu.png",
                              shiny_avatar_url: "https://example.test/pikachu-shiny.png",
                              sprite_url: "https://example.test/pikachu-sprite.png")

    SessionMascot.create!(session_id: "s-old", mascot_slug: snorlax.slug,
                          created_at: 2.days.ago, updated_at: 2.days.ago)
    SessionMascot.create!(session_id: "s-new", mascot_slug: pikachu.slug, shiny: true,
                          created_at: 1.hour.ago, updated_at: 1.hour.ago)
    task = Task.create!(title: "Build Pokedex View",
                        metadata: { "devops" => { "session_id" => "s-new" } })

    AgentAction.create!(session_id: "s-new", mascot: pikachu.slug, task_slug: task.slug,
                        kind: "bash", summary: "ran focused tests", outcome: "ok",
                        occurred_at: 5.minutes.ago)
    AgentAction.create!(session_id: "s-old", mascot: snorlax.slug,
                        kind: "read", summary: "loaded context", outcome: "ok",
                        occurred_at: 10.minutes.ago)
    AgentAction.create!(session_id: "s-human", mascot: "avi",
                        kind: "note", summary: "not a Pokemon", outcome: "ok",
                        occurred_at: Time.current)

    pokedex = PokemonPokedex.new(recent_limit: 2)

    assert_equal 2, pokedex.total_pokemon
    assert_equal 2, pokedex.summoned_pokemon
    assert_equal 1, pokedex.shiny_pokemon

    assert_equal pikachu, pokedex.latest_spawn.pokemon
    assert_equal task, pokedex.latest_spawn.task
    assert pokedex.latest_spawn.shiny

    assert_equal [pikachu, snorlax], pokedex.recent_actions.map(&:pokemon)
    assert_equal ["ran focused tests", "loaded context"], pokedex.recent_actions.map { |row| row.action.summary }
  end
end
