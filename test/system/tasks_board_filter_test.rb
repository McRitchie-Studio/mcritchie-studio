require "application_system_test_case"

# [e2e] The /tasks board is rebased onto the studio/board primitive: the filter /
# archive chrome lives in the OUTER taskBoardChrome component, while the cards render
# INSIDE the primitive's studioBoard component. This proves the NESTED Alpine scope
# resolves REACTIVELY across that boundary — toggling an app chip mutates
# taskBoardChrome state and the card (inside the inner component) hides, then restores.
# It's the composition's core risk, asserted as the real in-browser effect.
class TasksBoardFilterSystemTest < ApplicationSystemTestCase
  test "[e2e] an app chip toggle hides then restores a card across the nested board scope" do
    rolio = Task.create!(
      title: "rolio tasks board card", stage: "building",
      metadata: { "devops" => { "repositories" => ["rolio"] } }
    )
    turf = Task.create!(
      title: "turf tasks board card", stage: "building",
      metadata: { "devops" => { "repositories" => ["turf-monster"] } }
    )

    visit tasks_path
    # The outer chrome is interactive AND the primitive board rendered.
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"
    assert_selector "[data-test='studio-board']"

    # Both cards start visible — the nested scope resolves matchesFilter/appVisible.
    assert_selector "#card-#{rolio.slug}", visible: true
    assert_selector "#card-#{turf.slug}", visible: true

    # Hide Rolio → its card (inside studioBoard) reacts to the OUTER hiddenApps.
    find("[data-test='board-filter-row'] button", text: "rolio", match: :first).click
    assert_no_selector "#card-#{rolio.slug}", visible: true
    assert_selector "#card-#{turf.slug}", visible: true

    # Toggle Rolio back on → its card returns.
    find("[data-test='board-filter-row'] button", text: "rolio", match: :first).click
    assert_selector "#card-#{rolio.slug}", visible: true
  end
end
