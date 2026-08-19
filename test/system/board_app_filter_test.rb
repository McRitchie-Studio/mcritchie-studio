require "application_system_test_case"

# E2E happy path: the app filter actually hides and restores cards in a real
# browser. Toggling an app chip hides its cards; toggling it again restores them.
class BoardAppFilterSystemTest < ApplicationSystemTestCase
  test "toggling an app chip hides then restores its cards" do
    rolio = Task.create!(
      title: "rolio e2e card task", stage: "designed",
      metadata: { "devops" => { "repositories" => ["rolio"] } }
    )
    turf = Task.create!(
      title: "turf e2e card task", stage: "designed",
      metadata: { "devops" => { "repositories" => ["turf-monster"] } }
    )

    visit deployments_path
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"

    # Both cards start visible.
    assert_selector "#card-#{rolio.slug}", visible: true
    assert_selector "#card-#{turf.slug}", visible: true

    # Hide Rolio → its card disappears, the turf card stays.
    #
    # The chip's own state first, for the same reason as the /tasks board spec: a card
    # that is still visible cannot tell you whether the click landed. See
    # tasks_board_filter_test.rb for the incident this came from.
    #
    # Scoped to the filter row and clicked through click_when_settled, because this
    # board carries the identical exposure: the chips are sized by a webfont that
    # arrives after the load event, and a click dispatched while they are still being
    # re-measured lands on their common ancestor instead of the button.
    click_when_settled("[data-test='board-filter-row'] button", text: "rolio", match: :first)
    assert_selector "button[aria-pressed='true']", text: "rolio", wait: 5
    assert_no_selector "#card-#{rolio.slug}", visible: true
    assert_selector "#card-#{turf.slug}", visible: true

    # Toggle Rolio back on → its card returns.
    click_when_settled("[data-test='board-filter-row'] button", text: "rolio", match: :first)
    assert_selector "button[aria-pressed='false']", text: "rolio", wait: 5
    assert_selector "#card-#{rolio.slug}", visible: true
  end

  # The ready flag is runtime truth ("directives bound / chips clickable"), so it
  # must not survive into Turbo's cache: the snapshot is taken AFTER
  # turbo:before-cache handlers run, and whatever they leave is exactly what a
  # restoration visit paints as the preview — before Alpine re-initialises.
  # Dispatch the event Turbo would and assert the cleanup really strips the flag.
  test "[e2e] turbo:before-cache strips the deploy board ready flag" do
    visit deployments_path
    assert_selector "[data-test='kanban-board'][data-alpine-ready='true']"

    execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")

    assert_selector "[data-test='kanban-board']"
    assert_no_selector "[data-test='kanban-board'][data-alpine-ready]"
  end
end
