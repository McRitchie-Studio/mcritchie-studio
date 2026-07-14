require "test_helper"

class PokemonControllerTest < ActionDispatch::IntegrationTest
  # Every SQL call the page makes, schema/transaction bookkeeping aside. CACHE hits
  # are COUNTED, deliberately: Rails' per-request query cache collapses a repeated
  # identical query, so excluding them would hide an N+1 whose rows happen to ask the
  # same question — which is exactly the N+1 this page invites (many species sharing
  # one evolution target).
  def count_pokedex_queries
    queries = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      queries += 1 unless payload[:name].in?(["SCHEMA", "TRANSACTION"])
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get pokedex_path }
    assert_response :success
    queries
  end

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
      assert_select "h2", "Shiny Pokémon"
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

  test "[component] the collection grid draws every species in its state" do
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", generation: 1,
                    base: "charmander", evolution: ["charmeleon"],
                    avatar_url: "https://example.test/charmander.png",
                    sprite_url: "https://example.test/charmander-sprite.png")
    Pokemon.create!(dex: 5, name: "Charmeleon", slug: "charmeleon", generation: 1,
                    base: "charmander", evolution: [],
                    avatar_url: "https://example.test/charmeleon.png",
                    sprite_url: "https://example.test/charmeleon-sprite.png")
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1,
                              base: "pikachu", evolution: ["raichu"],
                              avatar_url: "https://example.test/pikachu.png",
                              shiny_avatar_url: "https://example.test/pikachu-shiny.png",
                              sprite_url: "https://example.test/pikachu-sprite.png")
    Pokemon.create!(dex: 26, name: "Raichu", slug: "raichu", generation: 1, base: "pikachu",
                    avatar_url: "https://example.test/raichu.png",
                    sprite_url: "https://example.test/raichu-sprite.png")
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                    avatar_url: "https://example.test/snorlax.png",
                    sprite_url: "https://example.test/snorlax-sprite.png")

    # Pikachu is SEEN (a shiny spawn). The Charmander line is CAUGHT (a ship, which
    # sweeps in the pre-evolution). Snorlax has never been met.
    SessionMascot.create!(session_id: "s-pika", mascot_slug: pikachu.slug, shiny: true)
    ship = Task.create!(title: "Ship Charmeleon Line",
                        metadata: { "devops" => { "mascot" => "charmeleon" } })
    TaskEvent.create!(task_slug: ship.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 5.minutes.ago, metadata: { "mascot" => { "slug" => "charmeleon" } })

    get pokedex_path

    assert_response :success
    assert_select "[data-test=dex-grid]"
    assert_select "[data-test=dex-cell]", 5, "one cell per seeded species"

    # The states, per species — the grid's whole job.
    assert_select "[data-test=dex-cell][data-slug=charmander][data-state=caught]"
    assert_select "[data-test=dex-cell][data-slug=charmeleon][data-state=caught]"
    assert_select "[data-test=dex-cell][data-slug=pikachu][data-state=seen]"
    assert_select "[data-test=dex-cell][data-slug=snorlax][data-state=unseen]"

    # A catch also gets a literal mark; only the caught cells wear one.
    assert_select "[data-test=dex-caught-mark]", 2

    assert_select "[data-test=dex-cell][data-slug=pikachu]" do
      assert_select "[data-test=dex-shiny-toggle]", 1, "a seen species can be flipped shiny"
      assert_select "img[src=?]", "https://example.test/pikachu-shiny.png"
      assert_select "[data-test=dex-cell] > div", /✨/, "its first sighting came up shiny"
    end

    # An unseen species is INERT: no flip, and no shiny asset fetched for a silhouette.
    assert_select "[data-test=dex-cell][data-slug=snorlax]" do
      assert_select "[data-test=dex-shiny-toggle]", false
      assert_select "img.dex-art-unseen", 1
    end

    # The line ahead rides on the cell — but only the forms already MET. Charmeleon is
    # caught, so Charmander wears it; Raichu has never been seen, so Pikachu wears
    # nothing rather than a silhouetted blob that reveals a form you have not met.
    assert_select "[data-test=dex-cell][data-slug=charmander] [data-test=dex-evolution-circle]", 1
    assert_select "[data-test=dex-cell][data-slug=pikachu] [data-test=dex-evolution-circle]", false
    assert_select "[data-test=dex-cell][data-slug=charmeleon] [data-test=dex-evolution-circle]", false

    # The legend counts CELLS, so its three numbers partition the dex. "Seen only" is
    # the remainder after the caught ones are drawn in their own state — the card above
    # counts 3 species SEEN (the caught line is seen too), and the same word carrying
    # two different numbers on one page is exactly the confusion the label heads off.
    assert_select "[data-test=pokemon-seen]", "3"
    assert_select "[data-test=dex-legend]", /Caught\s*2/
    assert_select "[data-test=dex-legend]", /Seen only\s*1/  # pikachu — spawned, never shipped
    assert_select "[data-test=dex-legend]", /Not seen\s*2/   # raichu + snorlax
  end

  # The grid renders a cell per species, each with artwork and evolution circles — the
  # exact shape that invites an N+1 (Pokemon#evolutions queries per cell). Asserting a
  # fixed query count would just pin today's number; the PROPERTY that matters is that
  # the count cannot grow with the dex. So: hold the sightings fixed, add ten times the
  # species, and demand the same number of queries.
  test "[integration] the pokedex query count does not grow with the size of the dex" do
    pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1,
                              base: "pikachu", evolution: ["raichu"],
                              sprite_url: "https://example.test/pikachu-sprite.png")
    Pokemon.create!(dex: 26, name: "Raichu", slug: "raichu", generation: 1,
                    base: "pikachu", sprite_url: "https://example.test/raichu-sprite.png")
    SessionMascot.create!(session_id: "s-pika", mascot_slug: pikachu.slug)

    get pokedex_path # warm up: first-request loads (schema, translations) are not the subject
    small_dex = count_pokedex_queries

    # Ten more species, each with a line ahead of it. No new sightings — every one is
    # an UNSEEN cell, which still renders artwork and circles.
    #
    # Each evolves into its OWN distinct form. A shared evolution target would make
    # every per-species lookup the SAME query, and Rails' query cache would fold ten
    # N+1 calls into one — a fixture that lets the bug through.
    10.times do |i|
      Pokemon.create!(dex: 200 + i, name: "Evo#{i}", slug: "evo-#{i}", generation: 1,
                      base: "filler-#{i}", sprite_url: "https://example.test/evo-#{i}.png")
      Pokemon.create!(dex: 100 + i, name: "Filler#{i}", slug: "filler-#{i}", generation: 1,
                      base: "filler-#{i}", evolution: ["evo-#{i}"],
                      sprite_url: "https://example.test/filler-#{i}.png")
    end

    get pokedex_path
    large_dex = count_pokedex_queries

    assert_operator Pokemon.count, :>, 10, "the dex actually grew"
    assert_equal small_dex, large_dex,
                 "the grid must project the memos the cards already built — a per-species query is an N+1"
  end

  test "[component] empty pokedex renders stable empty states" do
    get pokedex_path

    assert_response :success
    # With no shiny data there are no sparkles, so the TITLES must still tell the two
    # cards apart — the sparkles alone are not a durable distinction.
    assert_select "[data-test=pokemon-card] h2", "Pokémon"
    assert_select "[data-test=shiny-card] h2", "Shiny Pokémon"
    assert_select "[data-test=shiny-sparkle]", false, "no shiny data means no sparkles to lean on"
    assert_select "[data-test=pokemon-newest-seen-empty]", "None seen yet."
    assert_select "[data-test=pokemon-newest-caught-empty]", "None caught yet."
    assert_select "[data-test=shiny-newest-seen-empty]", "None seen yet."
    assert_select "[data-test=shiny-newest-caught-empty]", "None caught yet."
    assert_select "[data-test=recent-pokemon-empty]", "No Pokémon actions yet."
  end
end
