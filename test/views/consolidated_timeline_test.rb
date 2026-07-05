require "test_helper"

# [component] the consolidated stage-timeline partial — each transition renders as
# a standard container (from→to, the completing crew, measured duration, reported
# usage), and an open intent renders a live in-progress block with a ticker.
class ConsolidatedTimelineTest < ActionView::TestCase
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @carl    = Agent.create!(name: "Carl", slug: "carl")
    @agents  = Agent.all.to_a
  end

  test "renders a standard block per transition with crew, duration, and reported usage" do
    task = Task.create!(title: "component timeline task", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 3.hours.ago)
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 1.hour.ago, seconds_in_from: 9000, source: "cli",
                      model: "claude-opus-4-8", tokens_in: 1000, tokens_out: 2000, cost: "5.40", actor: "carl")

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='stage-timeline']"
    assert_select "[data-test='timeline-grid']"
    assert_select "[data-test='timeline-block']", minimum: 3
    # every card carries the uniform Model/Tokens/Cost/Duration metric block
    assert_select "[data-test='timeline-metrics']", minimum: 3
    assert_includes rendered, "claude-opus-4-8"
    assert_includes rendered, "5.40"
    assert_includes rendered, "3,000"          # tokens_total (1000 + 2000), delimited
    # Started → Completed footer, and an em dash for any unreported metric
    assert_includes rendered, "Started"
    assert_includes rendered, "Completed"
    assert_includes rendered, "—"
  end

  test "renders a live in-progress block with a ticker for an open review intent" do
    task = Task.create!(title: "component live task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed",
                             reviewers: [{ "slug" => "carl", "weight" => "primary" },
                                         { "slug" => "shannon", "weight" => "light" }])

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-inprogress']", count: 0 # pill removed
    assert_select "[data-test='timeline-pulse']"                # pulsing backdrop signals live work
    assert_select "[data-test='timeline-live']"                 # ticking duration
    assert_includes rendered, "Carl"
    assert_includes rendered, "Shannon"
    assert_includes rendered, "primary"
    # Light-mode contrast (regression guard for the PR #207 QA block): the live
    # ticker must be a bounded, theme-aware pill — not bare text-green-200 that is
    # invisible on the white light-mode surface (light is the no-JS default).
    assert_includes rendered, "text-green-700"
    assert_includes rendered, "dark:text-green-200"
  end

  test "renders active building on the Designed to Building card without appending a second build card" do
    Pokemon.create!(dex: 27, name: "Sandshrew", slug: "sandshrew", generation: 1)
    task = Task.create!(title: "component live building merge task", stage: "designed",
                        metadata: { "devops" => { "mascot" => "sandshrew" } })
    task.build!

    render partial: "tasks/consolidated_timeline",
           locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-block'][data-stage='building']", count: 1
    assert_select "[data-test='timeline-block'][data-stage='building'][data-in-progress='true']", count: 1
    assert_select "[data-test='timeline-block'][data-stage='submitted'][data-in-progress='true']", count: 0
    assert_select "[data-test='timeline-live']"
    assert_select "[data-test='timeline-transition']", text: /Designed.*Building/m
  end

  test "renders the blocking agent on a blocked transition card" do
    task = Task.create!(title: "blocked actor timeline task", stage: "blocked")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "blocked",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, source: "cli", actor: "shannon")

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-block'][data-stage='blocked']" do
      assert_select "[data-test='timeline-crew-member'][title^='Shannon']", count: 1
    end
  end

  # [integration] backward-compat: a →reviewed transition recorded BEFORE the
  # HEAVY→PRIMARY rename still carries weight "heavy" in its event metadata. The
  # timeline must render it identically to a new "primary" record — the deep-seat
  # pill text reads "primary" (via StageAgent#role_label) and wears the primary
  # styling — so no migration of the append-only metadata is needed.
  test "renders a legacy 'heavy' review record as a Primary seat" do
    task = Task.create!(title: "legacy heavy review task", stage: "reviewed")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "carl", "weight" => "heavy" },
                                                  { "slug" => "shannon", "weight" => "light" }] })

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_includes rendered, "Carl"
    assert_includes rendered, "Shannon"
    # the legacy "heavy" weight surfaces as the canonical "primary" label, never "heavy"
    assert_includes rendered, "primary", "a legacy heavy record displays the primary role"
    visible_text = css_select("[data-test='stage-timeline']").map(&:text).join(" ")
    refute_match(/\bheavy\b/i, visible_text, "the stale 'heavy' label is normalized away in visible UI")
    # and it wears the primary (deep) seat tooltip + accent styling
    assert_select "[title='Primary (deep) review']"
  end

  test "renders historical build mascots from event snapshots" do
    Pokemon.create!(dex: 87, name: "Dewgong", slug: "dewgong", generation: 1)
    Pokemon.create!(dex: 88, name: "Grimer", slug: "grimer", generation: 1)
    task = Task.create!(title: "component mascot history task", stage: "building",
                        metadata: { "devops" => { "mascot" => "grimer" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 5.hours.ago,
                      metadata: { "mascot" => { "slug" => "dewgong", "name" => "Dewgong" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: { "mascot" => { "slug" => "dewgong", "name" => "Dewgong" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600,
                      metadata: { "mascot" => { "slug" => "dewgong", "name" => "Dewgong" } })
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "blocked",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "blocked", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600,
                      metadata: { "mascot" => { "slug" => "grimer", "name" => "Grimer" } })

    render partial: "tasks/consolidated_timeline",
           locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-crew-member'][title^='Dewgong']", minimum: 3
    assert_select "[data-test='timeline-crew-member'][title^='Grimer']", count: 1
    assert_select "[data-test='timeline-block'][data-stage='building'][data-in-progress='true']", count: 1
  end

  test "renders the sizing trio strip (Avi PO, Dev, Actual) and flags an estimate miss" do
    task = Task.create!(title: "component sizing task", stage: "shipped",
                        po_size: "medium", dev_size: "large", actual_size: "xl")

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-sizing']"
    assert_includes rendered, "Avi"     # PO forecast is Avi's, the default sizer
    assert_includes rendered, "MEDIUM"  # po_size, upcased
    assert_includes rendered, "LARGE"   # dev_size
    assert_includes rendered, "XL"      # auto-derived actual_size
    # actual (xl) != PO forecast (medium) → estimate-miss flag, theme-aware amber
    assert_includes rendered, "forecast"
    assert_includes rendered, "dark:text-yellow-400"
  end

  test "omits the sizing strip when the task carries no sizes" do
    task = Task.create!(title: "component unsized task", stage: "designed")

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: @agents, events: task.task_events.to_a }

    assert_select "[data-test='timeline-sizing']", false
  end

  # A third-stage evolution (Charmeleon → Charizard at the assemble gate) renders its
  # own "Evolve" reel right after Reviewed → Assembled, and that assembled card is
  # left to Steffon alone (its mascot companion moved onto the reel).
  test "renders an Evolve reel card after Reviewed to Assembled and leaves Steffon alone" do
    Agent.create!(name: "Steffon", slug: "steffon")
    task = Task.create!(title: "component evolve card task")
    task.task_events.delete_all
    snap = ->(slug) { { "mascot" => { "slug" => slug, "name" => slug.capitalize, "avatar" => "https://example.test/#{slug}.png" } } }
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600, actor: "carl", metadata: snap["charmeleon"])
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600,
                      metadata: snap["charmeleon"].merge("reviewers" => [{ "slug" => "carl", "weight" => "primary" },
                                                                          { "slug" => "shannon", "weight" => "light" }]))
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon", metadata: snap["charizard"])
    task.update_columns(stage: "assembled")

    render partial: "tasks/consolidated_timeline", locals: { task: task.reload, agents: Agent.all.to_a, events: task.task_events.to_a }

    # the reel — its own card, badged "Evolve", showing prior form → evolved form
    assert_select "[data-test='timeline-block'][data-stage='evolve']", count: 1
    assert_select "[data-test='timeline-evolution']"
    assert_includes rendered, "Evolve"
    assert_select "[data-test='timeline-evolution-from']", text: /Charmeleon/
    assert_select "[data-test='timeline-evolution-to']", text: /Charizard/
    assert_select "[data-test='timeline-evolution-trigger']", text: /Steffon/

    # it shares the standard card anatomy: badge on top, then a metric block and a
    # Started → Completed footer (model/tokens/cost blank — duration + stamps only)
    assert_select "[data-test='timeline-block'][data-stage='evolve'] [data-test='timeline-metrics']", count: 1
    assert_select "[data-test='timeline-block'][data-stage='evolve']", text: /Started/
    assert_select "[data-test='timeline-block'][data-stage='evolve']", text: /Completed/

    # the real Reviewed → Assembled card carries Steffon, NOT the mascot companion
    assert_select "[data-test='timeline-block'][data-stage='assembled'] [data-test='timeline-crew-member'][title^='Steffon']", count: 1
    assert_select "[data-test='timeline-block'][data-stage='assembled'] [data-test='timeline-crew-member'][title^='Charizard']", count: 0
  end
end
