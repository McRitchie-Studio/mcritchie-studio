require "application_system_test_case"

class ReviewEventsTest < ApplicationSystemTestCase
  test "[e2e] reviewer can open event reader from task timeline" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "review reader system task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )
    task.record_review_check_in(
      role: "primary",
      moment: "diff",
      actor: "carl",
      message: "System test sees the primary diff checkpoint."
    )
    task.record_review_check_in(
      role: "light",
      moment: "smoke",
      actor: "shannon",
      message: "System test sees the light smoke checkpoint."
    )

    visit task_path(task.slug)
    review_link = find("[data-test='timeline-review-events-link']")
    assert_equal review_events_task_path(task.slug), URI.parse(review_link[:href]).path
    execute_script("arguments[0].click()", review_link.native)

    assert_current_path review_events_task_path(task.slug)
    assert_text "HEAVY SWIMLANE"
    assert_text "LIGHT SWIMLANE"
    assert_text "System test sees the primary diff checkpoint."
    assert_text "System test sees the light smoke checkpoint."
  end

  test "[e2e] operator opens review process hub from deployment link menu" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "review hub system task", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    visit deployments_path

    # Under a chromedriver/chrome version skew in CI, the native click on the
    # <summary> is sometimes silently swallowed (PRs #460 and #467 red-flagged
    # here at the [open] assertion). A missed click leaves the <details> closed
    # forever, so a single click followed by assert_selector just burns the
    # Capybara wait and fails. Retry the click with a bounded poll between
    # attempts: the browser sets the open attribute synchronously when an
    # activation registers, so a 2s poll coming back false means the click
    # never landed and a re-click cannot toggle an open menu shut.
    menu = find("[data-test='deployment-link-menu']")
    3.times do
      menu.find("summary").click
      break if page.has_css?("[data-test='deployment-link-menu'][open]", wait: 2)
    end
    assert_selector "[data-test='deployment-link-menu'][open]"

    # The dropdown stacks "Stages" directly above "Docs"; the same click skew
    # once mis-landed a too-early click on the adjacent "Stages" link (asserted
    # "/stages" instead of "/review_events"). With the menu confirmed open,
    # resolve the Docs link by its unique hook (verifying its href so a
    # selector drift can't pass silently), then click that exact element.
    docs_link = find("[data-test='deployment-link-menu-docs']")
    assert_equal review_events_hub_path, URI.parse(docs_link[:href]).path
    docs_link.click

    assert_current_path review_events_hub_path
    assert_text "Review Process Hub"
    assert_text "HEAVY SWIMLANE"
    assert_text "LIGHT SWIMLANE"
    assert_text "review hub system task"
    assert_text "Carl"
    assert_text "Shannon"
  end
end
