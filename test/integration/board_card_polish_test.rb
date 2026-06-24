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
end
