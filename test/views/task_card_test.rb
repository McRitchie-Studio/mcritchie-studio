require "test_helper"

# [component] the extracted board card partial renders standalone (the unit the
# broadcaster re-renders for a live push), with the slug/stage data hooks the
# client uses to find, move, and replace it.
class TaskCardTest < ActionView::TestCase
  setup do
    Agent.create!(name: "Carl", slug: "carl")
    @agents = Agent.all.to_a
  end

  test "renders the card with the slug/stage data hooks and the title" do
    task = Task.create!(title: "Card render task", stage: "submitted")

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :deploy }

    assert_select "#card-#{task.slug}[data-slug='#{task.slug}'][data-stage='submitted']"
    assert_includes rendered, "Card render task"
  end

  test "blocked card tone is readable in light and dark themes" do
    task = Task.create!(title: "Blocked tone task", stage: "blocked")

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :deploy }

    card = css_select("#card-#{task.slug}").first
    assert_includes card["class"], "bg-red-50"
    assert_includes card["class"], "dark:bg-red-950/40"
    assert_includes card["class"], "hover:bg-red-100/70"
    assert_includes rendered, "hover:text-red-700"
    assert_includes rendered, "dark:hover:text-red-300"
  end

  test "the activity label has no surrounding whitespace (it would render as a gap before the note count)" do
    task = Task.create!(title: "Activity label task", stage: "submitted")
    activity = Activity.create!(task_slug: task.slug, activity_type: "handoff",
                                description: "First note")
    Activity.create!(task_slug: task.slug, activity_type: "comment", description: "Second note")

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     latest_activity: activity, activity_count: 2 }

    label = css_select("[data-test='activity-box'] span").first
    assert_equal "Handoff", label.text,
      "uppercase tracking-wide label must have no surrounding whitespace, else it shows a gap before the count"
  end

  test "[component] renders clarification activity with a non-blocking card signal" do
    task = Task.create!(title: "Clarification card task", stage: "submitted")
    activity = Activity.create!(task_slug: task.slug, activity_type: "clarification",
                                description: "Can you confirm whether the docs example should mention PR comments?")

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     latest_activity: activity, activity_count: 1 }

    box = css_select("[data-test='activity-box']").first
    assert_equal "clarification", box["data-activity-type"]
    assert_includes box["class"], "border-cyan-300"

    label = css_select("[data-test='activity-type-label']").first
    assert_equal "Clarification", label.text
    assert_equal "Non-blocking question or answer", label["title"]
  end

  test "the slug row renders between the crew and updated age row with size first" do
    task = Task.create!(title: "Slug position task", stage: "building", po_size: "small")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "carl")

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :deploy }

    crew_index = rendered.index('data-test="stage-agent-avatars"')
    slug_index = rendered.index('data-test="task-slug-row"')
    size_index = rendered.index('data-test="task-size-badge"')
    slug_text_index = rendered.index("<code")
    updated_index = rendered.index('data-test="task-card-updated-row"')

    assert crew_index, "stage crew must render for the ordering assertion"
    assert slug_index, "slug row must expose its stable test hook"
    assert size_index, "size badge must expose its stable test hook"
    assert updated_index, "updated age row must expose its stable test hook"
    assert_operator crew_index, :<, slug_index
    assert_operator size_index, :<, slug_text_index
    assert_operator slug_index, :<, updated_index
  end

  test "the activity box renders after the updated age row" do
    task = Task.create!(title: "Activity position task", stage: "submitted")
    activity = Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                                description: "PR does not meet acceptance yet.")

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     latest_activity: activity, activity_count: 1 }

    updated_index = rendered.index('data-test="task-card-updated-row"')
    activity_index = rendered.index('data-test="activity-box"')

    assert updated_index, "updated age row must expose its stable test hook"
    assert activity_index, "activity box must expose its stable test hook"
    assert_operator updated_index, :<, activity_index
  end

  test "the partial is self-contained (no board @ivars) — renders with only its locals" do
    task = Task.create!(title: "Standalone card task", stage: "designed")

    assert_nothing_raised do
      render partial: "tasks/task_card",
             locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                       mascot: nil, latest_activity: nil, activity_count: 0 }
    end
    assert_select "#card-#{task.slug}"
  end
end
