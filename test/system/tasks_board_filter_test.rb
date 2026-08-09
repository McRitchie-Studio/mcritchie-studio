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
    # BOTH components must be interactive before the click, and they are separate
    # signals. The chrome owns the filter chips (@click="toggleApp"); the CARDS —
    # and their x-show="matchesFilter(...) && appVisible(...)" — live inside the
    # inner studio/board primitive, which initialises AFTER the chrome. Waiting on
    # the chrome alone let a click land while the card bindings were still cold:
    # toggleApp mutated hiddenApps with nothing listening, and the card never hid.
    # That failed this test three times in CI (never once locally) across two
    # unrelated PRs. Each component stamps data-alpine-ready on its own $el AFTER
    # its directive walk — the engine's at studio/_board_assets.html.erb — so gate
    # on the INNER one too rather than on mere markup presence.
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"
    assert_selector "[data-test='studio-board'][data-alpine-ready='true']"

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
