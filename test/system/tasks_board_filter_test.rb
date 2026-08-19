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
    #
    # click_when_settled, NOT find(...).click. This test failed intermittently on three
    # PRs across two sessions in one day, always on the card assertion below, and the
    # cause was never the board: the chip was still being re-measured when the driver
    # clicked it. Montserrat arrives from fonts.googleapis.com after the load event, so
    # every chip resizes during the window this test spends getting ready; a reflow
    # between pointerdown and pointerup fires `click` on the row instead of the button,
    # and the filter is never toggled at all. See ApplicationSystemTestCase.
    #
    # ASSERT THE TOGGLE BEFORE ITS CONSEQUENCE. aria-pressed is the chip's own state, so
    # a swallowed click fails HERE, naming itself, instead of downstream on a card
    # assertion that cannot say whether the click or the reactivity was at fault.
    click_when_settled("[data-test='board-filter-row'] button", text: "rolio", match: :first)
    assert_selector "[data-test='board-filter-row'] button[aria-pressed='true']", text: "rolio",
                    wait: 5
    assert_no_selector "#card-#{rolio.slug}", visible: true
    assert_selector "#card-#{turf.slug}", visible: true

    # Toggle Rolio back on → its card returns.
    click_when_settled("[data-test='board-filter-row'] button", text: "rolio", match: :first)
    assert_selector "[data-test='board-filter-row'] button[aria-pressed='false']", text: "rolio",
                    wait: 5
    assert_selector "#card-#{rolio.slug}", visible: true
  end

  # The ready flag is runtime truth ("chrome wired"), so it must not survive into
  # Turbo's cache: the snapshot is taken AFTER turbo:before-cache handlers run,
  # and whatever they leave is exactly what a restoration visit paints as the
  # preview — before Alpine re-initialises. Dispatch the event Turbo would and
  # assert the cleanup really strips the flag (the effect, not the listener text).
  test "[e2e] turbo:before-cache strips the tasks board ready flag" do
    visit tasks_path
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"

    execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")

    assert_selector "[data-test='kanban-board']"
    assert_no_selector "[data-test='kanban-board'][data-alpine-ready]"
  end
end
