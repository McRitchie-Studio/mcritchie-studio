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
    filter_row = doc.at_css("[data-test='board-filter-row']")
    assert filter_row, "deployments should render the shared app filter row"

    # Placement DELIBERATELY REVERSED (operator request, 2026-07-27): the local
    # progression tester moved OUT of the app-filter row and UP beside the board's
    # own actions (New Task / Links), so a demo is driven from one row instead of
    # two. This assertion pair is the record of that decision, not a leftover.
    header_actions = doc.at_css("[data-test='board-header-actions']")
    assert header_actions, "the board header actions container should remain present"
    assert header_actions.at_css("[data-test='dev-board-tools']"),
           "the TASK tester group belongs beside New Task / Links"
    assert header_actions.at_css("[data-test='dev-deploy-tools']"),
           "the RELEASE tester group belongs beside New Task / Links"
    assert_nil filter_row.at_css("[data-test='dev-board-tools']"),
               "the tester must not also render down in the app-filter row"
    assert_nil filter_row.at_css("[data-test='dev-deploy-tools']"),
               "the tester must not also render down in the app-filter row"

    # The group chips name what they mutate: a fixture TASK vs a fixture RELEASE.
    assert_equal "Task", header_actions.at_css("[data-test='dev-board-tools'] span").text.strip
    assert_equal "Release", header_actions.at_css("[data-test='dev-deploy-tools'] span").text.strip

    # Both groups now say Advance — one steps a card, one steps the tracker.
    advance = header_actions.css("[data-test='dev-board-tools'] button").map { |b| b.text.strip }
    assert_includes advance, "Advance →", "Move was renamed to Advance"
    refute_includes advance, "Move"

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
