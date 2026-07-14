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

    # Assert Seen and Caught TOGETHER. This fixture has no spawns at all, so before
    # catches counted as sightings the shiny card rendered the impossible
    # "Seen 1 · Caught 3". A catch is an encounter: the whole caught line is seen.
    assert_equal 6, pokedex.seen_pokemon
    assert_equal 3, pokedex.seen_pokemon(shiny: true)
    assert_operator pokedex.seen_pokemon, :>=, pokedex.caught_pokemon
    assert_operator pokedex.seen_pokemon(shiny: true), :>=, pokedex.caught_pokemon(shiny: true)
  end

  # The dex invariant, pinned on its own: you cannot catch what you never encountered.
  # Caught expands through the lineage walk while Seen credits only real sightings, so
  # without folding catches into sightings these two public numbers can contradict.
  test "[unit] Seen is never less than Caught, even with no spawns at all" do
    Pokemon.create!(dex: 152, name: "Chikorita", slug: "chikorita", generation: 2,
                    base: "chikorita", evolution: ["bayleef"])
    Pokemon.create!(dex: 153, name: "Bayleef", slug: "bayleef", generation: 2,
                    base: "chikorita", evolution: ["meganium"])
    meganium = Pokemon.create!(dex: 154, name: "Meganium", slug: "meganium", generation: 2,
                               base: "chikorita", evolution: [])

    # One shiny ship of a stage-3 form. No SessionMascot rows anywhere.
    ship = Task.create!(title: "Ship Shiny Meganium",
                        metadata: { "devops" => { "mascot" => meganium.slug, "mascot_shiny" => true } })
    TaskEvent.create!(task_slug: ship.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 5.minutes.ago,
                      metadata: { "mascot" => { "slug" => meganium.slug, "shiny" => true } })

    pokedex = PokemonPokedex.new

    assert_equal 3, pokedex.caught_pokemon
    assert_equal 3, pokedex.seen_pokemon, "the caught line is encountered, not just caught"
    assert_equal 3, pokedex.caught_pokemon(shiny: true)
    assert_equal 3, pokedex.seen_pokemon(shiny: true)
    # A caught-but-never-spawned species still has a sensible newest-seen entry.
    assert_equal meganium, pokedex.newest_unique.pokemon
  end

  # devops.mascot_shiny is the least controlled shiny representation — it has held
  # true, "true", and "1". A raw == "true" silently undercounts shiny Caught on the
  # fallback path, which is the DOMINANT path for older ships.
  test "[unit] the task-mascot fallback honors every shiny representation" do
    %w[pikachu raichu].each_with_index do |slug, i|
      Pokemon.create!(dex: 25 + i, name: slug.capitalize, slug: slug, generation: 1,
                      base: slug, evolution: [])
    end

    ["1", "true", true].each_with_index do |shiny_repr, i|
      task = Task.create!(title: "Ship Shiny Repr #{i}",
                          metadata: { "devops" => { "mascot" => "pikachu", "mascot_shiny" => shiny_repr } })
      # No snapshot on the event: forces the devops.mascot_shiny fallback.
      TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                        occurred_at: (i + 1).minutes.ago, metadata: {})

      assert_equal 1, PokemonPokedex.new.caught_pokemon(shiny: true),
                   "mascot_shiny #{shiny_repr.inspect} must count as shiny"
      Task.where(slug: task.slug).destroy_all
      TaskEvent.where(task_slug: task.slug).destroy_all
    end
  end

  # The linear-line tests above pass even with a naive "slice the flattened family"
  # lineage. A BRANCHING line is what catches that bug: Eevee splits five ways, so a
  # branch tip must catch its ancestors and NONE of its siblings.
  test "[unit] catching a branch tip catches its ancestors, never its siblings" do
    Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", generation: 1, base: "eevee",
                    evolution: %w[vaporeon jolteon flareon espeon umbreon])
    Pokemon.create!(dex: 134, name: "Vaporeon", slug: "vaporeon", generation: 1, base: "eevee", evolution: [])
    Pokemon.create!(dex: 135, name: "Jolteon", slug: "jolteon", generation: 1, base: "eevee", evolution: [])
    Pokemon.create!(dex: 136, name: "Flareon", slug: "flareon", generation: 1, base: "eevee", evolution: [])
    Pokemon.create!(dex: 196, name: "Espeon", slug: "espeon", generation: 2, base: "eevee", evolution: [])
    umbreon = Pokemon.create!(dex: 197, name: "Umbreon", slug: "umbreon", generation: 2, base: "eevee", evolution: [])

    task = Task.create!(title: "Ship The Umbreon Branch",
                        metadata: { "devops" => { "mascot" => umbreon.slug } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 5.minutes.ago, metadata: { "mascot" => { "slug" => umbreon.slug } })

    pokedex = PokemonPokedex.new

    assert_equal %w[eevee umbreon], pokedex.send(:caught_slugs).to_a.sort,
                 "a branch tip catches only its ancestor line — never its sibling Eeveelutions"
    assert_equal 2, pokedex.caught_pokemon
    assert_equal umbreon, pokedex.newest_caught.pokemon
  end

  # Most shipped rows on the board predate the mascot snapshot. TaskEvent#mascot_snapshot
  # documents the contract — "readers should fall back to the task's current mascot" —
  # and the task keeps devops.mascot forever, so ignoring it would derive the headline
  # Caught number from only the minority of ships that carry a snapshot.
  test "[unit] a shipped event with no mascot snapshot falls back to the task's mascot" do
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", generation: 1,
                    base: "bulbasaur", evolution: ["ivysaur"])
    Pokemon.create!(dex: 2, name: "Ivysaur", slug: "ivysaur", generation: 1,
                    base: "bulbasaur", evolution: ["venusaur"])
    venusaur = Pokemon.create!(dex: 3, name: "Venusaur", slug: "venusaur", generation: 1,
                               base: "bulbasaur", evolution: [])

    task = Task.create!(title: "Older Ship No Snapshot",
                        metadata: { "devops" => { "mascot" => venusaur.slug } })
    # An OLDER shipped row: no metadata.mascot on the event itself.
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 15.minutes.ago, metadata: {})

    pokedex = PokemonPokedex.new

    assert_equal %w[bulbasaur ivysaur venusaur], pokedex.send(:caught_slugs).to_a.sort,
                 "the task's own mascot backfills the missing snapshot, line and all"
    assert_equal 3, pokedex.caught_pokemon
    assert_equal venusaur, pokedex.newest_caught.pokemon
  end

  test "[unit] a snapshot on the shipped event wins over the task's current mascot" do
    snapshotted = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1,
                                  base: "pikachu", evolution: [])
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                    base: "snorlax", evolution: [])
    # The task's mascot has since recycled to Snorlax, but the event froze Pikachu —
    # the snapshot is what the task actually shipped, so it must win.
    task = Task.create!(title: "Shipped As Pikachu",
                        metadata: { "devops" => { "mascot" => "snorlax" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 5.minutes.ago, metadata: { "mascot" => { "slug" => snapshotted.slug } })

    pokedex = PokemonPokedex.new

    assert_equal ["pikachu"], pokedex.send(:caught_slugs).to_a
    assert_equal snapshotted, pokedex.newest_caught.pokemon
  end

  # Every real task gets a mascot on create, so the fallback recovers nearly every
  # older ship. The genuinely unrecoverable row is a backfill-synthesized one whose
  # task no longer resolves — it must drop out silently, not raise on a public page.
  test "[unit] a ship with neither a snapshot nor a resolvable task is skipped cleanly" do
    Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1, base: "pikachu", evolution: [])
    TaskEvent.create!(task_slug: "ghost-task", from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 5.minutes.ago, metadata: { "backfilled" => true })

    pokedex = PokemonPokedex.new

    assert_equal 0, pokedex.caught_pokemon
    assert_nil pokedex.newest_caught
  end

  # THE GRID. Its three states are the two card numbers, per species — so they must be
  # derived from the same sets, and the caught-before-seen order is load-bearing: a
  # catch IS a sighting, so every caught species is also in seen_slugs and would
  # render as merely "seen" if :seen were tested first.
  test "[unit] dex entries carry each species' collection state, in dex order" do
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", generation: 1,
                    base: "charmander", evolution: ["charmeleon"])
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon", generation: 1,
                    base: "charmander", evolution: ["charizard"])
    charizard = Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", generation: 1,
                                base: "charmander", evolution: [])
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1)
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1) # never touched

    # Pikachu was only ever SPAWNED — seen, not caught.
    SessionMascot.create!(session_id: "s-pika", mascot_slug: pikachu.slug)
    # A shipped task CATCHES the Charizard line: final form + both pre-evolutions.
    ship = Task.create!(title: "Ship Charizard Line",
                        metadata: { "devops" => { "mascot" => charizard.slug } })
    TaskEvent.create!(task_slug: ship.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 5.minutes.ago, metadata: { "mascot" => { "slug" => charizard.slug } })

    entries = PokemonPokedex.new.dex_entries

    assert_equal [4, 5, 6, 25, 143], entries.map { |entry| entry.pokemon.dex }, "dex order"
    assert_equal({ "charmander" => :caught, "charmeleon" => :caught, "charizard" => :caught,
                   "pikachu" => :seen, "snorlax" => :unseen },
                 entries.to_h { |entry| [entry.pokemon.slug, entry.state] })

    # The caught line is SEEN too (the dex invariant) — it must still read as caught.
    caught = entries.find { |entry| entry.pokemon.slug == "charizard" }
    assert caught.caught?
    assert caught.revealed?
    assert_not caught.unseen?

    unseen = entries.find { |entry| entry.pokemon.slug == "snorlax" }
    assert unseen.unseen?
    assert_not unseen.revealed?, "an unseen species is inert — no shiny flip"
  end

  test "[unit] every entry state is one the grid can draw, and each species appears once" do
    3.times { |i| Pokemon.create!(dex: i + 1, name: "Mon#{i}", slug: "mon-#{i}", generation: 1) }
    SessionMascot.create!(session_id: "s", mascot_slug: "mon-1")

    entries = PokemonPokedex.new.dex_entries

    assert_equal Pokemon.count, entries.size, "one cell per seeded species"
    assert_equal entries.map { |entry| entry.pokemon.slug }.uniq.size, entries.size, "no species twice"
    assert_equal [], entries.map(&:state) - %i[caught seen unseen], "no state the grid cannot draw"
  end

  # The evolution circles are resolved off the in-memory dex, never Pokemon#evolutions
  # (which queries per cell — 251 of them on a public page). They carry ENTRIES, not
  # bare Pokémon, so each circle can be drawn in its own state.
  test "[unit] dex entries link the line ahead as entries, in their own states" do
    Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", generation: 1, base: "eevee",
                    evolution: %w[vaporeon jolteon])
    Pokemon.create!(dex: 134, name: "Vaporeon", slug: "vaporeon", generation: 1, base: "eevee", evolution: [])
    Pokemon.create!(dex: 135, name: "Jolteon", slug: "jolteon", generation: 1, base: "eevee", evolution: [])

    # Vaporeon is seen; Jolteon has never been met.
    SessionMascot.create!(session_id: "s-vap", mascot_slug: "vaporeon")

    entries = PokemonPokedex.new.dex_entries.index_by { |entry| entry.pokemon.slug }

    assert_equal %w[vaporeon jolteon], entries["eevee"].evolutions.map { |evo| evo.pokemon.slug }
    assert_equal %i[seen unseen], entries["eevee"].evolutions.map(&:state),
                 "each circle carries its OWN state — a caught cell never spoils an unmet next form"
    assert_empty entries["vaporeon"].evolutions, "a final form has no line ahead"
  end

  test "[unit] a species sighted shiny is flagged shiny_seen" do
    Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1)
    Pokemon.create!(dex: 133, name: "Eevee", slug: "eevee", generation: 1)

    SessionMascot.create!(session_id: "s-shiny", mascot_slug: "pikachu", shiny: true)
    SessionMascot.create!(session_id: "s-plain", mascot_slug: "eevee", shiny: false)

    entries = PokemonPokedex.new.dex_entries.index_by { |entry| entry.pokemon.slug }

    assert entries["pikachu"].shiny_seen
    assert_not entries["eevee"].shiny_seen
  end

  test "[unit] a newer ship with a non-Pokemon mascot never blanks the caught card" do
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1,
                              base: "pikachu", evolution: [])
    real = Task.create!(title: "Ship A Real Pokemon",
                        metadata: { "devops" => { "mascot" => pikachu.slug } })
    TaskEvent.create!(task_slug: real.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 30.minutes.ago, metadata: { "mascot" => { "slug" => pikachu.slug } })
    # A LATER ship carrying a persona mascot must be SKIPPED, not win the max and
    # blank the card to "None caught yet" while a real catch sits behind it.
    persona = Task.create!(title: "Ship With Persona Mascot",
                           metadata: { "devops" => { "mascot" => "avi" } })
    TaskEvent.create!(task_slug: persona.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.minute.ago, metadata: { "mascot" => { "slug" => "avi" } })

    pokedex = PokemonPokedex.new

    assert_equal pikachu, pokedex.newest_caught.pokemon
    assert_equal 1, pokedex.caught_pokemon
  end
end
