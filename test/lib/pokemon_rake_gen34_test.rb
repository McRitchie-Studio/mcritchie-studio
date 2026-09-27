require "test_helper"
require "rake"

# [unit] The Gen 3–4 extension of lib/tasks/pokemon.rake (tasks/pokemon-gen-3-and-4):
# the dex and generation ranges, the family walk that lets Gen 4 extend Gen 1–2
# lines and seat new babies on old bases, the gender gates derived from PokéAPI's
# evolution chains, the retrying PokéAPI read, and the additive image plumbing
# that never leaves a JSON URL pointing at a key that was never uploaded. The rake
# file defines its helpers as private methods on the top-level object, so they
# are reached with `send` on a plain Object.
class PokemonRakeGen34Test < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pokemon:fetch")
    @rake = Object.new
  end

  def row(dex, slug, **extra)
    { "dex" => dex, "slug" => slug, "name" => slug.capitalize }.merge(extra)
  end

  # A pokemon-species record as PokéAPI shapes the fields the walk reads.
  def species(from: nil, baby: false, gender_rate: 4, differs: false)
    { "is_baby" => baby, "gender_rate" => gender_rate, "has_gender_differences" => differs,
      "evolves_from_species" => (from && { "url" => "https://pokeapi.co/api/v2/pokemon-species/#{from}/" }) }
  end

  # --- ranges -----------------------------------------------------------------

  test "the dex range covers Gen 1-4 and every dex has a generation" do
    assert_equal (1..493), DEX_RANGE
    assert_equal [1, 1, 2, 2, 3, 3, 4, 4], [1, 151, 152, 251, 252, 386, 387, 493].map { |dex| @rake.send(:generation_for, dex) }
    assert_raises(ArgumentError) { @rake.send(:generation_for, 494) }
  end

  test "RANGE narrows the slice and the default is the full dex" do
    ENV.delete("RANGE")
    assert_equal (1..493), @rake.send(:dex_range)
    ENV["RANGE"] = "252-493"
    assert_equal (252..493), @rake.send(:dex_range)
  ensure
    ENV.delete("RANGE")
  end

  # --- the family walk ----------------------------------------------------------

  test "a Gen 4 evolution extends a Gen 1-2 line and keeps its baby on the base" do
    rows = [row(125, "electabuzz"), row(239, "elekid"), row(466, "electivire")]
    by_dex = { 125 => species(from: 239), 239 => species(baby: true), 466 => species(from: 125) }
    @rake.send(:stamp_family_fields, rows, by_dex)
    by = rows.index_by { |r| r["slug"] }

    assert_equal ["electivire"], by["electabuzz"]["evolution"]
    assert_equal %w[electabuzz electabuzz electabuzz], by.values_at("electabuzz", "elekid", "electivire").map { |r| r["base"] }
    assert_equal ["elekid"], by["electabuzz"]["baby"]
  end

  test "a new baby hands the crown to its one heir, even an older species" do
    rows = [row(143, "snorlax"), row(446, "munchlax"), row(447, "riolu"), row(448, "lucario")]
    by_dex = { 143 => species(from: 446), 446 => species(baby: true), 447 => species(baby: true),
               448 => species(from: 447) }
    @rake.send(:stamp_family_fields, rows, by_dex)
    by = rows.index_by { |r| r["slug"] }

    assert_equal "snorlax", by["munchlax"]["base"]
    assert_equal ["munchlax"], by["snorlax"]["baby"]
    assert_equal "lucario", by["riolu"]["base"]
    assert_equal ["riolu"], by["lucario"]["baby"]
  end

  # NOT_BABY keeps Togepi a spawnable root; with Togekiss present that root is a
  # three-stage line. Were Togepi demoted, Togetic would become the base.
  test "togepi stays a base and roots a three-stage line once togekiss exists" do
    rows = [row(175, "togepi"), row(176, "togetic"), row(468, "togekiss")]
    by_dex = { 175 => species(baby: true), 176 => species(from: 175), 468 => species(from: 176) }
    @rake.send(:stamp_family_fields, rows, by_dex)
    by = rows.index_by { |r| r["slug"] }

    assert_equal %w[togepi togepi togepi], by.values_at("togepi", "togetic", "togekiss").map { |r| r["base"] }
    assert_equal ["togekiss"], by["togetic"]["evolution"]
    assert_empty by["togetic"]["baby"]
  end

  test "the walk stamps female sprite URLs only for a species with a female look" do
    rows = [row(415, "combee"), row(416, "vespiquen")]
    by_dex = { 415 => species(gender_rate: 1, differs: true), 416 => species(from: 415, gender_rate: 8) }
    @rake.send(:stamp_family_fields, rows, by_dex)
    by = rows.index_by { |r| r["slug"] }

    assert by["combee"]["female_sprite_url"].end_with?("/415-combee-female-sprite.png")
    assert by["combee"]["shiny_female_sprite_url"].end_with?("/415-combee-shiny-female-sprite.png")
    assert_nil by["vespiquen"]["female_sprite_url"]
    assert_equal 8, by["vespiquen"]["gender_rate"]
  end

  # --- gender gates from the evolution chains ----------------------------------

  def link(name, gender: nil, evolves_to: [], details: nil)
    { "species" => { "name" => name },
      "evolution_details" => details || [{ "gender" => gender, "trigger" => { "name" => "level-up" } }],
      "evolves_to" => evolves_to }
  end

  def ralts_chain
    { "chain" => link("ralts", evolves_to: [
                        link("kirlia", evolves_to: [link("gardevoir"), link("gallade", gender: 2)])
                      ]) }
  end

  test "derive_evolution_genders reads PokéAPI's gender codes off the chain" do
    combee = { "chain" => link("combee", evolves_to: [link("vespiquen", gender: 1)]) }

    assert_equal({ "kirlia" => { "gallade" => "male" }, "combee" => { "vespiquen" => "female" } },
                 @rake.send(:derive_evolution_genders, [ralts_chain, combee]))
  end

  test "a link that some route takes without a gender is not gated" do
    mixed = [{ "gender" => 1 }, { "gender" => nil }]
    chain = { "chain" => link("snorunt", evolves_to: [link("froslass", details: mixed)]) }

    assert_empty @rake.send(:derive_evolution_genders, [chain])
  end

  test "check_evolution_genders passes when PokéAPI agrees with the reviewed rules" do
    rows = %w[ralts kirlia gardevoir gallade snorunt glalie froslass burmy wormadam mothim combee vespiquen]
           .each_with_index.map { |slug, i| row(i + 1, slug) }
    derived = { "kirlia" => { "gallade" => "male" }, "snorunt" => { "froslass" => "female" },
                "burmy" => { "wormadam" => "female", "mothim" => "male" }, "combee" => { "vespiquen" => "female" } }

    assert_nil @rake.send(:check_evolution_genders, rows, derived)
  end

  test "check_evolution_genders aborts the fetch on a gate the rules do not name" do
    rows = %w[kirlia gallade eevee leafeon].each_with_index.map { |slug, i| row(i + 1, slug) }
    derived = { "kirlia" => { "gallade" => "male" }, "eevee" => { "leafeon" => "female" } }

    error = assert_raises(RuntimeError) { @rake.send(:check_evolution_genders, rows, derived) }
    assert_match "leafeon", error.message
    # …and on a reviewed gate PokéAPI no longer reports.
    assert_raises(RuntimeError) { @rake.send(:check_evolution_genders, rows, {}) }
  end

  test "check_evolution_genders ignores rules whose rows are out of range" do
    rows = [row(1, "kirlia"), row(2, "gardevoir")] # no Gallade in this slice

    assert_nil @rake.send(:check_evolution_genders, rows, {})
  end

  # --- the retrying PokéAPI read -------------------------------------------------

  def response(klass, code, body: "{}", headers: {})
    klass.new("1.1", code, "x").tap do |res|
      headers.each { |key, value| res[key] = value }
      res.instance_variable_set(:@read, true)
      res.instance_variable_set(:@body, body)
    end
  end

  def with_responses(*responses, &block)
    pauses = []
    queue = responses.dup
    @rake.stub(:retry_pause, ->(seconds) { pauses << seconds }) do
      Net::HTTP.stub(:get_response, ->(*) { queue.shift }, &block)
    end
    pauses
  end

  test "get_json retries a 429 and a 503, honouring Retry-After" do
    result = nil
    pauses = with_responses(response(Net::HTTPTooManyRequests, "429", headers: { "retry-after" => "7" }),
                            response(Net::HTTPServiceUnavailable, "503"),
                            response(Net::HTTPOK, "200", body: '{"name":"kirlia"}')) do
      result = @rake.send(:get_json, "https://pokeapi.test/pokemon/281")
    end

    assert_equal({ "name" => "kirlia" }, result)
    assert_equal [7, 4], pauses, "Retry-After wins over the 2s backoff; then 2**2"
  end

  test "get_json gives up after FETCH_ATTEMPTS and never retries a 404" do
    busy = Array.new(FETCH_ATTEMPTS) { response(Net::HTTPTooManyRequests, "429") }
    pauses = with_responses(*busy) do
      assert_raises(RuntimeError) { @rake.send(:get_json, "https://pokeapi.test/pokemon/1") }
    end
    assert_equal FETCH_ATTEMPTS - 1, pauses.size

    pauses = with_responses(response(Net::HTTPNotFound, "404")) do
      assert_raises(RuntimeError) { @rake.send(:get_json, "https://pokeapi.test/pokemon/9999") }
    end
    assert_empty pauses
  end

  test "pooled_map keeps the items' order" do
    assert_equal (1..20).map { |n| n * 2 }, @rake.send(:pooled_map, (1..20).to_a) { |n|
      sleep(0.001 * (20 - n))
      n * 2
    }
  end

  # --- images ----------------------------------------------------------------------

  test "image_sources adds the female pixel sprites only for a species with a female look" do
    plain = @rake.send(:image_sources, row(412, "burmy"), %w[normal shiny female])
    assert_equal %w[pokemon/412-burmy.png pokemon/412-burmy-sprite.png pokemon/412-burmy-shiny.png
                    pokemon/412-burmy-shiny-sprite.png], plain.keys
    assert_equal "#{SPRITE_CDN}/other/official-artwork/shiny/412.png", plain["pokemon/412-burmy-shiny.png"]

    female = @rake.send(:image_sources, row(415, "combee", "has_gender_differences" => true), %w[female])
    assert_equal({ "pokemon/415-combee-female-sprite.png" => "#{SPRITE_CDN}/female/415.png",
                   "pokemon/415-combee-shiny-female-sprite.png" => "#{SPRITE_CDN}/shiny/female/415.png" }, female)
  end

  test "prune_missing_urls blanks only the in-range URLs with no object" do
    base = "https://s3.test/pokemon"
    rows = [row(1, "bulbasaur", "shiny_avatar_url" => "#{base}/1-bulbasaur-shiny-cropped.png"),
            row(479, "rotom", "avatar_url" => "#{base}/479-rotom-cropped.png",
                              "shiny_avatar_url" => "#{base}/479-rotom-shiny-cropped.png",
                              "shiny_sprite_url" => "#{base}/479-rotom-shiny-sprite.png")]
    missing = ["#{base}/479-rotom-shiny-cropped.png", "#{base}/1-bulbasaur-shiny-cropped.png"]

    pruned = @rake.send(:prune_missing_urls, rows, (252..493)) { |url| !missing.include?(url) }

    assert_equal ["rotom.shiny_avatar_url"], pruned
    assert_nil rows[1]["shiny_avatar_url"]
    assert_equal "#{base}/479-rotom-shiny-sprite.png", rows[1]["shiny_sprite_url"], "a live key stays"
    assert rows[0]["shiny_avatar_url"].present?, "a row outside the range is never touched"
  end
end
