require "test_helper"

# [component] tasks/_epic_chip — the connective tissue between an epic and its
# tasks on the board. The partial prints the task's epic slug as a chip linking
# to the filtered board, and renders NOTHING when the task belongs to no epic;
# the card partial seats it beside the task-slug chip. Both are pinned here on
# the standalone card render — the unit DeploymentsBroadcaster re-renders for a
# live push — with the full-page and turbo-stream paths pinned by
# test/integration/board_epic_filter_test.rb.
class TaskEpicChipTest < ActionView::TestCase
  setup do
    Agent.create!(name: "Carl", slug: "carl")
    @agents = Agent.all.to_a
  end

  test "[component] the chip prints the epic and links to the filtered board" do
    render partial: "tasks/epic_chip", locals: { epic_slug: "devops-v3" }

    assert_select "a[data-test='task-epic-chip'][data-epic='devops-v3'][href='/tasks?epic=devops-v3']", text: "devops-v3"
  end

  test "[component] the chip renders nothing for a blank epic" do
    render partial: "tasks/epic_chip", locals: { epic_slug: nil }
    assert_select "[data-test='task-epic-chip']", count: 0
    assert_equal "", rendered.strip, "no empty slot, no stray markup"

    render partial: "tasks/epic_chip", locals: { epic_slug: "" }
    assert_select "[data-test='task-epic-chip']", count: 0
  end

  # Distinct from the mono task slug beside it, and readable on both surfaces:
  # every colour utility on the chip has a dark: twin.
  test "[component] the chip carries a light and a dark colour pair" do
    render partial: "tasks/epic_chip", locals: { epic_slug: "devops-v3" }

    chip = css_select("[data-test='task-epic-chip']").first
    classes = chip["class"].split
    %w[bg text border].each do |utility|
      light = classes.find { |c| c.start_with?("#{utility}-violet") }
      dark = classes.find { |c| c.start_with?("dark:#{utility}-violet") }
      assert light, "the chip needs a light-mode #{utility} colour"
      assert dark, "the chip needs a dark-mode #{utility} colour beside #{light}"
    end
  end

  test "[component] the card seats the chip beside the task slug when the task has an epic" do
    task = Task.create!(title: "Epic chip card task", stage: "building", epic_slug: "devops-v3")

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :build }

    assert_select "#card-#{task.slug} [data-test='task-slug-row'] code", text: task.slug
    assert_select "#card-#{task.slug} [data-test='task-slug-row'] [data-test='task-epic-chip'][href='/tasks?epic=devops-v3']",
                  text: "devops-v3"
  end

  test "[component] the card omits the chip when the task has no epic" do
    task = Task.create!(title: "No epic card task", stage: "building")

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :build }

    assert_select "#card-#{task.slug} [data-test='task-slug-row'] code", text: task.slug
    assert_select "#card-#{task.slug} [data-test='task-epic-chip']", count: 0
  end
end
