# frozen_string_literal: true

require "test_helper"
require "view_component/test_helpers"
require_relative "../support/task_card_rendering"

# [unit] TaskCardComponent renders each stage, block, approval and soul state from
# its declared inputs, and reads nothing beyond them.
class TaskCardComponentTest < ActionView::TestCase
  include TaskCardRendering
  include ViewComponent::TestHelpers

  setup do
    %w[Carl Avi].each_with_index { |name, position| Agent.create!(name: name, slug: name.downcase, position: position) }
    @agents = Agent.order(:position).to_a
  end

  def card_for(task)
    css_select("#card-#{task.slug}").last
  end

  def studio_session(task, soul:, issued_by:)
    AgentSession.create!(soul: soul, tier: "studio", task_slug: task.slug, issued_by: issued_by)
  end

  def count_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:cached] || payload[:name].to_s == "SCHEMA"
      next if payload[:sql].to_s.start_with?("BEGIN", "COMMIT", "ROLLBACK", "RELEASE", "SAVEPOINT")

      queries << payload[:sql]
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # One gallery preview's rendered DOM.
  def preview(name)
    Nokogiri::HTML5.fragment(render_preview(name, from: TaskCardComponentPreview).to_s)
  end

  # The page batch, as TaskCardPreloads#load_task_cards builds it.
  def board_for(tasks)
    slugs = tasks.map(&:slug)
    activities = Activity.where(task_slug: slugs, activity_type: Activity::TASK_CONVERSATION_TYPES)
    TaskCardComponent::Board.new(
      agents: @agents, pokemon_by_slug: Pokemon.all.index_by(&:slug), type_enumerals: Pokemon.type_enumerals,
      latest_activities: activities.recent.each_with_object({}) { |row, memo| memo[row.task_slug] ||= row },
      activity_counts: activities.group(:task_slug).count,
      unresolved_feedback: Task.unresolved_feedback_by_slug(slugs),
      ever_blocked_slugs: Activity.where(task_slug: slugs, activity_type: "qa_feedback").distinct.pluck(:task_slug).to_set,
      resubmissions: Task::Resubmission.for_tasks(tasks), ci_progress_by_slug: {},
      agent_sessions: AgentSession.live_by_task(tasks)
    )
  end

  test "test_renders_each_stage: the root carries the id and data hooks the board and the stream rely on" do
    Task::STAGES.each do |stage|
      task = Task.create!(title: "Component #{stage} card", stage: stage, agent_slug: "carl",
                          metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })

      render_task_card(task.reload)

      card = card_for(task)
      assert card, "#{stage}: the root is #card-<slug>"
      assert_includes card["class"].split, "kanban-card", "#{stage}: the drag board finds it by .kanban-card"
      assert_equal [task.slug, stage, "carl", "mcritchie-studio", "/tasks/#{task.slug}"],
                   %w[data-slug data-stage data-agent data-apps data-href].map { |name| card[name] }
      assert_equal stage != "archived", card.css("[data-test='task-card-archive']").any?,
                   "#{stage}: only an archived card drops the archive action"
      assert_equal 1, card.css("[data-test='task-card-delete']").size
      assert_equal ApplicationController.helpers.ci_meter_stage?(stage), card.css("#ci-progress-#{task.slug}").any?,
                   "#{stage}: the CI slot keeps its id where the meter shows"
    end
  end

  test "test_blocked: a live block is red with the blocker's words; past the seam it only tints" do
    live = Task.create!(title: "Component live block card", stage: "building")
    live.block!(by: "carl", kind: "rework")
    Activity.create!(task_slug: live.slug, activity_type: "qa_feedback", description: "x",
                     metadata: { "summary" => "Spacing off on the chip", "kind" => "rework" })
    past = Task.create!(title: "Component reviewed block card", stage: "reviewed")
    Activity.create!(task_slug: past.slug, activity_type: "qa_feedback", description: "please fix it")

    render_task_card(live.reload, crew_board: :build)
    render_task_card(past.reload)

    assert_equal "blocked", card_for(live)["data-stage-glow"]
    assert_includes card_for(live)["class"].split, "border-danger/40"
    assert_equal "Spacing off on the chip", card_for(live).css("[data-test='blocker-summary']").text.strip
    assert_equal "reviewed", card_for(past)["data-stage-glow"], "the border stays the stage's"
    assert_includes card_for(past)["class"].split, "bg-danger/10"
    assert_not_includes card_for(past)["class"].split, "border-danger/40"
  end

  test "test_waiting_approval: the request shows its bar, its countdown and the amber glow" do
    task = Task.create!(title: "Component approval card", stage: "building",
                        metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3011/tasks" } })

    render_task_card(task.reload, crew_board: :build)

    card = card_for(task)
    assert_equal "approval", card["data-stage-glow"]
    assert_equal "/tasks/#{task.slug}/local_review", card.css("[data-test='operator-approval-waiting']").first["href"]
    assert_equal "approval", card.css("[data-test='task-window-chip']").first["data-window-kind"]
  end

  test "test_soul_chip_logged_in: a live studio login shows its soul beside the crew, builder or reviewer" do
    built = Task.create!(title: "Component builder login card", stage: "building")
    reviewed = Task.create!(title: "Component reviewer login card", stage: "submitted")
    builder = studio_session(built, soul: "carl", issued_by: "task_claim")
    reviewer = studio_session(reviewed, soul: "avi", issued_by: "review_claim")

    render_task_card(built.reload, crew_board: :build, agent_session: builder)
    render_task_card(reviewed.reload, agent_session: reviewer)

    chip = card_for(built).css("[data-test='task-card-soul']").first
    assert_equal %w[carl task_claim], [chip["data-soul"], chip["data-login"]]
    assert_equal "Carl is logged in (builder login)", chip["title"]
    assert_equal "Avi is logged in (reviewer login)", card_for(reviewed).css("[data-test='task-card-soul']").first["title"]
  end

  test "a soul the roster does not carry still shows, by its slug" do
    task = Task.create!(title: "Component unknown soul card", stage: "building")
    session = studio_session(task, soul: "jasper", issued_by: "task_claim")

    render_task_card(task.reload, crew_board: :build, agent_session: session)

    chip = card_for(task).css("[data-test='task-card-soul']").first
    assert_equal "jasper", chip.text.strip
    assert_equal "jasper is logged in (builder login)", chip["title"]
  end

  test "test_pokemon_alone_logged_out: no session, no chip and no wrapper around the crew" do
    task = Task.create!(title: "Component logged out card", stage: "building")

    render_task_card(task.reload, crew_board: :build, agent_session: nil)

    assert_empty card_for(task).css("[data-test='task-card-soul'], [data-test='task-card-soul-anchor']")
  end

  # The board hands the card a session only while it is live, so a lapsed
  # reviewer login leaves the card logged out.
  test "the page batch carries a live login and drops a lapsed reviewer's" do
    built = Task.create!(title: "Component batch builder card", stage: "building")
    lapsed = Task.create!(title: "Component batch lapsed card", stage: "submitted")
    studio_session(built, soul: "carl", issued_by: "task_claim")
    studio_session(lapsed, soul: "avi", issued_by: "review_claim") # no review claim holds it

    board = board_for([built, lapsed].map(&:reload))
    render board.card(built, crew_board: :build)
    render board.card(lapsed, crew_board: :deploy)

    assert_equal "carl", card_for(built).css("[data-test='task-card-soul']").first["data-soul"]
    assert_empty card_for(lapsed).css("[data-test='task-card-soul']")
  end

  test "test_no_query_with_preloads: a card built from the page batch issues no query" do
    tasks = Task::STAGES.map do |stage|
      task = Task.create!(title: "Component no query #{stage}", stage: stage, epic_slug: "devops-v3",
                          metadata: { "devops" => { "pr_url" => "https://github.com/acme/app/pull/9" } })
      task.task_events.create!(kind: "intent", from_stage: stage, to_stage: Task::STAGES.last, actor: "carl", occurred_at: 1.hour.ago)
      Activity.create!(task_slug: task.slug, activity_type: "comment", description: "a note")
      studio_session(task, soul: "carl", issued_by: "task_claim")
      task
    end
    loaded = Task.where(slug: tasks.map(&:slug)).includes(:task_events, :gate_runs).to_a
    board = board_for(loaded)
    render board.card(loaded.first, crew_board: :deploy) # warms the per-process memos

    batched = count_queries { loaded.each { |task| render board.card(task, crew_board: :deploy) } }
    assert_empty batched, "the card queried on its own:\n#{batched.join("\n")}"

    # The control: the same cards with single-card preloads read per task.
    single = count_queries do
      loaded.each { |task| render TaskCardComponent.new(task: task, preloads: TaskCardComponent::Preloads.for_task(task)) }
    end
    assert_operator single.size, :>=, loaded.size, "the counter sees a per-card read when one runs"
  end

  test "every input is required: a caller cannot leave one for the card to look up" do
    task = Task.create!(title: "Component required inputs card", stage: "designed")
    complete = task_card_preloads(task).to_h

    complete.each_key do |input|
      assert_raises(ArgumentError, "#{input} is required") { TaskCardComponent::Preloads.new(**complete.except(input)) }
    end
    assert_raises(ArgumentError) { TaskCardComponent.new(task: task, preloads: complete) }
  end

  test "the delete action's hover tint is one the danger ink clears AA on" do
    task = Task.create!(title: "Component delete tint card", stage: "designed")

    render_task_card(task.reload)

    classes = card_for(task).css("[data-test='task-card-delete']").first["class"].split
    assert_includes classes, "hover:text-danger-ink"
    assert_includes classes, "hover:bg-danger/10"
    assert_empty classes.grep(%r{\Ahover:bg-danger/(?!10\z)}), "a stronger danger tint under danger ink misses AA"
  end

  # Each gallery preview renders, and building one writes nothing: the gallery
  # runs in production against the production database.
  test "every preview renders its card and writes nothing" do
    previews = TaskCardComponentPreview.instance_methods(false)
    assert_operator previews.size, :>=, 15

    writes = count_queries do
      previews.each do |name|
        card = preview(name).css(".kanban-card")
        assert_equal ["preview-#{name.to_s.dasherize}"], card.map { |node| node["data-slug"] }, "#{name} renders its card"
      end
    end.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)
    assert_empty writes
  end

  test "the soul previews show the logged-out card and one card per login" do
    assert_empty preview(:soul_logged_out).css("[data-test='task-card-soul']")

    { soul_builder_logged_in: "task_claim", soul_reviewer_logged_in: "review_claim" }.each do |name, login|
      assert_equal [login], preview(name).css("[data-test='task-card-soul']").map { |chip| chip["data-login"] }
    end
  end
end
