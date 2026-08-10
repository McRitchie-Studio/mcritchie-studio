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
    find("button", text: "rolio", match: :first).click
    assert_no_selector "#card-#{rolio.slug}", visible: true
    assert_selector "#card-#{turf.slug}", visible: true

    # Toggle Rolio back on → its card returns.
    find("button", text: "rolio", match: :first).click
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
