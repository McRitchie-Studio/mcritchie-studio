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
    # The board is TWO Alpine components — this chrome wrapping the engine's
    # studio/board primitive — and each stamps data-alpine-ready on its own $el
    # after its directive walk. Waiting on BOTH is strictly stricter than waiting
    # on the chrome alone and costs nothing, so it stays.
    #
    # It is NOT known to fix anything. THE FLAKE THIS TEST SUFFERS IS STILL OPEN:
    # it failed in CI three times across PRs #727 and #729 and has never once
    # reproduced locally (single file, full lane, CI seeds, clean db:test:prepare,
    # and CI's exact merge ref). An init-race explanation was proposed and then
    # REFUTED in review: the chrome and the primitive render inline in one
    # document, so Alpine performs a single initTree walk whose deferHandlingDirectives
    # flush binds the cards' x-show BEFORE either flag is stamped — there is no
    # window between the two flags to close. A cold binding would also self-heal,
    # since an effect's first evaluation reads the already-mutated hiddenApps.
    # A better untested suspect: the chip's width depends on app_emoji(app), and
    # headless CI renders emoji at different widths, so a layout shift between
    # locating the chip below and dispatching the click fits "3x in CI, never
    # locally" far better than any init race.
    #
    # If this test fails again, the cause is still unfound — do not read these two
    # assertions as having handled it.
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
