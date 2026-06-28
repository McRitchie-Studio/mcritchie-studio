require "test_helper"

# Component tier: the board renders an app-filter chip per distinct repo present,
# wired to the Alpine toggle, and every card carries its repos + the combined
# agent/app visibility gate. (The interactive hide/show is the system test.)
class BoardAppFilterTest < ActionDispatch::IntegrationTest
  test "deployments renders an app-filter chip per present app, wired to toggleApp" do
    rolio = Task.create!(
      title: "rolio filter chip task",
      stage: "designed",
      metadata: { "devops" => { "repositories" => ["rolio"] } }
    )
    Task.create!(
      title: "turf filter chip task",
      stage: "building",
      metadata: { "devops" => { "repositories" => ["turf-monster"] } }
    )

    get deployments_path
    assert_response :success

    # Wiring: each present app gets a chip that toggles + greys via the Alpine
    # state. (Asserted on the raw body — libxml2 won't expose the `@click` name.)
    assert_includes response.body, "toggleApp('rolio')"
    assert_includes response.body, "toggleApp('turf-monster')"
    assert_includes response.body, "appHidden('rolio')"

    # Chip content: select by the readable `:class` binding, then check label/emoji.
    doc   = Nokogiri::HTML(@response.body)
    chips = doc.css("button").select { |b| b[":class"].to_s.include?("appHidden(") }
    apps  = chips.map { |b| b[":class"][/appHidden\('([^']+)'\)/, 1] }
    assert_includes apps, "rolio"
    assert_includes apps, "turf-monster"

    rolio_chip = chips.find { |b| b[":class"].include?("appHidden('rolio')") }
    assert_includes rolio_chip.text.strip, "rolio"
    assert_includes rolio_chip.text, "📇"

    # Known app slugs map to their ecosystem emoji.
    turf_chip = chips.find { |b| b[":class"].include?("appHidden('turf-monster')") }
    assert_includes turf_chip.text, "🐊"

    # The card carries its repos + the combined agent/app x-show gate.
    card = doc.at_css("#card-#{rolio.slug}")
    assert_equal "rolio", card["data-apps"]
    assert_includes card["x-show"].to_s, "appVisible('rolio')"
    assert_includes card["x-show"].to_s, "matchesFilter("
  end

  test "a task with no mapped repo carries an empty data-apps (always visible)" do
    bare = Task.create!(title: "no repo board task", stage: "designed")

    get deployments_path
    assert_response :success
    doc = Nokogiri::HTML(@response.body)

    card = doc.at_css("#card-#{bare.slug}")
    assert_equal "", card["data-apps"]
    # appVisible('') short-circuits to true, so a no-repo card never hides.
    assert_includes card["x-show"].to_s, "appVisible('')"
  end
end
