require "test_helper"

# [component] tasks/_window_chip — the live countdown for an operator window
# (Devops::Windows, design section 6), seated beside the epic chip on the board
# card. Pinned on the standalone card render (the unit DeploymentsBroadcaster
# re-renders for a live push); the full-page and turbo-stream paths are pinned
# by test/integration/board_window_chip_test.rb.
class TaskWindowChipTest < ActionView::TestCase
  NOW = Time.utc(2026, 9, 24, 20, 0, 0)

  setup do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Avi", slug: "avi")
    @agents = Agent.all.to_a
  end

  def approval_window(requested_at: NOW)
    Devops::Windows.approval(requested_at: requested_at, waiting: true)
  end

  test "[component] the chip paints the kind, the end, and the mm:ss clock the ticker will advance" do
    render partial: "tasks/window_chip", locals: { window: approval_window, now: NOW + 61 }

    assert_select "[data-test='task-window-chip'][data-window-kind='approval'][data-window-state='open']" do
      assert_select "[data-window-ends-at='#{(NOW + 600).to_i}']"
      assert_select "[data-test='task-window-clock'][data-release-ticker][data-mode='window']" \
                    "[data-ends-at='#{(NOW + 600).to_i}'][data-lapsed-label='unanswered, proceeding']", text: "08:59"
    end
    assert_select "[data-test='task-window-chip'][data-window-urgent]", count: 0
  end

  test "[component] the last minute is urgent and the pulse is motion-safe only" do
    render partial: "tasks/window_chip", locals: { window: approval_window, now: NOW + 545 }

    chip = css_select("[data-test='task-window-chip']").first
    assert_equal "true", chip["data-window-urgent"]
    classes = chip["class"].split
    pulse = classes.find { |c| c.include?("animate-pulse") }
    assert pulse, "the urgent pulse must be a class on the chip"
    assert_includes pulse, "motion-safe:", "the pulse must be gated on motion-safe so reduced-motion viewers see no movement"
    refute classes.any? { |c| c == "animate-pulse" }, "no unconditional animation"
  end

  test "[component] a lapsed window paints the kind's lapsed label and dims" do
    render partial: "tasks/window_chip", locals: { window: approval_window, now: NOW + 600 }

    assert_select "[data-test='task-window-chip'][data-window-state='lapsed']" do
      assert_select "[data-test='task-window-clock']", text: "unanswered, proceeding"
    end
    chip = css_select("[data-test='task-window-chip']").first
    assert chip["class"].split.any? { |c| c.start_with?("data-[window-state=lapsed]:") }, "the lapsed state must change the chip's look"
  end

  test "[component] the chip renders nothing for no window" do
    render partial: "tasks/window_chip", locals: { window: nil }

    assert_select "[data-test='task-window-chip']", count: 0
    assert_equal "", rendered.strip, "no empty slot, no stray markup"
  end

  test "[component] every kind carries a light and a dark colour pair" do
    windows = {
      "approval" => approval_window,
      "escalation" => Devops::Windows.escalation(blocked_at: NOW, block_kind: "dependency", summary: "Escalated: x"),
      "production" => Devops::Windows.production(requested_at: NOW)
    }
    windows.each do |kind, window|
      render partial: "tasks/window_chip", locals: { window: window, now: NOW }
      chip = css_select("[data-test='task-window-chip'][data-window-kind='#{kind}']").first
      assert chip, "the #{kind} chip renders"
      classes = chip["class"].split
      %w[bg text border].each do |utility|
        light = classes.find { |c| c.start_with?("#{utility}-") && !c.start_with?("#{utility}-[") }
        dark = classes.find { |c| c.start_with?("dark:#{utility}-") }
        assert light, "the #{kind} chip needs a light-mode #{utility} colour"
        assert dark, "the #{kind} chip needs a dark-mode #{utility} colour beside #{light}"
      end
    end
  end

  test "[component] the card seats the approval countdown beside the epic chip while the request waits" do
    task = Task.create!(title: "Window chip approval card", stage: "building", epic_slug: "devops-v3",
                        metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3011/tasks" } })
    task.reload
    assert task.devops["approval_requested_at"].present?, "the request stamp is what the window derives from"

    render partial: "tasks/task_card", locals: { task: task, agents: @agents, crew_board: :build }

    assert_select "#card-#{task.slug} [data-test='task-slug-row'] [data-test='task-epic-chip'] + [data-test='task-window-chip'][data-window-kind='approval']"
    assert_select "#card-#{task.slug} [data-test='operator-approval-waiting']", { count: 1 },
                  "the WAITING APPROVAL bar still rides beside the clock"
  end

  test "[component] the card shows the escalation clock on an Escalated dependency block, ranked over the approval" do
    task = Task.create!(title: "Window chip escalation card", stage: "submitted",
                        metadata: { "devops" => { "approval_status" => "waiting" } })
    task.block!(by: "avi", kind: "dependency")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", agent_slug: "avi",
                     description: "POLICY QUESTION for Alex.", metadata: { "summary" => "Escalated: which default wins", "kind" => "dependency" })
    task.reload

    render partial: "tasks/task_card", locals: { task: task, agents: @agents, crew_board: :build,
                                                unresolved_feedback: task.unresolved_feedback_activity }

    assert_select "#card-#{task.slug} [data-test='task-window-chip']", count: 1
    assert_select "#card-#{task.slug} [data-test='task-window-chip'][data-window-kind='escalation']"
  end

  test "[component] a rework block wears no clock" do
    task = Task.create!(title: "Window chip rework card", stage: "submitted")
    task.block!(by: "carl", kind: "rework")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", agent_slug: "carl",
                     description: "Fix the spacing.", metadata: { "summary" => "Spacing off on the chip", "kind" => "rework" })
    task.reload

    render partial: "tasks/task_card", locals: { task: task, agents: @agents, crew_board: :build,
                                                unresolved_feedback: task.unresolved_feedback_activity }

    assert_select "#card-#{task.slug} [data-test='task-window-chip']", count: 0
  end

  test "[component] the card omits the chip when nothing is waiting on the operator" do
    task = Task.create!(title: "Window chip quiet card", stage: "building")

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :build }

    assert_select "#card-#{task.slug} [data-test='task-window-chip']", count: 0
  end
end
