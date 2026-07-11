require "test_helper"

class PokemonPokedexTest < ActiveSupport::TestCase
  test "[unit] computes spawned stats, newest unique, and recent Pokemon actions" do
    snorlax = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal],
                              generation: 1, sprite_url: "https://example.test/snorlax-sprite.png")
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", types: %w[electric],
                              generation: 1, avatar_url: "https://example.test/pikachu.png",
                              shiny_avatar_url: "https://example.test/pikachu-shiny.png",
                              sprite_url: "https://example.test/pikachu-sprite.png")
    eevee = Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", types: %w[normal],
                            generation: 1, sprite_url: "https://example.test/eevee-sprite.png")

    SessionMascot.create!(session_id: "s-old", mascot_slug: snorlax.slug,
                          created_at: 2.days.ago, updated_at: 2.days.ago)
    SessionMascot.create!(session_id: "s-new", mascot_slug: pikachu.slug, shiny: true,
                          created_at: 1.hour.ago, updated_at: 1.hour.ago)
    SessionMascot.create!(session_id: "s-newest", mascot_slug: eevee.slug,
                          created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    task = Task.create!(title: "Build Pokedex View",
                        metadata: { "devops" => { "session_id" => "s-new", "mascot" => pikachu.slug } })

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

    assert_equal 3, pokedex.total_pokemon
    assert_equal 3, pokedex.summoned_pokemon
    assert_equal 1, pokedex.shiny_pokemon

    assert_equal eevee, pokedex.newest_unique.pokemon
    assert_not pokedex.newest_unique.shiny
    assert_equal pikachu, pokedex.newest_unique_shiny.pokemon
    assert_equal task, pokedex.newest_unique_shiny.task
    assert pokedex.newest_unique_shiny.shiny

    assert_equal [pikachu, snorlax], pokedex.recent_actions.map(&:pokemon)
    assert_equal ["ran focused tests", "loaded context"], pokedex.recent_actions.map { |row| row.action.summary }
  end

  test "[unit] newest unique is the species first seen most recently, not the latest spawn" do
    snorlax = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1)
    eevee = Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", generation: 1)
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1)

    SessionMascot.create!(session_id: "s1", mascot_slug: snorlax.slug, created_at: 3.days.ago, updated_at: 3.days.ago)
    SessionMascot.create!(session_id: "s2", mascot_slug: eevee.slug,   created_at: 2.days.ago, updated_at: 2.days.ago)
    SessionMascot.create!(session_id: "s3", mascot_slug: pikachu.slug, created_at: 1.day.ago,  updated_at: 1.day.ago)
    # A REPEAT Snorlax spawn is the newest row overall, but Snorlax was first seen
    # 3 days ago — a repeat must never re-bump the card.
    SessionMascot.create!(session_id: "s4", mascot_slug: snorlax.slug, created_at: 1.minute.ago, updated_at: 1.minute.ago)

    pokedex = PokemonPokedex.new

    assert_equal pikachu, pokedex.newest_unique.pokemon, "the most recent FIRST sighting wins, not the latest spawn"
    assert_in_delta 1.day.ago.to_f, pokedex.newest_unique.first_seen_at.to_f, 5
  end

  test "[unit] a first-time evolution (TaskEvent snapshot) counts as the newest unique" do
    larvitar = Pokemon.create!(dex: 246, name: "Larvitar", slug: "larvitar", generation: 2)
    pupitar = Pokemon.create!(dex: 247, name: "Pupitar", slug: "pupitar", generation: 2)

    SessionMascot.create!(session_id: "s-lv", mascot_slug: larvitar.slug,
                          created_at: 2.hours.ago, updated_at: 2.hours.ago)
    task = Task.create!(title: "Order Session Filter Recency",
                        metadata: { "devops" => { "mascot" => larvitar.slug } })
    # The submitted-gate evolution: larvitar -> pupitar, recorded on the task's spine.
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 30.minutes.ago, metadata: { "mascot" => { "slug" => pupitar.slug } })

    pokedex = PokemonPokedex.new

    assert_equal pupitar, pokedex.newest_unique.pokemon
    assert_equal task, pokedex.newest_unique.task
    assert_in_delta 30.minutes.ago.to_f, pokedex.newest_unique.first_seen_at.to_f, 5
  end

  test "[unit] newest unique shiny tracks the first SHINY sighting across spawns and evolutions" do
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1)
    eevee = Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", generation: 1)
    pupitar = Pokemon.create!(dex: 247, name: "Pupitar", slug: "pupitar", generation: 2)

    SessionMascot.create!(session_id: "s-pk", mascot_slug: pikachu.slug, shiny: true,
                          created_at: 3.hours.ago, updated_at: 3.hours.ago)
    # A newer NON-shiny spawn must not touch the shiny card.
    SessionMascot.create!(session_id: "s-ev", mascot_slug: eevee.slug, shiny: false,
                          created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    # A shiny evolution snapshot (orphan task_slug keeps the fixture free of a
    # genesis event) — the most recent FIRST shiny sighting.
    TaskEvent.create!(task_slug: "ghost-task", from_stage: "building", to_stage: "submitted",
                      occurred_at: 1.hour.ago, metadata: { "mascot" => { "slug" => pupitar.slug, "shiny" => "true" } })

    pokedex = PokemonPokedex.new

    assert_equal eevee, pokedex.newest_unique.pokemon, "the non-shiny card still tracks all sightings"
    assert_equal pupitar, pokedex.newest_unique_shiny.pokemon
    assert pokedex.newest_unique_shiny.shiny
  end

  test "[unit] newest unique can also be the newest shiny" do
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1)
    SessionMascot.create!(session_id: "s-shiny", mascot_slug: pikachu.slug, shiny: true)

    pokedex = PokemonPokedex.new

    assert_equal pikachu, pokedex.newest_unique.pokemon
    assert_equal pikachu, pokedex.newest_unique_shiny.pokemon
  end

  test "[unit] seen counts distinct species, not raw draws" do
    snorlax = Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1)
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1)
    SessionMascot.create!(session_id: "a", mascot_slug: snorlax.slug, created_at: 2.days.ago, updated_at: 2.days.ago)
    # A REPEAT Snorlax draw must not double-count the species.
    SessionMascot.create!(session_id: "b", mascot_slug: snorlax.slug, created_at: 1.day.ago, updated_at: 1.day.ago)
    SessionMascot.create!(session_id: "c", mascot_slug: pikachu.slug, shiny: true, created_at: 1.hour.ago, updated_at: 1.hour.ago)

    pokedex = PokemonPokedex.new

    assert_equal 2, pokedex.seen_pokemon
    assert_equal 1, pokedex.seen_pokemon(shiny: true) # only Pikachu came up shiny
  end

  test "[unit] catching counts a shipped mascot plus all its pre-evolutions" do
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", generation: 1,
                    base: "charmander", evolution: ["charmeleon"])
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon", generation: 1,
                    base: "charmander", evolution: ["charizard"])
    charizard = Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", generation: 1,
                                base: "charmander", evolution: [])
    Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1) # never shipped

    task = Task.create!(title: "Ship The Charizard Line",
                        metadata: { "devops" => { "mascot" => charizard.slug } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 10.minutes.ago, metadata: { "mascot" => { "slug" => charizard.slug } })

    pokedex = PokemonPokedex.new

    # Final form + both pre-evolutions; Pikachu is not caught.
    assert_equal 3, pokedex.caught_pokemon
    assert_equal charizard, pokedex.newest_caught.pokemon
    assert_equal task, pokedex.newest_caught.task
    assert_in_delta 10.minutes.ago.to_f, pokedex.newest_caught.first_seen_at.to_f, 5
  end

  test "[unit] only a shipped transition catches — a submitted mascot is not caught" do
    bulbasaur = Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", generation: 1,
                                base: "bulbasaur", evolution: [])
    task = Task.create!(title: "Not Shipped Yet",
                        metadata: { "devops" => { "mascot" => bulbasaur.slug } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.minutes.ago, metadata: { "mascot" => { "slug" => bulbasaur.slug } })

    pokedex = PokemonPokedex.new

    assert_equal 0, pokedex.caught_pokemon
    assert_nil pokedex.newest_caught
  end

  test "[unit] shiny caught is scoped to shiny ships and still propagates to the line" do
    Pokemon.create!(dex: 7, name: "Squirtle", slug: "squirtle", generation: 1,
                    base: "squirtle", evolution: ["wartortle"])
    Pokemon.create!(dex: 8, name: "Wartortle", slug: "wartortle", generation: 1,
                    base: "squirtle", evolution: ["blastoise"])
    blastoise = Pokemon.create!(dex: 9, name: "Blastoise", slug: "blastoise", generation: 1,
                                base: "squirtle", evolution: [])
    Pokemon.create!(dex: 92, name: "Gastly", slug: "gastly", generation: 1,
                    base: "gastly", evolution: ["haunter"])
    Pokemon.create!(dex: 93, name: "Haunter", slug: "haunter", generation: 1,
                    base: "gastly", evolution: ["gengar"])
    gengar = Pokemon.create!(dex: 94, name: "Gengar", slug: "gengar", generation: 1,
                             base: "gastly", evolution: [])

    shiny_ship = Task.create!(title: "Ship Shiny Blastoise",
                              metadata: { "devops" => { "mascot" => blastoise.slug, "mascot_shiny" => true } })
    TaskEvent.create!(task_slug: shiny_ship.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 20.minutes.ago, metadata: { "mascot" => { "slug" => blastoise.slug, "shiny" => true } })
    plain_ship = Task.create!(title: "Ship Plain Gengar",
                              metadata: { "devops" => { "mascot" => gengar.slug } })
    TaskEvent.create!(task_slug: plain_ship.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 10.minutes.ago, metadata: { "mascot" => { "slug" => gengar.slug } })

    pokedex = PokemonPokedex.new

    assert_equal 6, pokedex.caught_pokemon               # both lines caught
    assert_equal 3, pokedex.caught_pokemon(shiny: true)  # only the Squirtle line, shiny
    assert_equal blastoise, pokedex.newest_caught_shiny.pokemon
    assert pokedex.newest_caught_shiny.shiny
    assert_equal gengar, pokedex.newest_caught.pokemon, "newest overall catch is the later plain ship"
  end
end
