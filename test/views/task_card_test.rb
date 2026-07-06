require "test_helper"

# [component] the extracted board card partial renders standalone (the unit the
# broadcaster re-renders for a live push), with the slug/stage data hooks the
# client uses to find, move, and replace it.
class TaskCardTest < ActionView::TestCase
  TypeColor = Struct.new(:color, :rank, :emoji, keyword_init: true)

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
    assert_equal "blocked", card["data-stage-glow"]
    assert_includes card["class"], "bg-red-50"
    assert_includes card["class"], "task-card-stage-glow-blocked"
    assert_includes card["class"], "dark:bg-red-950/40"
    assert_includes card["class"], "hover:bg-red-100/70"
    assert_includes card["style"], "--task-card-glow-color: #ef4444"
    assert_includes card["style"], "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 46%, transparent)"
    assert_includes card["style"], "0 0 48px color-mix(in srgb, var(--task-card-glow-color) 14%, transparent)"
    assert_includes card["style"], "border-color: var(--task-card-glow-border-color)"
    assert_includes card["style"], "box-shadow: var(--task-card-glow-shadow)"
    assert_includes rendered, "hover:text-red-700"
    assert_includes rendered, "dark:hover:text-red-300"
  end

  test "submitted card glows with the mascot signature color" do
    task = Task.create!(title: "Submitted glow task", stage: "submitted")
    mascot = Pokemon.create!(dex: 158, name: "Totodile", slug: "totodile", types: %w[water],
                             primary_type: "water", generation: 2)
    type_enumerals = { "water" => TypeColor.new(color: "#6390F0", rank: 10, emoji: "💧") }

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     mascot: mascot, type_enumerals: type_enumerals }

    card = css_select("#card-#{task.slug}").first
    assert_equal "submitted", card["data-stage-glow"]
    assert_equal "#6390F0", card["data-glow"]
    assert_includes card["class"], "task-card-stage-glow-submitted"
    assert_includes card["style"], "--task-card-glow-color: #6390F0"
    assert_includes card["style"], "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 46%, transparent)"
    assert_includes card["style"], "0 0 48px color-mix(in srgb, var(--task-card-glow-color) 14%, transparent)"
  end

  test "reviewed card uses the larger steady glow" do
    task = Task.create!(title: "Reviewed glow task", stage: "reviewed",
                        metadata: { "devops" => { "mascot_color" => "#22d3ee" } })

    render partial: "tasks/task_card", locals: { task: task.reload, agents: @agents, crew_board: :deploy }

    card = css_select("#card-#{task.slug}").first
    assert_equal "reviewed", card["data-stage-glow"]
    assert_includes card["class"], "task-card-stage-glow-reviewed"
    assert_includes card["style"], "--task-card-glow-color: #22d3ee"
    assert_includes card["style"], "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 58%, transparent)"
    assert_includes card["style"], "0 0 82px color-mix(in srgb, var(--task-card-glow-color) 22%, transparent)"
    assert_includes card["style"], "0 0 118px color-mix(in srgb, var(--task-card-glow-color) 12%, transparent)"
  end

  test "deploy attention cards support single two-color and rainbow border glows" do
    task = Task.create!(title: "Assembled glow task", stage: "assembled")
    mascot = Pokemon.create!(dex: 806, name: "Charizard", slug: "charizard", types: %w[fire flying],
                             primary_type: "fire", generation: 1)
    type_enumerals = {
      "fire" => TypeColor.new(color: "#EE8130", rank: 900, emoji: "🔥"),
      "flying" => TypeColor.new(color: "#A98FF3", rank: 200, emoji: "💨")
    }

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     mascot: mascot, type_enumerals: type_enumerals }

    card = css_select("#card-#{task.slug}").first
    assert_equal "assembled", card["data-stage-glow"]
    assert_includes card["class"], "task-card-stage-glow-assembled"
    assert_includes card["style"], "--task-card-glow-color: #EE8130"
    assert_includes card["style"], "--task-card-glow-color-a: #EE8130"
    assert_includes card["style"], "--task-card-glow-color-b: #A98FF3"
    assert_includes card["style"], "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 58%, transparent)"
    assert_includes card["style"], "0 0 82px color-mix(in srgb, var(--task-card-glow-color) 22%, transparent)"
    assert_includes card["style"], "0 0 118px color-mix(in srgb, var(--task-card-glow-color) 12%, transparent)"

    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_includes css, ".task-card-stage-glow-submitted::before"
    assert_includes css, ".task-card-stage-glow-reviewed::before"
    assert_includes css, ".task-card-stage-glow-assembled::before"
    assert_includes css, ".release-confirming-glow::before"
    assert_includes css, ".task-card-stage-glow-submitted::after"
    assert_includes css, ".task-card-stage-glow-reviewed::after"
    assert_includes css, ".task-card-stage-glow-assembled::after"
    assert_includes css, ".release-confirming-glow::after"
    assert_includes css, ".task-card-stage-glow-submitted"
    assert_includes css, "--deployment-border-gradient: linear-gradient(45deg, #22c55e, #22c55e)"
    assert_includes css, "--deployment-border-animation: none"
    assert_includes css, ".task-card-stage-glow-reviewed"
    assert_includes css, "#facc15"
    assert_includes css, "#2563eb"
    assert_includes css, "--deployment-border-animation: deploymentBorderSteam 20s linear infinite"
    assert_includes css, "animation: var(--deployment-border-animation)"
    assert_includes css, "background-size: 400%"
    assert_includes css, "filter: blur(var(--deployment-border-halo-blur))"
    assert_includes css, "-webkit-mask-composite: xor"
    assert_includes css, "mask-composite: exclude"
    assert_includes css, "padding: 2px"
    assert_includes css, "inset: -10px"
    assert_includes css, "padding: 10px"
    assert_includes css, "#fb0094"
    assert_includes css, "#00c4ff"
    assert_includes css, "#34d399"
    assert_includes css, "@keyframes deploymentBorderSteam"
    assert_includes css, "animation: none"
    assert_not_includes css, ".task-card-stage-glow-blocked::before"
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

  test "[component] a cleared-block card wears the amber re-review tone + badge" do
    task = Task.create!(title: "Cleared block card", stage: "submitted")

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     unresolved_feedback: nil, ever_blocked: true }

    card = css_select("#card-#{task.slug}").first
    assert_includes card["class"], "bg-amber-50"
    assert_includes card["class"], "dark:bg-amber-950/40"
    assert_includes card["class"], "hover:bg-amber-100/70"
    assert_select "[data-test='cleared-feedback']", text: "RE-REVIEW"
    assert_not_includes card["class"], "bg-red-50", "a cleared block is amber, not red"
  end

  test "[component] an open block still wins red over amber" do
    task = Task.create!(title: "Still blocked card", stage: "submitted")
    feedback = Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                                description: "please fix it")

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     unresolved_feedback: feedback, ever_blocked: true }

    card = css_select("#card-#{task.slug}").first
    assert_equal "blocked", card["data-stage-glow"]
    assert_includes card["class"], "bg-red-50"
    assert_includes card["class"], "task-card-stage-glow-blocked"
    assert_select "[data-test='unresolved-feedback']"
    assert_select "[data-test='cleared-feedback']", count: 0
  end

  test "[component] a never-blocked submitted card stays plain" do
    task = Task.create!(title: "Never blocked card", stage: "submitted")

    render partial: "tasks/task_card",
           locals: { task: task.reload, agents: @agents, crew_board: :deploy,
                     unresolved_feedback: nil, ever_blocked: false }

    card = css_select("#card-#{task.slug}").first
    assert_includes card["class"], "bg-surface"
    assert_equal "submitted", card["data-stage-glow"]
    assert_includes card["class"], "task-card-stage-glow-submitted"
    assert_includes card["style"], "--task-card-glow-color: #f59e0b"
    assert_select "[data-test='cleared-feedback']", count: 0
  end
end
