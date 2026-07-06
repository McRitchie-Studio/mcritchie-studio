require "test_helper"

# Component tier (ui-only shape): the task-card polish pass. Renders the real shared
# app/views/tasks/_board.html.erb via /tasks and asserts:
#   #2  gem release → a BARE footer 💎 (the old "💎 gem" violet pill is gone)
#   #3b activity label moved INSIDE the message box, in white (text-heading)
#   #4  the redundant assignee name chip is removed
class BoardCardPolishTest < ActionDispatch::IntegrationTest
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
  end

  test "a gem release shows a bare footer emoji, not the old pill" do
    task = Task.create!(title: "gem release polish card", stage: "submitted",
                        metadata: { "devops" => { "shape" => "library" } })
    assert task.gem_release?, "library shape should be a gem release"

    get tasks_path
    assert_response :success

    # the bare 💎 carries its hover title; the old "💎 gem" pill text is gone
    assert_select "#card-#{task.slug} span[title^='Gem release']", count: 1
    assert_select "#card-#{task.slug} span", text: "💎 gem", count: 0
  end

  test "the activity label rides inside the message box in white" do
    task = Task.create!(title: "activity label polish card", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                     description: "QA-deployed on release; pending the operator prod-ship gate.")

    get tasks_path
    assert_response :success

    # the label now lives INSIDE the box (data-test='activity-box') as a white
    # (text-heading) tag — not a violet header above it
    assert_select "#card-#{task.slug} [data-test='activity-box'] span.text-heading",
                  text: "QA Feedback", count: 1
  end

  test "the assignee name chip is removed from the card" do
    task = Task.create!(title: "assignee chip polish card", stage: "building",
                        agent_slug: "shannon")

    get tasks_path
    assert_response :success

    # no standalone assignee name chip — the stage crew under the slug attributes work
    assert_select "#card-#{task.slug} span.text-xs.text-muted", text: "shannon", count: 0
  end

  test "the URG / HIGH priority badges are dropped" do
    urgent = Task.create!(title: "urgent priority polish card", stage: "building", priority: 2)
    high   = Task.create!(title: "high priority polish card", stage: "building", priority: 1)

    get tasks_path
    assert_response :success

    assert_select "#card-#{urgent.slug} span", text: "URG", count: 0
    assert_select "#card-#{high.slug} span", text: "HIGH", count: 0
  end

  test "the slug and footer meta are single-line with clipped overflow" do
    task = Task.create!(title: "single line polish card", stage: "submitted")

    get tasks_path
    assert_response :success

    # slug fades/clips on one line (no wrap) — mask handles the fade
    assert_select "#card-#{task.slug} code.whitespace-nowrap.overflow-hidden", count: 1
    # the footer meta wrapper is a single non-wrapping clipped line too
    assert_select "#card-#{task.slug} div.whitespace-nowrap.overflow-hidden", minimum: 1
  end

  test "long card title and activity preview each marquee on one line" do
    task = Task.create!(title: "Suite Consistency Cleanup Review Card",
                        stage: "blocked")
    note = "QA review found one remaining generated-doc blocker that needs action before merge."
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                     description: note)

    get tasks_path
    assert_response :success

    # the title never wraps: one line, edge fade + hover marquee (overflow_fade)
    assert_select "#card-#{task.slug} a[data-test='task-card-title'] [x-ref='fadeInner']",
                  text: /Suite Consistency Cleanup/, count: 1
    assert_select "#card-#{task.slug} [data-test='task-card-title'].line-clamp-2", count: 0
    # the activity preview marquees on one line too now (overflow_fade), no longer a clamp
    assert_select "#card-#{task.slug} [data-test='activity-description'] [x-ref='fadeInner']",
                  text: /QA review found one remaining/, count: 1
    assert_select "#card-#{task.slug} [data-test='activity-description'].line-clamp-2", count: 0
    # the full note stays reachable via the tooltip on the preview wrapper
    assert_select "#card-#{task.slug} [data-test='activity-description'][title=?]", note, count: 1
    assert_select "#card-#{task.slug} a[data-test='task-card-title'][title=?]", task.title, count: 1
  end

  test "the size badge leads the slug row instead of the footer meta row" do
    task = Task.create!(title: "size badge polish card", stage: "submitted", po_size: "small")

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='task-slug-row'] [data-test='task-size-badge']",
                  text: "S", count: 1
    assert_select "#card-#{task.slug} [data-test='task-card-updated-row'] [data-test='task-size-badge']",
                  count: 0

    card_html = css_select("#card-#{task.slug}").first.to_html
    size_index = card_html.index('data-test="task-size-badge"')
    slug_code_index = card_html.index("<code")
    assert_operator size_index, :<, slug_code_index
  end

  test "the release-slug badge is dropped from the board card" do
    task = Task.create!(title: "release slug polish card", stage: "submitted",
                        metadata: { "devops" => { "release_slug" => "rel-2026-06-23-devops-intent-ui" } })

    get tasks_path
    assert_response :success

    # the release-slug pill no longer rides the card — it's pipeline plumbing, not a
    # high-level glance signal (it still shows on the task detail view)
    assert_select "#card-#{task.slug} span", text: "2026-06-23-devops-intent-ui", count: 0
  end

  test "QA and Prod quick links still ride the card when present" do
    task = Task.create!(title: "qa prod links polish card", stage: "submitted",
                        metadata: { "devops" => {
                          "qa_url" => "https://qa.example.com",
                          "production_url" => "https://prod.example.com",
                        } })

    get tasks_path
    assert_response :success

    # dropping the release-slug badge must not take the QA/Prod links with it
    assert_select "#card-#{task.slug} a", text: "QA", count: 1
    assert_select "#card-#{task.slug} a", text: "Prod", count: 1
  end

  test "the activity box follows the updated row with tight internal spacing" do
    task = Task.create!(title: "activity margin polish card", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "handoff",
                     description: "Increment 2 (websocket live updates) handed off.")

    get tasks_path
    assert_response :success

    card_html = css_select("#card-#{task.slug}").first.to_html
    updated_index = card_html.index('data-test="task-card-updated-row"')
    activity_index = card_html.index('data-test="activity-box"')

    assert_operator updated_index, :<, activity_index
    # the box sits tight under the metadata row and trims header/message gap
    assert_select "#card-#{task.slug} [data-test='activity-box'].mt-1", count: 1
    assert_select "#card-#{task.slug} [data-test='activity-box'].py-1", count: 1
    assert_select "#card-#{task.slug} [data-test='activity-box'] div.mb-0.leading-none", count: 1
    assert_select "#card-#{task.slug} [data-test='activity-box'] [data-test='activity-description']", count: 1
    assert_select "#card-#{task.slug} [data-test='activity-box'].mt-2", count: 0
  end

  test "long title and activity text each marquee on one line" do
    task = Task.create!(title: "Long Card Title", stage: "submitted")
    task.update_column(:title, "Long Board Card Title That Must Stay Inside The Card")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                     description: "QA review found one remaining visual regression in the board card and the note should stay inside the activity box.")

    get tasks_path
    assert_response :success

    # the title link never wraps: one line, edge fade + hover marquee (overflow_fade)
    assert_select "#card-#{task.slug} > a.line-clamp-2", count: 0
    assert_select "#card-#{task.slug} > a[data-test='task-card-title'] [x-ref='fadeInner']",
                  text: /Long Board Card Title/, count: 1
    assert_select "#card-#{task.slug} > a[data-test='task-card-title'].line-clamp-2.break-words", count: 0
    # the activity preview marquees on one line too now (overflow_fade), no longer a clamp
    assert_select "#card-#{task.slug} [data-test='activity-box'] p.line-clamp-2.break-words", count: 0
    assert_select "#card-#{task.slug} [data-test='activity-box'] [x-ref='fadeInner']",
                  text: /QA review found one remaining visual regression/, count: 1
  end
end
