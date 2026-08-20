require "test_helper"
require_relative "../support/devops_key_spread"

class TasksControllerTest < ActionDispatch::IntegrationTest
  include DevopsKeySpread

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @new_task = tasks(:new_task)
    @queued_task = tasks(:queued_task)
    @in_progress_task = tasks(:in_progress_task)
    @done_task = tasks(:done_task)
    @failed_task = tasks(:failed_task)
  end

  # === HTML page tests ===

  test "index renders tasks page" do
    get tasks_path
    assert_response :success
    assert_select "h2", "Tasks"
  end

  test "[component] task cards use shared JSON routes and distinct exit animations" do
    get tasks_path

    assert_response :success
    assert_select "button[data-test='task-card-archive']"
    assert_select "button[data-test='task-card-delete']"
    # Archive/delete are the OUTER taskBoardChrome writes (the app half of the board
    # primitive rebase), hitting the SHARED task JSON routes — no per-action archive
    # endpoint: PATCH stage=archived, DELETE the task.
    assert_includes response.body, "fetch('/tasks/' + slug + '.json'"
    assert_includes response.body, "method: 'PATCH'"
    assert_includes response.body, "method: 'DELETE'"
    # Distinct exit animations: the app passes a distinct kind to the studio/board
    # primitive's animateCardExit, which branches archive vs delete.
    assert_includes response.body, "this.boardExit(card, 'archive')"
    assert_includes response.body, "this.boardExit(card, 'delete')"
    assert_includes response.body, 'kind === "archive"'
    assert_not_includes response.body, "/tasks/' + slug + '/archive.json"
  end

  test "[component] show renders the testing-phases card with per-phase durations" do
    task = Task.create!(title: "Phase Card Probe", slug: "phase-card-probe")
    task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      testing_phases_version: Task::TestingPhases::VERSION,
      testing_phases: { "phases" => {
        "build" => { "status" => "completed", "seconds" => 600 },
        "local_certification" => { "status" => "completed", "seconds" => 300 },
        "ci" => { "status" => "missing" },
        "review" => { "status" => "in_progress", "seconds" => 120 }
      } }
    )

    get task_path(task.slug)

    assert_response :success
    assert_select "h3", text: "Testing phases"
    assert_select "p.label-upper", text: "Local Certification"
    assert_select "p.label-upper", text: "Review"
    # Operator Acceptance left the task projection in v2 — no fifth tile.
    assert_select "p.label-upper", text: "Operator Acceptance", count: 0
  end

  test "[component] show renders the testing-gates card from the latest gate attempts" do
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", success: false)
    GateRun.open!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert")
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", success: true,
                   sops: [{ "sop" => "full-suite", "result" => "pass", "duration_ms" => 8000 },
                          { "sop" => "dor-check", "result" => "pass" }])
    GateRun.open!(subject_type: "task", subject_slug: @new_task.slug, key: "g2a_primary", actor: "carl")

    get task_path(@new_task.slug)

    assert_response :success
    assert_select "h3", text: "Testing gates"
    assert_select "p.label-upper", text: "G1 Cert"
    assert_select "p.label-upper", text: "G2a Primary"
    assert_select "p.label-upper", text: "G2b Light"
    assert_includes response.body, "attempt 2" # the failed first attempt stays visible as a retry count
    assert_select "p", text: "Passed"     # g1 verdict chip
    assert_select "p", text: "In flight"  # g2a open lane
    assert_select "p", text: "Not run"    # g2b untouched
    assert_select "summary", text: /2 SOPs/
  end

  test "[component] show omits the testing-gates card when no gate has run" do
    get task_path(@new_task.slug)

    assert_response :success
    assert_select "h3", text: "Testing gates", count: 0
  end

  test "[integration] show renders the DoR gate chips when dor gate runs exist" do
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "dor", success: true,
                   sops: [{ "sop" => "dor-check", "result" => "pass" }])
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "dor_review", success: false,
                   sops: [{ "sop" => "ci", "result" => "fail" }])

    get task_path(@new_task.slug)

    assert_response :success
    assert_select "h3", text: "Testing gates"
    assert_select "p.label-upper", text: "DoR (builder)"
    assert_select "p.label-upper", text: "DoR (review)"
    assert_select "p", text: "Passed"  # dor builder verdict
    assert_select "p", text: "Failed"  # dor_review verdict
  end

  test "[integration] json patch archives through the shared task update path" do
    log_in_as(@admin)

    patch task_path(@new_task.slug, format: :json), params: { task: { stage: "archived" } }

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal "archived", @new_task.reload.stage
  end

  test "deployments shows the current-release header when a release exists" do
    rel = Release.open!(branch: "release/header-test", qa_url: "https://qa.example/tasks", deployed_sha: "abc1234def567")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)
    rel.assemble!

    get deployments_path

    assert_response :success
    assert_select "#current-release"
    assert_select "#current-release", text: /#{Regexp.escape(rel.slug)}/
    assert_select "#current-release [data-test='release-state-badge']", text: /\AAssembled at .+\z/ # consolidated state + "at" stamp
    assert_select "#current-release a[href=?]", task_path(@new_task.slug) # member chip
    # "when present" fields render
    assert_select "#current-release a[href=?]", "https://qa.example/tasks" # QA link
    assert_includes response.body, "abc1234" # deployed SHA (7-char)
  end

  test "[integration] current release gets animated border glow once confirming starts" do
    Release.delete_all
    rel = Release.open!(branch: "release/confirming-glow")

    get deployments_path
    assert_response :success
    assert_select "#current-release.release-confirming-glow", count: 0
    assert_select "#current-release.studio-border-glow", count: 0

    rel.stamp_stage!("confirming")

    get deployments_path
    assert_response :success
    card = css_select("#current-release").first
    assert_equal "confirming", card["data-stage-glow"]
    assert_includes card["class"], "studio-border-glow"
    assert_includes card["class"], "release-confirming-glow"
    assert_includes card["style"], "--task-card-glow-color-a: #fb0094"
    assert_includes card["style"], "--task-card-glow-color-b: #00c4ff"
    assert_includes card["style"], "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 58%, transparent)"
    assert_includes card["style"], "0 0 118px color-mix(in srgb, var(--task-card-glow-color) 12%, transparent)"
  end

  test "[integration] deployments renders the three heartbeat launchers in the Heartbeats card" do
    Agent.find_or_create_by!(slug: "avi") { |a| a.name = "Avi" }
    Agent.find_or_create_by!(slug: "steffon") { |a| a.name = "Steffon" }
    Agent.find_or_create_by!(slug: "alex") { |a| a.name = "Alex" }

    get deployments_path

    assert_response :success
    # The launchers live in the Heartbeats card, NOT the current-release or DevOps cards.
    assert_select "#current-release [data-test='heartbeat-launcher']", count: 0
    assert_select "#release-duration-card [data-test='heartbeat-launcher']", count: 0
    assert_select "[data-test='heartbeats-card'] [data-test='heartbeat-launcher']", count: 4
    # The card is launchers-only — a plain 4-up grid of the soul launchers, no release
    # tracker and no stage-ownership layout (that pairing was the rejected design; the
    # tracker stays in the Next Release card).
    # Each avatar links to the soul's /agents/<slug> page.
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] a[data-test='heartbeat-avatar-link'][href='/agents/carl']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] a[data-test='heartbeat-avatar-link'][href='/agents/avi']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] a[data-test='heartbeat-avatar-link'][href='/agents/steffon']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] a[data-test='heartbeat-avatar-link'][href='/agents/alex']"
    # Each launcher exposes a prompt-like heartbeat row (row 1) plus its atom action rows —
    # Carl owns pr-review + pr-review-slow, Avi owns qa-release, Steffon owns
    # production-deploy, Alex carries full-cycle.
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] button[data-row='heartbeat'][data-clip='Carl Heartbeat']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] button[data-row='action'][data-clip='pr-review']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] button[data-row='action'][data-clip='pr-review-slow']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] button[data-row='heartbeat'][data-clip='Avi Heartbeat']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] button[data-row='action'][data-clip='qa-release']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] button[data-row='action'][data-clip='production-deploy']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] button[data-row='action'][data-clip='grade-events']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] button[data-row='action'][data-clip='full-cycle']"
  end

  test "[integration] deployments shows the conductor mascot + in-progress timing on the Next Release card" do
    Release.delete_all
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1,
                    sprite_url: "https://example.test/snorlax.png")
    rel = Release.open!
    rel.update!(metadata: { "devops" => { "mascot" => "snorlax", "mascot_session" => "sess-x" } })

    get deployments_path

    assert_response :success
    assert_select "#current-release [data-test='release-mascot'] img[src=?]", "https://example.test/snorlax.png"
    assert_select "#current-release [data-test='release-mascot']", text: /Snorlax/
    assert_select "#current-release [data-test='release-timing']", text: /\Ain progress · /
  end

  test "[integration] deployments shows the conductor mascot + 'took' duration on the Last Release card" do
    Release.delete_all
    Pokemon.create!(dex: 149, name: "Dragonite", slug: "dragonite", types: %w[dragon flying], generation: 1,
                    sprite_url: "https://example.test/dragonite.png")
    shipped = Release.open!
    shipped.update!(metadata: { "devops" => { "mascot" => "dragonite", "mascot_session" => "sess-y" } })
    shipped.ship!
    shipped.update_columns(created_at: 18.minutes.ago, shipped_at: Time.current)

    get deployments_path

    assert_response :success
    assert_select "#last-release [data-test='release-mascot'] img[src=?]", "https://example.test/dragonite.png"
    assert_select "#last-release [data-test='release-mascot']", text: /Dragonite/
    assert_select "#last-release [data-test='release-timing']", text: /\Atook /
  end

  test "[component] deployments shows a 🟢 smoke-seal badge on a green-sealed Last Release" do
    Release.delete_all
    shipped = Release.open!
    shipped.ship!
    shipped.record_smoke_seal!(Release::SmokeSeal.from_result(passed: true, summary: "@qa-readonly green vs prod"))

    get deployments_path

    assert_response :success
    assert_select "#last-release [data-test='release-smoke-seal-badge'][data-seal-status='green']", text: /🟢 Seal/
  end

  test "[component] deployments shows a 🔴 smoke-seal badge on a red-sealed Last Release" do
    Release.delete_all
    shipped = Release.open!
    shipped.ship!
    shipped.record_smoke_seal!(Release::SmokeSeal.from_result(passed: false, summary: "2 specs failed"))

    get deployments_path

    assert_response :success
    assert_select "#last-release [data-test='release-smoke-seal-badge'][data-seal-status='red']", text: /🔴 Seal/
  end

  test "[component] an unsealed release renders NO smoke-seal badge" do
    Release.delete_all
    shipped = Release.open!
    shipped.ship!

    get deployments_path

    assert_response :success
    assert_select "#last-release [data-test='release-smoke-seal-badge']", count: 0
    assert_select "#last-release [data-test='release-state-badge']", count: 1, text: /\AShipped/
  end

  test "deployments rides release workflow chips inline with the task pills" do
    Release.delete_all
    rel = Release.open!(branch: "release/qa-kickoff")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)

    get deployments_path

    assert_response :success
    # The four legacy release chips were retired; the current-release card no longer
    # carries them. The task pill still shares the members row.
    assert_select "#current-release [data-test='release-members-row']" do
      assert_select "a[href=?]", task_path(@new_task.slug)  # the task pill
    end
    assert_select "#current-release code", { text: /Avi Heartbeat Slow/, count: 0 }
    assert_select "#current-release code", { text: /Merge, Assemble, Deploy/, count: 0 }
    # The launchers now live in the Heartbeats card — one per soul, including
    # Carl's pr-review-slow and Alex's full-cycle acts.
    assert_select "[data-test='heartbeats-card'] [data-test='heartbeat-launcher']", count: 4
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] code", text: "pr-review-slow"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] code", text: "full-cycle"
  end

  test "deployments renders the status badge on the current release card" do
    Release.delete_all
    rel = Release.open!(branch: "release/badge-order")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)
    rel.assemble!

    get deployments_path
    assert_response :success

    # The status badge still pins to the card's top-right corner (the retired chips
    # no longer share that row).
    assert_select "#current-release [data-test='release-state-badge']", count: 1
  end

  test "deployments release cards omit the redundant 'release' branch label" do
    Release.delete_all
    shipped = Release.open!(branch: "release")
    shipped.ship!
    active = Release.open!(branch: "release")
    @new_task.update!(stage: "reviewed")
    active.add(@new_task)

    get deployments_path
    assert_response :success

    # the bare branch name no longer renders as a code chip in either card header
    assert_select "#current-release code", { text: "release", count: 0 },
                  "the redundant 'release' branch label must be gone from the Next Release card"
    assert_select "#last-release code", { text: "release", count: 0 },
                  "the redundant 'release' branch label must be gone from the Last Release card"
  end

  test "deployments rides the Archive completed tasks chip inline with the Last Release pills" do
    Release.delete_all
    shipped = Release.open!(branch: "release")
    @new_task.update!(stage: "reviewed")
    shipped.add(@new_task)
    shipped.assemble!
    shipped.ship!

    get deployments_path
    assert_response :success

    # Last Release gets its own copy/paste kickoff chip ("Archive completed tasks"),
    # inline (right) with the task pills, same style as the Next Release chip.
    assert_select "#last-release [data-test='release-members-row']" do
      assert_select "a[href=?]", task_path(@new_task.slug)  # the task pill
      assert_select "code", text: /Archive completed tasks/ # the kickoff chip
    end
  end

  test "board header toggle shows building / reviewed / assembled count badges" do
    # Counts are global (load_board groups every stage), so derive the expected
    # numbers the same way the view does — robust to whatever the fixtures hold.
    3.times { |i| Task.create!(title: "fresh building #{i}", stage: "building") }
    Task.create!(title: "fresh reviewed task", stage: "reviewed")
    2.times { |i| Task.create!(title: "fresh assembled #{i}", stage: "assembled") }

    building  = Task.where(stage: "building").count
    reviewed  = Task.where(stage: "reviewed").count
    assembled = Task.where(stage: "assembled").count

    # On /tasks the Tasks button is hidden (redundant with the title); the
    # Deployments button shows with its reviewed + assembled badges.
    get tasks_path
    assert_response :success
    assert_select %(nav[aria-label="Board views"]) do
      assert_select %(a[href="#{deployments_path}"]), { minimum: 1 }
      assert_select %(a[href="#{tasks_path}"]), { count: 0 }
      assert_select %(span[title="#{reviewed} reviewed"]), text: reviewed.to_s
      assert_select %(span[title="#{assembled} assembled"]), text: assembled.to_s
    end

    # On /deployments the Tasks button shows with its building badge.
    get deployments_path
    assert_response :success
    assert_select %(nav[aria-label="Board views"] span[title="#{building} building"]), text: building.to_s
  end

  test "[component] deployments links to /tasks/recent in the board sections nav" do
    # The Recent link surfaces the /tasks/recent recency list and rides in the
    # Deploy lane's board-sections nav beside Pipeline + Insights. It is scoped
    # to /deployments only — the Build board (/tasks) must not render it.
    get deployments_path
    assert_response :success
    assert_select %(nav[aria-label="Board sections"] a[href="#{recent_tasks_path}"]),
      { minimum: 1 }, "deployments should link to /tasks/recent in the board sections nav"

    get tasks_path
    assert_response :success
    assert_select %(nav[aria-label="Board sections"] a[href="#{recent_tasks_path}"]),
      { count: 0 }, "the Recent link is scoped to the deployments lane only"
  end

  test "deployments hides the redundant Tasks link above the full-width breakpoint" do
    # At full width the six-lane Deploy board already shows the whole Build lane
    # (designed · building · submitted), so the Tasks link is redundant and is
    # hidden at 1400px+ — the complement of the board's max-[1399px] collapse.
    get deployments_path
    assert_response :success
    tasks_link = css_select(%(nav[aria-label="Board views"] a[href="#{tasks_path}"])).first
    assert tasks_link, "deployments should still render the Tasks link (for the collapsed narrow view)"
    assert_includes tasks_link["class"], "min-[1400px]:hidden",
      "the Tasks link should hide at 1400px+ on /deployments"

    # /stages has no board, so nothing makes the Tasks link redundant — it stays
    # visible at every width.
    get stages_path
    assert_response :success
    stages_tasks_link = css_select(%(nav[aria-label="Board views"] a[href="#{tasks_path}"])).first
    assert stages_tasks_link, "stages should render the Tasks link"
    assert_not_includes stages_tasks_link["class"], "min-[1400px]:hidden",
      "the Tasks link must not be width-hidden on /stages"
  end

  test "[component] deployments board links to the cross-session Activities view" do
    get deployments_path
    assert_response :success
    # the reimagined /agents/activities feed, not the old /alex/heartbeat/activities page
    assert_select %(nav[aria-label="Board sections"] a[href="#{activities_agents_path}"]),
      text: "🎭 Activities",
      count: 1
    assert_select %(nav[aria-label="Board sections"] a[href="#{heartbeat_all_activities_path}"]), count: 0
  end

  test "[component] deployments board links to the Alex pipeline and insights" do
    get deployments_path
    assert_response :success
    assert_select %(nav[aria-label="Board sections"] a[href="#{alex_pipeline_path}"]),
      text: "Pipeline",
      count: 1
    assert_select %(nav[aria-label="Board sections"] a[href="#{alex_insights_path}"]),
      text: "Insights",
      count: 1
  end

  test "[component] pipeline and insights links stay off the other board surfaces" do
    # The OPSD surfaces belong to the Deploy lane; tasks + stages keep the
    # shorter nav.
    [tasks_path, stages_path].each do |path|
      get path
      assert_response :success
      assert_select %(nav[aria-label="Board sections"] a[href="#{alex_pipeline_path}"]), { count: 0 },
        "expected no Pipeline link on #{path}"
      assert_select %(nav[aria-label="Board sections"] a[href="#{alex_insights_path}"]), { count: 0 },
        "expected no Insights link on #{path}"
    end
  end

  test "[component] deployments older links move into the header menu" do
    get deployments_path
    assert_response :success

    assert_select %(nav[aria-label="Board sections"] a[href="#{stages_path}"]), count: 0
    assert_select %([data-test="deployment-link-menu"] a[href="#{stages_path}"]),
      text: "Stages",
      count: 1
    assert_select %([data-test="deployment-link-menu"] a[href="#{review_events_hub_path}"]),
      text: "Docs",
      count: 1
    assert_select %([data-test="submitted-review-docs-link"]), count: 0
  end

  test "[component] the Activities link rides every board surface" do
    # _board_top_links is shared, so the shortcut shows on tasks + stages too.
    [tasks_path, stages_path].each do |path|
      get path
      assert_response :success
      assert_select %(nav[aria-label="Board sections"] a[href="#{activities_agents_path}"]),
        { text: "🎭 Activities", count: 1 },
        "expected the Activities link on #{path}"
    end
  end

  test "[component] the Pokedex link rides every board surface" do
    [tasks_path, deployments_path, stages_path].each do |path|
      get path
      assert_response :success
      assert_select %(nav[aria-label="Board sections"] a[href="#{pokedex_path}"]),
        { text: "Pokédex", count: 1 },
        "expected the Pokédex link on #{path}"
    end
  end

  test "board header omits the removed All Agents agent filter" do
    get tasks_path
    assert_response :success
    assert_not_includes response.body, "All Agents"
  end

  test "toggle count badge renders even at zero so the glance count never vanishes" do
    # building tasks are never release members, so clearing them is FK-safe.
    Task.where(stage: "building").delete_all
    # The building badge rides the Tasks button, which shows on /deployments
    # (it is hidden on /tasks as redundant with the title).
    get deployments_path
    assert_response :success
    assert_select %(nav[aria-label="Board views"] span[title="0 building"]), text: "0"
  end

  test "deployments shows the heartbeat launchers when no release exists" do
    Release.delete_all
    %w[avi steffon alex].each { |s| Agent.find_or_create_by!(slug: s) { |a| a.name = s.titleize } }

    get deployments_path

    assert_response :success
    assert_select "#current-release", text: /none active/
    # The four legacy chips were retired from the current-release card.
    assert_select "#current-release code", { text: /Avi Heartbeat Slow/, count: 0 }
    # The Heartbeats card still offers the launchers even with no active release.
    assert_select "[data-test='heartbeats-card'] [data-test='heartbeat-launcher']", count: 4
    # With nothing shipped, Last Release shows its muted empty state (keeps the 2×2 cell).
    assert_select "#last-release", text: /none yet/
  end

  test "[component] deployments renders the release duration intelligence card" do
    Release.delete_all
    shipped = Release.create!(slug: "rel-dashboard-metrics", branch: "release", state: "shipped")
    shipped.update_columns(created_at: 45.minutes.ago, shipped_at: 5.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
    task = Task.create!(title: "duration dashboard member task", stage: "shipped", release_slug: shipped.slug)
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, kind: "intent", from_stage: "designed", to_stage: "building",
                      occurred_at: 35.minutes.ago, actor: "builder")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 25.minutes.ago, seconds_in_from: 10.minutes.to_i,
                      actor: "builder", source: "cli", model: "gpt-5",
                      tokens_in: 1000, tokens_out: 250, cost: "0.0500")
    Release::DurationCache.refresh!(shipped)

    get deployments_path

    assert_response :success
    assert_select "#release-duration-card"
    assert_select "#release-duration-card a[href=?]", all_deployments_path, text: /All Deployments/
    # Release-centric phases now (Deploy + Total), not the per-task Building span.
    assert_select "#release-duration-card", text: /Deploy/
    assert_select "#release-duration-card", text: /Total/
    assert_select "#release-duration-card", { text: /Building/, count: 0 }
    assert_select "#release-duration-card h3", text: /DevOps/
    assert_select "#release-duration-card", text: /Release Times/, count: 0
    assert_select "#release-duration-card", text: /shipped releases/, count: 0
    # The redundant "Sample: N shipped releases" footer was removed (it echoed the
    # card's duration metrics); the zero-state message still shows when empty.
    assert_select "#release-duration-card", { text: /Sample:/, count: 0 },
                  "the 'Sample: N shipped releases' footer must not render"
  end

  # The WIP tile end to end: the number on the page is the board's real count of
  # open tasks, and it MOVES with the board. Asserting the advance (ship one task,
  # the tile drops by one) is what separates a live count from a hardcoded label —
  # a static assertion would pass against a tile that never reads the database.
  test "[integration] the DevOps card's WIP tile counts the open pipeline and tracks it" do
    Task.delete_all
    %w[designed building submitted reviewed assembled].each do |stage|
      Task.create!(title: "wip page #{stage} task", stage: stage)
    end
    # Terminal work is not in flight — neither of these may reach the tile.
    Task.create!(title: "wip page shipped task", stage: "shipped")
    Task.create!(title: "wip page archived task", stage: "archived")

    get deployments_path
    assert_response :success
    assert_select "[data-test='release-duration-wip']", text: /WIP/
    assert_select "[data-test='release-duration-wip']", text: /5/
    assert_select "#release-duration-card", text: /WIP/

    # Ship one member: the pipeline shrinks and so must the tile.
    Task.find_by!(title: "wip page assembled task").update!(stage: "shipped")

    get deployments_path
    assert_response :success
    assert_select "[data-test='release-duration-wip']", text: /4/
  end

  # The tile is the PIPELINE's number, not the current view's. The board's agent
  # filter narrows the columns; it must not narrow WIP, or a per-agent view would
  # quietly under-report how much work is open.
  test "[integration] the agent filter narrows the board columns but not the WIP tile" do
    Task.delete_all
    Task.create!(title: "wip filter alex task", stage: "building", agent_slug: "alex")
    Task.create!(title: "wip filter other task", stage: "building", agent_slug: "avi")
    Task.create!(title: "wip filter third task", stage: "submitted", agent_slug: "avi")

    get deployments_path(agent_slug: "alex")
    assert_response :success
    assert_select "[data-test='release-duration-wip']", text: /3/
  end

  test "[integration] deployments cards carry a data-glow attribute for the live glow" do
    # The live board tints each card's create/move glow from data-glow (the mascot's
    # type colour); it's present on every card (empty when the task has no mascot).
    task = Task.create!(title: "A glowing board task", stage: "designed")
    get deployments_path
    assert_response :success
    assert_select "#card-#{task.slug}[data-glow]"
  end

  test "[integration] deployments cards glow for deploy lane attention stages" do
    submitted = Task.create!(
      title: "Submitted glow board task",
      stage: "submitted",
      metadata: { "devops" => { "mascot_color" => "#6390F0", "repositories" => ["mcritchie-studio"] } }
    )
    reviewed = Task.create!(
      title: "Reviewed glow board task",
      stage: "reviewed",
      metadata: { "devops" => { "mascot_color" => "#22d3ee", "repositories" => ["mcritchie-studio"] } }
    )
    assembled = Task.create!(
      title: "Assembled glow board task",
      stage: "assembled",
      metadata: { "devops" => { "mascot_color" => "#a78bfa", "repositories" => ["mcritchie-studio"] } }
    )
    blocked = Task.create!(title: "Blocked glow board task", stage: "building")
    blocked.block!(by: "avi", kind: "rework")

    get deployments_path
    assert_response :success

    # Queued for review, nobody on it: dark. The ring belongs to a LIVE review, and
    # it only reads as one while its neighbours are unlit.
    submitted_card = css_select("#card-#{submitted.slug}").first
    assert_nil submitted_card["data-stage-glow"]
    assert_not_includes submitted_card["class"], "studio-border-glow"
    assert_not_includes submitted_card["class"], "studio-team-glow"

    reviewed_card = css_select("#dropzone-reviewed #card-#{reviewed.slug}").first
    assert_equal "reviewed", reviewed_card["data-stage-glow"]
    assert_includes reviewed_card["class"], "studio-border-glow"
    assert_includes reviewed_card["class"], "task-card-stage-glow-reviewed"
    assert_includes reviewed_card["style"], "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 52%, transparent)"
    assert_includes reviewed_card["style"], "0 0 64px color-mix(in srgb, var(--task-card-glow-color) 16%, transparent)"

    assembled_card = css_select("#dropzone-assembled #card-#{assembled.slug}").first
    assert_equal "assembled", assembled_card["data-stage-glow"]
    assert_includes assembled_card["class"], "studio-border-glow"
    assert_includes assembled_card["class"], "task-card-stage-glow-assembled"
    assert_match(/--studio-border-glow-offset: \d+%;/, assembled_card["style"])
    assert_match(/--studio-border-glow-duration: \d+s;/, assembled_card["style"])
    assert_match(/--studio-border-glow-angle: \d+deg;/, assembled_card["style"])
    assert_includes assembled_card["style"], "--task-card-glow-color-a: #a78bfa"
    assert_includes assembled_card["style"], "--task-card-glow-color-b: #a78bfa"
    assert_includes assembled_card["style"], "0 0 118px color-mix(in srgb, var(--task-card-glow-color-b) 12%, transparent)"

    blocked_card = css_select("#dropzone-building #card-#{blocked.slug}").first
    assert_equal "blocked", blocked_card["data-stage-glow"]
    assert_includes blocked_card["class"], "task-card-stage-glow-blocked"
    assert_not_includes blocked_card["class"], "studio-border-glow"
    assert_includes blocked_card["style"], "--task-card-glow-color: #ef4444"
  end

  # THE RING TRACKS THE REVIEWER, THROUGH THE REAL PREDICATE. The component test
  # passes review_in_progress in as a local; this drives the board end to end —
  # an open →reviewed intent plus a live claim — so the wiring between
  # Task#review_in_progress?, the board's preloaded map, and the card is covered.
  # Two cards in the same column, one claimed and one not, is the assertion that
  # matters: the ring has to DISTINGUISH them.
  test "[integration] only the submitted card under a live review wears the ring" do
    claimed = Task.create!(title: "Claimed review board task", stage: "submitted",
                           metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    queued  = Task.create!(title: "Queued review board task", stage: "submitted",
                           metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    claimed.task_events.delete_all
    claimed.record_intent_event(to_stage: "reviewed",
                                reviewers: [{ "slug" => "carl", "weight" => "primary" }])
    TaskReviewClaim.acquire(task_slug: claimed.slug, session: "sess-review", nonce: "inst-review",
                            reviewer: "carl")
    assert claimed.reload.review_in_progress?, "fixture must have a LIVE review"
    assert_not queued.reload.review_in_progress?

    get deployments_path
    assert_response :success

    claimed_card = css_select("#card-#{claimed.slug}").first
    assert_equal "review", claimed_card["data-stage-glow"]
    assert_includes claimed_card["class"], "studio-team-glow"
    assert_includes claimed_card["class"], "task-card-review-glow"
    assert_includes claimed_card["style"], "--studio-team-glow-color:"
    assert_includes claimed_card["style"], "--studio-team-glow-color-b:"

    queued_card = css_select("#card-#{queued.slug}").first
    assert_nil queued_card["data-stage-glow"]
    assert_not_includes queued_card["class"], "studio-team-glow"
  end

  test "deployments shows a Last Release section + Current empty state when nothing is active" do
    Release.delete_all
    shipped = Release.open!(branch: "release/last-test",
                            qa_url: "https://qa.example/last",
                            deployed_sha: "9999abcdef000")
    @new_task.update!(stage: "reviewed")
    shipped.add(@new_task)
    shipped.assemble!
    shipped.ship!

    get deployments_path
    assert_response :success

    # No active release → Current shows the muted empty state, NOT the shipped
    # release dressed up as "current". The launchers live in the Pipeline card.
    assert_select "#current-release", text: /none active/
    assert_select "#current-release", { text: /#{Regexp.escape(shipped.slug)}/, count: 0 },
                  "shipped release must NOT appear under Current"

    # The shipped release lives in the read-only Last Release section.
    assert_select "#last-release"
    assert_select "#last-release", text: /Last Release/
    assert_select "#last-release", text: /#{Regexp.escape(shipped.slug)}/
    assert_select "#last-release [data-test='release-state-badge']", text: /\AShipped at .+\z/ # consolidated state + "at" stamp
    assert_select "#last-release a[href=?]", task_path(@new_task.slug) # member chip
    assert_select "#last-release a[href=?]", "https://qa.example/last" # QA link
    assert_includes response.body, "9999abc" # deployed SHA (7-char)
  end

  test "deployments folds the release state + shipped time into one top-right badge" do
    # ui-only consolidation: the card used to carry BOTH a bare "shipped" state pill
    # (left, beside the slug) AND a separate muted "shipped X ago" line (right). They
    # are now ONE state-colored badge reading "Shipped at <clock>" in the header — no
    # duplicate state, no redundant timestamp line. The relative read the badge used
    # to show lives in its hover title.
    Release.delete_all
    shipped = Release.open!(branch: "release/badge-consolidation")
    @new_task.update!(stage: "reviewed")
    shipped.add(@new_task)
    shipped.assemble!
    shipped.ship!

    get deployments_path
    assert_response :success

    # exactly one status badge, folding state + the "at" stamp together
    assert_select "#last-release [data-test='release-state-badge']", count: 1 do |els|
      assert_match(/\AShipped at \d{1,2}:\d{2}[ap]\z/, els.first.text.strip)
    end
    # the badge's stamp is the shared "at" primitive, carrying the epoch the client
    # re-stamps to the viewer's clock — not a server-frozen string.
    assert_select "#last-release [data-test='release-state-badge'] time[data-at-stamp][data-at-epoch]", count: 1
    # the badge keeps the shipped (green) state color
    assert_select "#last-release [data-test='release-state-badge'].bg-green-900\\/50", count: 1
    # the separate muted "shipped X ago" line is gone (was the only text-muted "ago" span)
    assert_select "#last-release span.text-muted", { text: /ago/, count: 0 },
                  "the redundant 'shipped X ago' line must be folded into the badge"
  end

  test "deployments Last Release renders a chip + working link for an ARCHIVED member" do
    # Operator requirement: archiving a shipped task must NOT break the board's
    # Last-Release history — rel.tasks fetches members by release_slug regardless
    # of stage, so an archived member still renders a chip + a working task_path.
    Release.delete_all
    shipped = Release.open!(branch: "release/archived-member")
    @new_task.update!(stage: "reviewed")
    shipped.add(@new_task)    # member: release_slug set, stage → assembled
    shipped.assemble!
    shipped.ship!             # member → shipped
    @new_task.reload.archive! # archive the member AFTER ship; release_slug preserved

    get deployments_path
    assert_response :success

    assert_select "#last-release", text: /#{Regexp.escape(shipped.slug)}/
    # The archived member is still listed with a WORKING task_path link.
    assert_select "#last-release a[href=?]", task_path(@new_task.slug)
    assert_equal "archived", @new_task.reload.stage
    assert_equal shipped.slug, @new_task.reload.release_slug
  end

  test "task show renders an archived task (HTTP 200)" do
    @new_task.update!(stage: "shipped")
    @new_task.archive!

    get task_path(@new_task.slug)
    assert_response :success
    assert_equal "archived", @new_task.reload.stage
  end

  test "deployments renders Current (active) and Last (shipped) as distinct sections" do
    Release.delete_all
    shipped = Release.open!(branch: "release/shipped-distinct")
    shipped.ship!
    active = Release.open!(branch: "release/active-distinct")
    @new_task.update!(stage: "reviewed")
    active.add(@new_task)

    get deployments_path
    assert_response :success

    # Current = the active in-progress release only.
    assert_select "#current-release", text: /#{Regexp.escape(active.slug)}/
    assert_select "#current-release", { text: /#{Regexp.escape(shipped.slug)}/, count: 0 }
    # Last = the most-recent shipped release only.
    assert_select "#last-release", text: /#{Regexp.escape(shipped.slug)}/
    assert_select "#last-release", { text: /#{Regexp.escape(active.slug)}/, count: 0 }
  end

  test "deployments wraps Current and Last release modules in a responsive side-by-side grid" do
    Release.delete_all
    shipped = Release.open!(branch: "release/grid-shipped")
    shipped.ship!
    active = Release.open!(branch: "release/grid-active")
    @new_task.update!(stage: "reviewed")
    active.add(@new_task)

    get deployments_path
    assert_response :success

    # A 2×2 card grid once the viewport has enough room: Next Release + Last
    # Release on top, Heartbeats + DevOps below.
    assert_select "[data-test='release-dashboard-grid'].grid.grid-cols-1.xl\\:grid-cols-2" do
      assert_select "#current-release", count: 1
      assert_select "#last-release", count: 1
      assert_select "[data-test='heartbeats-card']", count: 1
      assert_select "#release-duration-card", count: 1
    end
    assert_select "#current-release.h-full"
    assert_select "#last-release.h-full"
    assert_select "[data-test='heartbeats-card'].h-full"
    assert_select "#release-duration-card.h-full"
    # Next Release no longer spans two rows — every card is a single 2×2 cell.
    assert_select "#current-release.lg\\:row-span-2", count: 0
  end

  test "deployments empty-state Current still nests inside the responsive grid beside Last" do
    Release.delete_all
    shipped = Release.open!(branch: "release/grid-empty")
    shipped.ship!

    get deployments_path
    assert_response :success

    # Short empty-state Current + tall Last both live in the grid container.
    assert_select "div.grid.grid-cols-1.xl\\:grid-cols-2" do
      assert_select "#current-release", text: /none active/
      assert_select "#last-release", count: 1
    end
  end

  test "tasks board shows only the Build-lane columns and no release module" do
    Release.open!(branch: "release/build-only") # a release exists, but /tasks must not show it
    get tasks_path

    assert_response :success
    assert_select "h2", "Tasks"
    # Feature-agent lane; submitted is the seam. Neither of the two terminal-ish
    # side columns is a lane: blocked tasks ride Building, and archived tasks are
    # off the board entirely (reachable at ?stage=archived).
    assert_select "#dropzone-designed"
    assert_select "#dropzone-building"
    assert_select "#dropzone-submitted"
    assert_select "#dropzone-archived", count: 0
    assert_select "#dropzone-blocked", count: 0
    # DevOps-only columns absent
    assert_select "#dropzone-reviewed", count: 0
    assert_select "#dropzone-assembled", count: 0
    assert_select "#dropzone-shipped", count: 0
    # the current-release module lives on /deployments, not here
    assert_select "#current-release", count: 0
    assert_not_includes response.body, "Review submitted PRs"
    assert_not_includes response.body, "Run Deployment"
  end

  test "[component] deployments board shows pipeline swim lanes without kickoff copy chips" do
    get deployments_path

    assert_response :success
    assert_select "h2", "Deployments"
    # Upstream build lanes now lead the board (drag-and-drop; expanded later)…
    assert_select "#dropzone-designed"
    assert_select "#dropzone-building"
    # …then the Deploy workflow; submitted is the seam (shared with the feature-agent lane)
    assert_select "#dropzone-submitted"
    assert_select "#dropzone-reviewed"
    assert_select "#dropzone-assembled"
    assert_select "#dropzone-shipped"
    # the side / terminal states stay off the board
    assert_select "#dropzone-blocked", count: 0
    assert_select "#dropzone-archived", count: 0
    # Copy-paste kickoff commands stay off the /deployments column headers.
    assert_not_includes response.body, "Review submitted PRs"
    assert_not_includes response.body, "Prepare release"
    assert_not_includes response.body, "Run Deployment"
    assert_not_includes response.body, "Archive completed tasks"
  end

  # --- board scope: live work only ------------------------------------------
  #
  # The boards used to load EVERY task — 1,212 of them in production, plus 14,170
  # TaskEvents — to draw 57 cards. These pin the scope that fixed it, on the two
  # things a future refactor could quietly undo: that archived rows never come
  # back by default, and that ?stage= still reaches them.

  test "[integration] boards do not load archived tasks by default" do
    archived = Task.create!(title: "archived stays off board", stage: "archived")

    [tasks_path, deployments_path].each do |path|
      get path
      assert_response :success
      # The slug, not just the card id: a task that was loaded but not drawn would
      # still leak into a data attribute or a count somewhere on the page.
      assert_not_includes response.body, archived.slug,
                          "#{path} carries an archived task it should never have loaded"
    end
  end

  test "[integration] stage filter is the opt-in that still reaches the archive" do
    archived = Task.create!(title: "archived reachable by filter", stage: "archived")

    get tasks_path(stage: "archived")

    assert_response :success
    assert_select "#card-#{archived.slug}"
    # A filtered board is a SINGLE column of that stage. Loading the rows is only
    # half the contract — before this, ?stage=archived fetched them and then drew a
    # board with no column able to hold one.
    assert_select "#dropzone-archived"
    assert_select "#dropzone-designed", count: 0
  end

  test "[integration] the older link on a capped column lands on that stage uncapped" do
    limit = Task::BOARD_SHIPPED_LIMIT
    shipped = (limit + 3).times.map { |i| Task.create!(title: "older link shipped #{i}", stage: "shipped") }

    get deployments_path
    assert_response :success
    older = css_select("a[data-test='stage-older-link']").first
    assert older, "a capped column must offer a way to the rest"

    get older["href"]

    assert_response :success
    # Every shipped task, including the one the cap dropped off the board.
    shipped.each { |task| assert_select "#card-#{task.slug}" }
    assert_select "a[data-test='stage-older-link']", count: 0
  end

  test "[integration] shipped column is capped and counts what exists" do
    limit = Task::BOARD_SHIPPED_LIMIT
    shipped = (limit + 3).times.map { |i| Task.create!(title: "board cap shipped #{i}", stage: "shipped") }
    total = Task.where(stage: "shipped").count

    get deployments_path

    assert_response :success
    assert_select "#dropzone-shipped [data-stage='shipped']", count: limit,
                  message: "the shipped column must draw at most BOARD_SHIPPED_LIMIT cards"
    # The badge reports the TRUE total, not the drawn slice — a capped column that
    # under-counted would be a quieter lie than the slow page the cap replaced.
    assert_select "[data-stage-count='shipped']", text: /#{total}/
    assert_select "a[data-test='stage-older-link']", text: /#{total - limit} older/
    # …and the newest survive the cap, not an arbitrary slice.
    assert_select "#dropzone-shipped #card-#{shipped.last.slug}"
    assert_select "#dropzone-shipped #card-#{shipped.first.slug}", count: 0
  end

  test "[component] neither board renders an Archived toggle" do
    [tasks_path, deployments_path].each do |path|
      get path
      assert_response :success
      assert_select "[data-test='board-header-actions'] button", text: "Archived", count: 0
      assert_not_includes response.body, "showArchived",
                          "#{path} still carries the archived-toggle Alpine state"
    end
  end

  test "blocked tasks ride the Building column (red hue) on both boards" do
    blocked = Task.create!(title: "blocked rides building", stage: "building")
    blocked.block!(by: "avi", kind: "rework")
    [tasks_path, deployments_path].each do |path|
      get path
      assert_response :success
      assert_select "#dropzone-building #card-#{blocked.slug}[class*=bg-red]", true,
                    "blocked card should ride the Building column with a red hue on #{path}"
    end
  end

  test "[component] task cards carry unresolved feedback as the red tone + blocker-summary bar, independent of latest note" do
    task = Task.create!(title: "unresolved feedback card", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "Needs rework before merge.")
    Activity.create!(task_slug: task.slug, activity_type: "handoff", description: "Latest handoff context.")

    get tasks_path

    assert_response :success
    # The generic UNRESOLVED QA label was dropped; the red block card-tone carries the
    # open feedback and the blocker's own summary rides a red bar linking to the detail.
    # The activity box still shows the latest note beneath it.
    assert_select "#card-#{task.slug}[class*=bg-red-50]"
    assert_select "#card-#{task.slug} [data-test='unresolved-feedback']", count: 0
    assert_select "#card-#{task.slug} a[data-test='blocker-summary'][href='#{task_path(task.slug)}']",
                  text: "Needs rework before merge."
    assert_select "#card-#{task.slug} [data-test='activity-box']", text: /Handoff/
  end

  test "[integration] show renders the blocker summary as the headline and details in an expand" do
    task = Task.create!(title: "split blocker task", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                     description: "The stage transition bypasses the server guard; re-gate it before resubmit.",
                     metadata: { "summary" => "Stage move skips server guard" })

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='task-unresolved-feedback-summary']", text: "Stage move skips server guard"
    assert_select "[data-test='task-unresolved-feedback-details']" do
      assert_select "summary", text: "Details"
      assert_select "p", text: /re-gate it before resubmit/
    end
  end

  test "[integration] show derives a headline for a legacy blocker with no summary" do
    task = Task.create!(title: "legacy blocker task", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                     description: "The stage transition bypasses the server guard entirely and must be re-gated.")

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='task-unresolved-feedback-summary']",
                  text: "The stage transition bypasses the server…"
    # The full details still render below the derived headline.
    assert_select "[data-test='task-unresolved-feedback-details'] p", text: /must be re-gated/
  end

  test "[integration] show skips the details expand when a short blocker equals its summary" do
    task = Task.create!(title: "short blocker task", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "Rebase before QA.")

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='task-unresolved-feedback-summary']", text: "Rebase before QA."
    assert_select "[data-test='task-unresolved-feedback-details']", count: 0
  end

  test "[component] the REVIEW STARTED card flag is dropped; the task page still carries it" do
    task = Task.create!(title: "review started guard", stage: "submitted")
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
    )

    get tasks_path

    assert_response :success
    # Dropped from the card — the deploy-board crew avatar carries live review now
    # (see board_card_stage_avatars_test); the detail page keeps the explicit label.
    assert_select "#card-#{task.slug} [data-test='review-in-progress']", count: 0

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='task-review-in-progress']", text: "REVIEW STARTED"
    assert_includes response.body, "Open follow-up work before adding changes to this branch."
  end

  # === local_review: the WAITING APPROVAL CTA ===
  #
  # It used to mint the magic link HERE and redirect to this app's /l/<token>.
  # From the production board that could only ever land the operator signed into
  # PRODUCTION at the local page's path — a magic link signs you into the app
  # that minted it. The board now HANDS OFF to the local server's own dev-only
  # mint endpoint (studio-engine >= 0.19), which is the only server that can
  # create a session on that stack.

  test "[integration] local_review hands off to the local server's mint endpoint and mints nothing here" do
    log_in_as(@admin)
    task = Task.create!(
      title: "local review mint task",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3009/demo?x=1" } }
    )

    assert_no_difference -> { Studio::Link.count } do
      get local_review_task_path(task.slug)
    end

    target = URI.parse(@response.redirect_url)
    assert_equal "localhost", target.host
    assert_equal 3009, target.port, "the reviewer must land on the DEMO's stack, not the board's host"
    assert_equal "/_studio/local_review", target.path

    query = Rack::Utils.parse_query(target.query)
    assert_equal "/demo?x=1", query["return_to"], "and lands them on the page under review"
  end

  # The CTA is ONE CLICK from a cold browser. It used to sit behind
  # require_authentication, so a logged-out click 302'd to /login — and
  # require_authentication keeps no return_to, so the click was thrown away
  # entirely. Caught on the operator's real click in the production log.
  test "[integration] a LOGGED-OUT click reaches the local mint instead of the login page" do
    task = Task.create!(
      title: "local review logged out task",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3009/admin/style" } }
    )

    get local_review_task_path(task.slug)

    target = URI.parse(@response.redirect_url)
    assert_equal "localhost", target.host, "a logged-out click must not be sent to /login"
    assert_equal 3009, target.port
    assert_equal "/_studio/local_review", target.path
    assert_equal "/admin/style", Rack::Utils.parse_query(target.query)["return_to"]
  end

  # No signed-in user means no email to send — and this URL is public, so an
  # address in it would be published. Asserted as a property (nothing that looks
  # like an address), not as "the email key is missing", so renaming the
  # parameter cannot quietly restore the leak.
  test "[integration] the public redirect carries no email address" do
    task = Task.create!(
      title: "local review no email task",
      stage: "building",
      metadata: { "devops" => { "local_url" => "http://localhost:3009/admin/style" } }
    )

    [nil, @admin].each do |viewer|
      viewer ? log_in_as(viewer) : reset!

      get local_review_task_path(task.slug)

      refute_includes @response.redirect_url.to_s, "@",
        "the operator's address must never ride a public redirect, signed in or not"
      assert_equal ["return_to"], Rack::Utils.parse_query(URI.parse(@response.redirect_url).query).keys
    end
  end

  # A non-admin used to be bounced to root here. That gate is gone ON PURPOSE:
  # the destination is always loopback, so the only server a stranger's click can
  # reach is their OWN machine, and the board hands out nothing.
  test "[integration] a non-admin gets the same handoff, not a bounce to root" do
    log_in_as(@viewer)
    task = Task.create!(
      title: "local review non admin task",
      stage: "building",
      metadata: { "devops" => { "local_url" => "http://localhost:3009/demo" } }
    )

    get local_review_task_path(task.slug)

    assert_equal "/_studio/local_review", URI.parse(@response.redirect_url).path
  end

  test "[integration] local_review with no local_url bounces to the task" do
    log_in_as(@admin)
    task = Task.create!(title: "local review no url task", stage: "building")

    get local_review_task_path(task.slug)

    assert_redirected_to task_path(task.slug)
  end

  test "[integration] local_review refuses to send a visitor off-box" do
    # With the CTA public and unauthenticated, loopback is the ONLY thing
    # standing between a hostile local_url and a stranger's browser — so a
    # local_url that is not loopback (a QA host, a typo, a hostile value) must
    # bounce to the task page, never off this machine. Asserted logged OUT,
    # because that is now the weakest caller.
    [
      "https://qa.mcritchie.studio/admin/style",
      "http://evil.com/pwn",
      "http://localhost.evil.com/pwn",
      "//evil.com/pwn"
    ].each do |hostile|
      task = Task.create!(title: "hostile url #{SecureRandom.hex(2)}", stage: "building",
                          metadata: { "devops" => { "local_url" => hostile } })

      get local_review_task_path(task.slug)

      assert_redirected_to task_path(task.slug)
      refute_includes @response.redirect_url.to_s, "evil.com",
                      "a non-loopback local_url must never become the redirect target"
    end
  end

  test "[component] reactivated building tasks render above blocked cards" do
    blocked = Task.create!(title: "stale blocked sort task", stage: "building")
    blocked.block!(by: "avi", kind: "rework")
    # A freshly claimed building task ranks above an older blocked one (position DESC).
    reactivated = Task.create!(title: "reactivated sort task now", stage: "building")

    get tasks_path
    assert_response :success

    building_html = css_select("#dropzone-building").first.to_html
    reactivated_index = building_html.index("card-#{reactivated.slug}")
    blocked_index = building_html.index("card-#{blocked.slug}")

    assert reactivated_index, "reactivated card should render in Building"
    assert blocked_index, "blocked card should render in Building"
    assert_operator reactivated_index, :<, blocked_index
  end

  test "[integration] JSON move into building renders the reactivated task first" do
    log_in_as(@admin)
    blocked = Task.create!(title: "stale blocked api task", stage: "building")
    blocked.block!(by: "avi", kind: "rework")
    reactivated = Task.create!(title: "reactivated api task now", stage: "submitted")

    # A JSON stage move into building re-ranks the card to the top of the column.
    patch task_path(reactivated.slug, format: :json),
          params: { task: { stage: "building" } }, as: :json
    assert_response :success

    get tasks_path
    assert_response :success

    building_html = css_select("#dropzone-building").first.to_html
    reactivated_index = building_html.index("card-#{reactivated.slug}")
    blocked_index = building_html.index("card-#{blocked.slug}")

    assert reactivated_index, "reactivated card should render in Building"
    assert blocked_index, "blocked card should render in Building"
    assert_operator reactivated_index, :<, blocked_index
  end

  test "stages page renders both workflow lanes and the stage guide" do
    get stages_path

    assert_response :success
    assert_select "h2", "Stages"
    assert_select "h3", text: /Workflow 1 . Build/
    assert_select "h3", text: /Workflow 2 . Deploy/
    # a stage from each lane, and the responsible/next scaffolding
    assert_includes response.body, "Designed"
    assert_includes response.body, "Assembled"
    assert_includes response.body, "Responsible"
    assert_includes response.body, "Run Deployment" # DevOps kickoff chip on the assembled card
    # The stage guide points operators at the rendered SOP infographic.
    assert_select "a[href=?]", sop_path, { minimum: 1 }, "stages should link to the SOP infographic"
  end

  test "stages page outlines tests-run and gate for the Deploy lane" do
    get stages_path
    assert_response :success

    # Deploy steps now spell out their tests-run + gate (devops-cycle-design §1.2)
    assert_includes response.body, "Tests run"
    assert_includes response.body, "Gate"
    assert_includes response.body, "Carl per PR"              # review is Carl-owned, not Avi-supervised
    assert_includes response.body, "FROZEN ship SHA"          # Steffon's ship-time suite
    assert_includes response.body, "qa-release"               # Avi's QA release lane
    assert_includes response.body, "full-cycle"               # the Alex full-cycle ship launcher
  end

  test "deployments and stages are public (no login required)" do
    get deployments_path
    assert_response :success
    get stages_path
    assert_response :success
  end

  test "[component] sop renders the four accountability swimlanes" do
    get sop_path

    assert_response :success
    assert_select "h2", "DevOps SOP"
    # One lane per accountable owner (the four lanes from the vocabulary YAML).
    [ "Builder", "Primary Reviewer", "Steffon", "Avi" ].each do |owner|
      assert_includes response.body, owner, "expected the #{owner} lane"
    end
    # A representative step label + the single-source owner definition render.
    assert_includes response.body, "Building"
    assert_includes response.body, "Owner = the agent accountable for the whole lane"
    # Each step has a node tile + an expand-on-click detail (Owner / Expectation / Gate).
    assert_select "[data-sop-node]"
    assert_select "dt", text: "Expectation"
    assert_select "dt", text: "Gate"
    assert_includes response.body, "Build to the accepted criteria" # an expand detail body
  end

  test "[component] sop is public (no login required)" do
    get sop_path
    assert_response :success
  end

  test "[component] sop shows no ⚠ divergence markers — the model is fully implemented" do
    get sop_path

    assert_response :success
    # Both prior divergences are reconciled: Assemble's Main Branch (merge-forward guard)
    # and Review's Release Branch (Steffon's qa-release sweep owns the merge), so the
    # SOP infographic carries no ⚠ marker.
    markers = css_select("[data-sop-diverges]")
    assert_equal 0, markers.size,
      "no SOP step should diverge from the implemented model (Steffon now owns the merge sweep)"
  end

  test "each board page cross-links to the other boards" do
    # The active board hides its own (redundant) toggle button, so a page links
    # to the OTHER board(s); Stages stays reachable from top-links or the
    # /deployments older-links menu.
    { tasks_path => "tasks", deployments_path => "deployments", stages_path => "stages" }.each do |page, current|
      get page
      assert_response :success
      if current == "deployments"
        assert_select %([data-test="deployment-link-menu"] a[href="#{stages_path}"]), { minimum: 1 }, "#{page} missing Stages menu link"
      else
        assert_select %(nav a[href="#{stages_path}"]), { minimum: 1 }, "#{page} missing Stages nav link"
      end
      assert_select %(nav a[href="#{tasks_path}"]), { minimum: 1 }, "#{page} missing Tasks nav link" unless current == "tasks"
      assert_select %(nav a[href="#{deployments_path}"]), { minimum: 1 }, "#{page} missing Deployments nav link" unless current == "deployments"
    end
  end

  test "board pages link back to the dashboard for admins" do
    log_in_as(@admin)
    [tasks_path, deployments_path, stages_path].each do |page|
      get page
      assert_select %(a[href="#{admin_dashboard_path}"]), { minimum: 1 }, "#{page} missing Dashboard link for admin"
    end
  end

  test "dashboard link is hidden from non-admins" do
    get tasks_path
    assert_select %(a[href="#{admin_dashboard_path}"]), count: 0
  end

  test "board pages omit removed DevOps Cycle link for admins" do
    log_in_as(@admin)

    [tasks_path, deployments_path, stages_path].each do |page|
      get page
      assert_response :success
      assert_select "a", text: "DevOps Cycle", count: 0
      assert_select "a", text: "Full SOP ↗", count: 0
    end
  end

  test "index renders latest task feedback on cards" do
    Activity.create!(
      task_slug: @new_task.slug,
      activity_type: "comment",
      description: "Older note."
    )
    Activity.create!(
      task_slug: @new_task.slug,
      activity_type: "qa_feedback",
      description: "Latest QA note should appear on the board."
    )

    get tasks_path

    assert_response :success
    assert_includes response.body, "Latest QA note should appear on the board."
    assert_includes response.body, "2 notes"
  end

  test "the resume control lives on the task read view, not the board cards" do
    @in_progress_task.update!(metadata: { "devops" => {
      "kind" => "feature",
      "session_id" => "2aa216f6-7565-4bf4-bd01-70793c8ba617",
      "session_provider" => "claude"
    } })

    # the board card no longer carries the resume command (decluttered)
    get tasks_path
    assert_response :success
    assert_select "#card-#{@in_progress_task.slug}" # the card still renders
    assert_not_includes response.body, "claude --resume"

    # …it renders on the task read view instead — truncated display + full clipboard copy
    get task_path(@in_progress_task.slug)
    assert_response :success
    assert_select "code", text: /claude --resume …a617/
    assert_includes response.body, "claude --resume 2aa216f6-7565-4bf4-bd01-70793c8ba617"
  end

  test "board card without a session renders no last-4 and no resume control" do
    @in_progress_task.update!(metadata: { "devops" => { "kind" => "feature" } })

    get tasks_path
    assert_response :success

    card = "#card-#{@in_progress_task.slug}"
    assert_select card # the card still renders
    assert_select "#{card} *", { text: /resume/, count: 0 }
    assert_not_includes response.body, "Copy resume command"
  end

  test "show renders task detail" do
    get task_path(@new_task.slug)
    assert_response :success
  end

  test "[component] show renders review followup guard during active review" do
    log_in_as(@admin)
    Agent.create!(name: "Guard Carl", slug: "guard-carl")
    Agent.create!(name: "Guard Shannon", slug: "guard-shannon")
    task = Task.create!(
      title: "review guard source task",
      stage: "submitted",
      metadata: {
        "devops" => {
          "kind" => "feature",
          "shape" => "ui-only",
          "repositories" => ["mcritchie-studio"],
          "risk_tags" => ["review-workflow"],
          "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999"
        }
      }
    )
    task.record_intent_event(
      to_stage: "reviewed",
      reviewers: [
        { "slug" => "guard-carl", "weight" => "primary" },
        { "slug" => "guard-shannon", "weight" => "light" }
      ]
    )

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='review-followup-guard']"
    assert_select "[data-test='review-followup-guard']", text: /Do not interrupt/
    assert_select "[data-test='review-followup-reviewer'][data-role='primary']", text: /Guard Carl/
    assert_select "a[href=?]", "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999", text: /View PR/
    assert_select "a[data-test='review-followup-create-link'][href=?]", new_task_path(followup_from: task.slug)
  end

  test "[component] show omits review followup guard after review lands" do
    log_in_as(@admin)
    task = Task.create!(title: "review guard landed task", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed",
                             reviewers: [{ "slug" => "carl", "weight" => "primary" }])
    task.review!

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='review-followup-guard']", count: 0
  end

  test "task show 'All Tasks' back-link points to /deployments" do
    get task_path(@new_task.slug)
    assert_response :success
    assert_select "a[href=?]", deployments_path, text: /All Tasks/
  end

  test "new task 'All Tasks' back-link points to /deployments" do
    log_in_as(@admin)
    get new_task_path
    assert_response :success
    assert_select "a[href=?]", deployments_path, text: /All Tasks/
  end

  test "[component] new followup task form preserves source context" do
    log_in_as(@admin)
    source = Task.create!(
      title: "source review guard",
      stage: "submitted",
      priority: 1,
      metadata: {
        "devops" => {
          "kind" => "feature",
          "shape" => "ui-only",
          "repositories" => ["mcritchie-studio", "turf-monster"],
          "risk_tags" => ["review-workflow"],
          "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/998"
        }
      }
    )

    get new_task_path(followup_from: source.slug)

    assert_response :success
    assert_select "input[name='task[title]'][value='Followup Review Changes']"
    assert_select "textarea[name='task[description]']", text: /Follow-up to source review guard/
    assert_select "textarea[name='task[description]']", text: /instead of pushing to the branch under review/
    assert_select "textarea[name='task[description]']", text: /pull\/998/
    assert_select "select[name='task[devops][shape]'] option[selected][value='ui-only']", "ui-only"
    assert_select "input[name='task[devops][repositories]'][value='mcritchie-studio, turf-monster']"
    assert_select "input[name='task[devops][risk_tags]'][value='review-workflow, review-followup']"
    assert_select "textarea[name='task[devops][acceptance]']", text: /Original review continues without interruption/
  end

  test "[integration] create preserves followup task shape from form params" do
    log_in_as(@admin)

    assert_difference "Task.count", 1 do
      post tasks_path, params: {
        task: {
          title: "Followup Shape Guard",
          description: "Follow-up to source review guard.",
          priority: "1",
          devops: {
            kind: "feature",
            shape: "ui-only",
            repositories: "mcritchie-studio",
            risk_tags: "review-workflow, review-followup",
            acceptance: "Followup captures post review changes safely\nOriginal review continues without interruption",
            test_plan: "Run focused checks for followup scope"
          }
        }
      }
    end

    task = Task.order(:created_at).last
    assert_redirected_to task_path(task.slug)
    assert_equal "ui-only", task.devops_shape
    assert_equal "feature", task.devops_kind
    assert_equal ["mcritchie-studio"], task.devops_repositories
    assert_equal ["review-workflow", "review-followup"], task.devops_risk_tags
  end

  # === devops.pr_urls through the WEB path ===
  #
  # `pr_urls` is a repo-keyed hash of arbitrary keys, and strong params treats a
  # bare `:pr_urls` in the permit list as a SCALAR — it hands back `{}` and the
  # write reaches nothing. `{ pr_urls: {} }` is what permits the open-ended hash.
  # Before it was permitted at all, the key was stripped BEFORE
  # Task.normalize_devops_map ran, so this action answered 200 for a hand-posted
  # write that landed nowhere, and for a nonsense url that was never validated.

  test "[integration] a web devops edit stores the per-repo pr_urls map" do
    log_in_as(@admin)
    turf = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

    patch task_path(@new_task.slug, format: :json),
          params: { task: { devops: { kind: "bug", pr_urls: { "turf-monster" => turf } } } }

    assert_response :success
    assert_equal({ "turf-monster" => turf }, @new_task.reload.devops["pr_urls"])
  end

  test "[integration] a web devops edit 422s on a pr_urls url that names no repo" do
    log_in_as(@admin)

    patch task_path(@new_task.slug, format: :json),
          params: { task: { devops: { kind: "bug", pr_urls: { "turf-monster" => "lol" } } } }

    assert_response :unprocessable_entity
    assert_match(/names no repo/, JSON.parse(response.body)["error"])
    assert_nil @new_task.reload.devops["pr_urls"]
  end

  test "[integration] a web devops edit 422s on a pr_urls url filed under the wrong repo" do
    log_in_as(@admin)
    turf = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

    patch task_path(@new_task.slug, format: :json),
          params: { task: { devops: { kind: "bug", pr_urls: { "mcritchie-studio" => turf } } } }

    assert_response :unprocessable_entity
    assert_match(/wrong repo/, JSON.parse(response.body)["error"])
  end

  # === A board UI edit is a PARTIAL devops write ===
  #
  # The edit form renders a field for some devops keys and not others. That post
  # used to be written over metadata.devops WHOLESALE, so every key the form
  # omits — agent_context (often the only record of WHY a task exists), built_by,
  # gem_bump, pr_urls, the mascot/session keys — was deleted by anyone editing an
  # acceptance bullet in a browser. Silently, with a 200.
  #
  # Both tests below read the field set OFF THE RENDERED FORM rather than from a
  # hand-written param list, and assert over Task::DEVOPS_KEYS rather than over
  # today's spellings. That is deliberate: a test that added `pr_urls` to an
  # expectation would pass while the next new key was still wiped.

  # The devops field names the real edit form posts.
  def rendered_devops_field_names(task)
    get edit_task_path(task.slug)
    assert_response :success
    css_select("input[name], select[name], textarea[name]")
      .filter_map { |node| node["name"][/\Atask\[devops\]\[([^\]]+)\]\z/, 1] }
      .uniq
  end

  test "[component] the task edit form's devops fields are a storable subset of the model's keys" do
    log_in_as(@admin)

    names = rendered_devops_field_names(@new_task)

    assert_includes names, "kind", "guard: the form really does render devops fields"
    assert_empty names - Task::DEVOPS_KEYS,
                 "the form renders a devops field normalize_devops_metadata does not store — that write reaches nothing"
    assert_not_empty Task::DEVOPS_KEYS - names,
                     "the form now covers every devops key, so the merge in " \
                     "TasksController#merged_metadata_with_devops no longer has anything to protect — " \
                     "read it before deleting anything"
  end

  test "[integration] a board UI edit leaves the devops keys its form omits intact" do
    log_in_as(@admin)
    @new_task.update!(metadata: { "devops" => devops_key_spread, "unrelated" => "kept" })
    # Baseline = what the MODEL actually kept, not what the spread offered. A
    # `designed` task legitimately carries no ClaimLease::CLAIM_KEYS (they live
    # only on `building`), and asserting over the spread would fail on that
    # invariant rather than on the behavior under test.
    stored = @new_task.reload.devops
    posted = rendered_devops_field_names(@new_task)
    unposted = (Task::DEVOPS_KEYS & stored.keys) - posted

    # Vacuity guards. The generic loop below is only meaningful if there really
    # are stored keys the form never posts — and these four are the ones measured
    # lost on the live board, so a fixture that stopped carrying them would make
    # this test pass while saying nothing.
    assert_not_empty unposted, "guard: the form must omit stored devops keys for this test to mean anything"
    assert_empty %w[agent_context built_by gem_bump pr_urls] - unposted,
                 "guard: the keys measured lost on the board must be in the covered set"
    # The most destructive post a browser can make: every field the form offers,
    # submitted empty. Anything that survives, survives because it was never
    # posted — not because the value happened to be resent.
    patch task_path(@new_task.slug), params: { task: { devops: posted.index_with("") } }
    assert_redirected_to task_path(@new_task.slug)

    devops = @new_task.reload.devops
    unposted.each do |key|
      assert_equal stored[key], devops[key],
                   "devops.#{key} was destroyed by a board edit that renders no field for it"
    end
    posted.each do |key|
      assert_not devops.key?(key), "devops.#{key} was posted blank, so the edit must clear it"
    end
    assert_equal "kept", @new_task.metadata["unrelated"], "the edit must not touch the rest of metadata"
  end

  # === Per-stage deploy-crew avatars (task-ui-stage-agents) ===

  # Seed the four Deploy-half souls + a shipped task with explicit TaskEvents so
  # the avatars (reviewers + Steffon + Avi) and durations are deterministic.
  def seed_deploy_crew_task(steffon_avatar: nil)
    Agent.create!(name: "Shannon", slug: "shannon")
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Steffon", slug: "steffon", avatar: steffon_avatar)
    Agent.create!(name: "Avi", slug: "avi")

    task = Task.create!(title: "Deploy crew render task", stage: "shipped")
    task.task_events.delete_all
    # Reviewers ride the →reviewed EVENT's metadata (the canonical write target,
    # per Task#stage_event_metadata) — NOT Task.metadata. The avatars read the
    # event, so the harness must seed the pair there.
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 7200, # 2h review
                      metadata: { "reviewers" => [
                        { "slug" => "shannon", "weight" => "primary" },
                        { "slug" => "carl", "weight" => "light" }
                      ] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon") # 30m
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi") # 10m
    task
  end

  test "deployments board card shows the deploy crew under the slug with compact durations" do
    task = seed_deploy_crew_task(steffon_avatar: "https://example.com/steffon.png")

    get deployments_path
    assert_response :success

    card = "#card-#{task.slug}"
    assert_select "#{card} [data-test='stage-agent-avatars']"
    # Steffon's image avatar renders (the others fall back to initials)
    assert_select "#{card} img[src='https://example.com/steffon.png']"
    # The crew rides UNDER the slug as the lane grid — review / assembled / shipped each
    # carry their OWN compact corner pill (assembled + shipped are not collapsed). This
    # seed has no build-lane events, so three pills land on the real crew-duration
    # markers: 7200s → 2h (longer review), 1800s → 30m (assembled), 600s → 10m (shipped).
    pills = "#{card} [data-test='crew-duration']"
    assert_select pills, count: 3
    assert_select pills, text: /2h/  # review compartment (max of the two reviewers)
    assert_select pills, text: /30m/ # assembled compartment (Steffon) — its own pill
    assert_select pills, text: /10m/ # shipped compartment (Avi) — its own pill
  end

  test "task show renders the consolidated stage timeline with crew, names, weights and durations" do
    task = seed_deploy_crew_task

    get task_path(task.slug)
    assert_response :success

    # The detailed "Stage crew" panel + the separate "Stage Timeline" are now ONE
    # consolidated timeline — every block carries the crew that handled its stage.
    assert_select "[data-test='stage-timeline']"
    assert_select "[data-test='stage-timeline'] p.label-upper", text: /Stage Timeline/
    assert_select "[data-test='timeline-block']", minimum: 3 # reviewed · assembled · shipped
    timeline = css_select("[data-test='stage-timeline']").to_s
    # every soul is named on its block
    %w[Shannon Carl Steffon Avi].each { |name| assert_includes timeline, name }
    # primary/light review weights surface
    assert_includes timeline, "primary"
    assert_includes timeline, "light"
    # full humanized duration (7200s → about 2 hours) in the card's Duration metric
    assert_includes timeline, "about 2 hours"
  end

  test "[component] task show's live assembled card reads Assembled -> Shipped (Avi), not a no-op" do
    Agent.create!(name: "Shannon", slug: "shannon")
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Steffon", slug: "steffon")
    Agent.create!(name: "Avi", slug: "avi")

    task = Task.create!(title: "Live QA timeline task", stage: "assembled")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 2.hours.ago, seconds_in_from: 600,
                      metadata: { "reviewers" => [
                        { "slug" => "shannon", "weight" => "primary" },
                        { "slug" => "carl", "weight" => "light" }
                      ] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 1.hour.ago, seconds_in_from: 1800, actor: "avi")
    # The standard QA window: Avi's QA intent rides toward `shipped` (qa-marked),
    # re-homed to the assembled LANE on the board. The /tasks/:id timeline must frame
    # it as the real transition — Assembled → Shipped, owned by Steffon — never the old
    # nonsensical "Assembled → Assembled" no-op.
    task.record_intent_event(to_stage: "shipped", actor: "avi", qa: true)

    get task_path(task.slug)
    assert_response :success

    inprogress = "[data-test='timeline-block'][data-in-progress='true']"
    assert_select "#{inprogress}[data-stage='shipped']", count: 1, # badge target = shipped, not assembled
                  message: "the live assembled card targets the shipped stage"
    assert_select "#{inprogress}[data-stage='assembled']", count: 0,
                  message: "no Assembled → Assembled no-op block"
    assert_includes css_select(inprogress).to_s, "Steffon", "the live ship card is owned by Steffon"

    # While the stage is still in progress, the transition row shows ONLY the
    # current stage in its ACTIVE (gerund) form — "Assembling", not "Assembled" —
    # with no arrow and no next-step (Shipped) badge. Those appear once the
    # transition lands (the li still TARGETS shipped via data-stage).
    live_row = css_select("#{inprogress} [data-test='timeline-transition']").to_s
    assert_includes live_row, "Assembling", "in-progress card shows the active stage verb"
    assert_not_includes live_row, "Shipped", "in-progress card hides the next-step badge + arrow"
  end

  test "[component] timeline centers the transition badges and stacks crew avatar-over-name" do
    task = seed_deploy_crew_task

    get task_path(task.slug)
    assert_response :success

    # Change 1: the from → to stage badges are center-justified.
    assert_select "[data-test='timeline-transition'].justify-center", minimum: 1
    # Change 2: each crew member is an avatar-OVER-name centered column.
    assert_select "[data-test='timeline-crew-member'].flex-col.items-center", minimum: 1
    # Change 3: the senior review pair renders as TWO side-by-side columns in one row.
    pair = css_select("[data-test='timeline-block'][data-stage='reviewed'] [data-test='timeline-crew-member']")
    assert_equal 2, pair.size, "the review pair shows two avatar-over-name columns side by side"
    # Change 3b: a TWO-agent crew splits into equal 50% columns (grid-cols-2), each
    # agent centered in its own half; a single-agent stage stays one centered column.
    assert_select "[data-test='timeline-block'][data-stage='reviewed'] [data-test='timeline-crew'].grid.grid-cols-2", 1
    assert_select "[data-test='timeline-block'][data-stage='assembled'] [data-test='timeline-crew'].grid-cols-2", 0
    assert_select "[data-test='timeline-block'][data-stage='assembled'] [data-test='timeline-crew'].justify-center", 1
  end

  test "task show backfills Steffon/Avi by role on a conductor-driven old-flow task" do
    # A shipped task whose Deploy moves were conductor-driven (blank actor) and that
    # predates the two-senior model (no reviewers metadata): the consolidated timeline
    # still attributes assembled→Steffon and shipped→Avi BY ROLE, so the Deploy crew
    # never goes blank (the Steffon/Avi fix). The review block simply shows no pair.
    Agent.create!(name: "Steffon", slug: "steffon")
    Agent.create!(name: "Avi", slug: "avi")
    task = Task.create!(title: "Old flow conductor task", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 2.hours.ago, seconds_in_from: 600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 1.hour.ago, seconds_in_from: 600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 30.minutes.ago, seconds_in_from: 600)

    get task_path(task.slug)
    assert_response :success
    timeline = css_select("[data-test='stage-timeline']").to_s
    assert_includes timeline, "Steffon", "assembled backfills to its role owner"
    assert_includes timeline, "Avi", "shipped backfills to its role owner"
  end

  test "build-lane board cards render no deploy-crew avatars" do
    get tasks_path
    assert_response :success
    assert_select "#card-#{@in_progress_task.slug} [data-test='stage-agent-avatars']", count: 0
  end

  test "a freshly-created designed task shows its mascot on the board card" do
    # Regression: a `designed` task has only a blank-actor genesis event, so the
    # crew helper is empty — but its mascot is the feature agent's face and must
    # show immediately (it used to appear only after the move to building).
    Pokemon.create!(dex: 51, name: "Dugtrio", slug: "dugtrio", generation: 1,
                    sprite_url: "https://example.test/dugtrio.png")
    task = Task.create!(title: "Fresh designed mascot task", stage: "designed",
                        metadata: { "devops" => { "mascot" => "dugtrio" } })
    assert_equal "dugtrio", task.reload.devops_field("mascot"), "guard: the mascot persisted"

    get tasks_path
    assert_response :success
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']", { count: 1 },
                  "a designed task must show its mascot the moment it's created"
    assert_includes css_select("#card-#{task.slug}").to_s, "https://example.test/dugtrio.png",
                    "the mascot's sprite renders on the card"
  end

  # === Kanban stage moves via JSON PATCH (the one path: board, bin/task, API) ===

  test "move task to any stage via PATCH JSON" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "shipped" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "shipped", @new_task.stage
    assert_not_nil @new_task.completed_at
  end

  test "move task backwards via PATCH JSON" do
    log_in_as(@admin)
    patch task_path(@done_task.slug, format: :json),
          params: { task: { stage: "designed" } }, as: :json
    assert_response :success
    @done_task.reload
    assert_equal "designed", @done_task.stage
  end

  test "move task to building sets started_at" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "building" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "building", @new_task.stage
    assert_not_nil @new_task.started_at
  end

  test "move task through the build workflow stages" do
    log_in_as(@admin)

    %w[building submitted reviewed].each do |stage|
      patch task_path(@new_task.slug, format: :json),
            params: { task: { stage: stage } }, as: :json
      assert_response :success
      assert_equal stage, @new_task.reload.stage
    end
    assert_not_nil @new_task.submitted_at
    assert_not_nil @new_task.reviewed_at
  end

  test "move task through the deploy workflow stages" do
    log_in_as(@admin)

    %w[reviewed assembled shipped].each do |stage|
      patch task_path(@new_task.slug, format: :json),
            params: { task: { stage: stage } }, as: :json
      assert_response :success
      assert_equal stage, @new_task.reload.stage
    end
    assert_not_nil @new_task.assembled_at
    assert_not_nil @new_task.completed_at
  end

  test "block action stamps the block columns and lands the task on building" do
    log_in_as(@admin)
    patch block_task_path(@in_progress_task.slug), params: { kind: "rework" }
    assert_redirected_to task_path(@in_progress_task.slug)
    @in_progress_task.reload
    assert_equal "building", @in_progress_task.stage, "a block is a building attribute, not a stage"
    assert @in_progress_task.blocked?
    assert_not_nil @in_progress_task.blocked_at
    assert_equal "building", @in_progress_task.blocked_from
    assert_equal "rework", @in_progress_task.block_kind
  end

  test "unblock action clears the block columns, staying on building" do
    log_in_as(@admin)
    @in_progress_task.block!(by: "avi", kind: "rework")
    assert @in_progress_task.blocked?

    patch unblock_task_path(@in_progress_task.slug)
    assert_redirected_to task_path(@in_progress_task.slug)
    @in_progress_task.reload
    assert_equal "building", @in_progress_task.stage
    assert_not @in_progress_task.blocked?
    assert_nil @in_progress_task.blocked_at
    assert_nil @in_progress_task.block_kind
  end

  test "move task to archived sets archived_at" do
    log_in_as(@admin)
    patch task_path(@done_task.slug, format: :json),
          params: { task: { stage: "archived" } }, as: :json
    assert_response :success
    @done_task.reload
    assert_equal "archived", @done_task.stage
    assert_not_nil @done_task.archived_at
  end

  # === Delete ===

  test "delete works via JSON" do
    log_in_as(@admin)
    assert_difference "Task.count", -1 do
      delete task_path(@new_task.slug, format: :json)
    end
    assert_response :no_content
  end

  # === Update fields via JSON ===

  test "update title via JSON returns JSON not redirect" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { title: "updated task title here" } }, as: :json
    assert_response :success
    @new_task.reload
    assert_equal "updated task title here", @new_task.title
  end

  test "create stores devops handoff metadata" do
    log_in_as(@admin)

    assert_difference "Task.count", 1 do
      post tasks_path, params: {
        task: {
          title: "Review Turf PR",
          devops: {
            kind: "feature",
            shape: "ui+db",
            worktree_slug: "contest-flow",
            repositories: "turf-monster, turf-vault",
            branch: "feat/contest-flow",
            pr_url: "https://github.com/McRitchie-Studio/turf-monster/pull/149",
            qa_url: "https://qa.turfmonster.media/contests",
            requires_release_conductor: "1",
            acceptance: "Contest creates on QA without errors\nEntry submits successfully on QA devnet",
            test_plan: "bin/rails test\nQA devnet mutating smoke",
            checks_run: "bin/rails test test/controllers/tasks_controller_test.rb"
          }
        }
      }
    end

    task = Task.order(:created_at).last
    assert_redirected_to task_path(task.slug)
    assert task.requires_release_conductor?
    assert_equal "ui+db", task.devops_shape
    assert_equal "contest-flow", task.devops_worktree_slug
    assert_equal ["turf-monster", "turf-vault"], task.devops_repositories
    assert_equal ["Contest creates on QA without errors", "Entry submits successfully on QA devnet"], task.devops_acceptance
    assert_equal ["bin/rails test test/controllers/tasks_controller_test.rb"], task.devops_checks_run
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
  end

  # === Release membership is the column, on the operator's surfaces too ===
  #
  # (release-slug-two-universes) The board edit form used to carry a "Release Slug"
  # text field writing metadata.devops.release_slug, and the task page rendered
  # that key. An operator could type a slug, watch it persist on the page, and
  # still have bin/conductor report no candidate — the visible value was the inert
  # one. The form field is gone and the card reads the column.

  test "[integration] the task page renders release membership from the column" do
    log_in_as(@admin)
    Release.delete_all
    release = Release.open!(branch: "release/card-proof")
    @new_task.update!(release_slug: release.slug, metadata: { "devops" => { "kind" => "feature" } })

    get task_path(@new_task.slug)

    assert_response :success
    # Linked to the release it actually rides, so the card is checkable, not just true.
    assert_select "a[href=?]", deployment_path(release.slug), text: release.slug
  end

  # THE MUTATION PROOF for the operator-facing half. The row carries a devops
  # shadow planted through update_columns (skipping every callback — the one way a
  # value can still exist there), and the column says something different. The page
  # must render the COLUMN. A reader that falls back to devops renders
  # "rel-typed-by-hand" and fails here.
  test "[integration] the task page never renders a devops release_slug shadow" do
    log_in_as(@admin)
    Release.delete_all
    release = Release.open!(branch: "release/shadow-proof")
    @new_task.update!(release_slug: release.slug)
    @new_task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      metadata: @new_task.metadata.deep_merge("devops" => { "release_slug" => "rel-typed-by-hand" })
    )

    get task_path(@new_task.slug)

    assert_response :success
    assert_no_match(/rel-typed-by-hand/, response.body,
                    "the page must never assert a release the pipeline does not know about")
    assert_select "a[href=?]", deployment_path(release.slug), text: release.slug
  end

  # NOTE: the card sits inside the `@task.devops?` panel, so the task needs devops
  # metadata for it to render at all — every task that reaches a release has some
  # (bin/task stamps kind/shape at creation).
  test "[integration] an unreleased task says so in the same words as bin/task" do
    log_in_as(@admin)
    @new_task.update!(release_slug: nil, metadata: { "devops" => { "kind" => "feature" } })

    get task_path(@new_task.slug)

    assert_response :success
    # Same wording as TaskColumnFields::UNSET_READS, so the page and the CLI
    # describe the same task identically.
    assert_match(/not on a release/, response.body)
  end

  test "[integration] the board edit form offers no release slug field" do
    log_in_as(@admin)

    get edit_task_path(@new_task.slug)

    assert_response :success
    assert_select "input[name=?]", "task[devops][release_slug]", false,
                  "membership is attached by the sweep, never typed into a form"
  end

  test "[integration] a board devops release_slug write is refused, not silently dropped" do
    log_in_as(@admin)
    @new_task.update!(release_slug: "rel-2026-08-12-real")

    patch task_path(@new_task.slug),
          params: { task: { devops: { kind: "feature", release_slug: "rel-typed-by-hand" } } },
          as: :json

    assert_response :unprocessable_entity
    assert_match(/tasks\.release_slug column/, response.parsed_body["error"].to_s)
    @new_task.reload
    assert_equal "rel-2026-08-12-real", @new_task.release_slug
    assert_not @new_task.devops.key?("release_slug")
  end

  test "update stores devops shape from html params" do
    log_in_as(@admin)

    patch task_path(@new_task.slug), params: {
      task: {
        devops: {
          kind: "feature",
          shape: "backend",
          repositories: "mcritchie-studio"
        }
      }
    }

    assert_redirected_to task_path(@new_task.slug)
    @new_task.reload
    assert_equal "backend", @new_task.devops_shape
    assert_equal "feature", @new_task.devops_kind
  end

  test "show renders devops handoff details" do
    @new_task.update!(
      metadata: {
        "devops" => {
          "kind" => "release",
          "worktree_slug" => "task-board-release",
          "repositories" => ["mcritchie-studio"],
          "qa_url" => "https://qa.mcritchie.studio/tasks",
          "acceptance" => ["Task board shows release metadata"],
          "test_plan" => ["PR review gate"],
          "checks_run" => ["bin/rails test"]
        }
      }
    )

    get task_path(@new_task.slug)

    assert_response :success
    assert_select ".label-upper", "DevOps handoff"
    assert_includes response.body, "task-board-release"
    assert_select "a[href=?]", "https://qa.mcritchie.studio/tasks"
    assert_includes response.body, "Task board shows release metadata"
    assert_includes response.body, "Expected Test Plan"
    assert_includes response.body, "Checks Run"
    assert_includes response.body, "bin/rails test"
  end

  test "show renders task conversation" do
    Activity.create!(
      task_slug: @new_task.slug,
      agent_slug: "alex",
      activity_type: "qa_feedback",
      description: "QA blocked until the sidebar branch is rebased."
    )

    get task_path(@new_task.slug)

    assert_response :success
    assert_select ".label-upper", "Conversation"
    assert_includes response.body, "QA blocked until the sidebar branch is rebased."
    assert_not_includes response.body, "Activity feed"
  end

  test "admin sees task feedback form" do
    log_in_as(@admin)

    get task_path(@new_task.slug)

    assert_response :success
    assert_select "form[action=?]", comment_task_path(@new_task.slug)
    assert_select "textarea[name='activity[description]']"
    assert_select "select[name='activity[activity_type]']"
  end

  test "admin can add task feedback from show page" do
    log_in_as(@admin)

    assert_difference "Activity.count", 1 do
      post comment_task_path(@new_task.slug),
           params: {
             activity: {
               activity_type: "qa_feedback",
               description: "Please address the QA browser-back regression."
             }
           }
    end

    assert_redirected_to task_path(@new_task.slug)
    activity = Activity.order(:created_at).last
    assert_equal @new_task.slug, activity.task_slug
    assert_equal "qa_feedback", activity.activity_type
    assert_equal "alex", activity.agent_slug
    assert_equal "task_conversation", activity.metadata["source"]
  end

  test "[integration] admin can add clarification without blocking the task" do
    log_in_as(@admin)
    @new_task.update!(stage: "submitted")

    assert_difference "Activity.count", 1 do
      post comment_task_path(@new_task.slug),
           params: {
             activity: {
               activity_type: "clarification",
               description: "Can you confirm whether the response belongs on the PR too?"
             }
           }
    end

    assert_redirected_to task_path(@new_task.slug)
    activity = Activity.order(:created_at).last
    assert_equal "clarification", activity.activity_type
    assert_equal "submitted", @new_task.reload.stage

    get tasks_path
    assert_response :success
    assert_select "#card-#{@new_task.slug} [data-test='activity-box'][data-activity-type='clarification']"
    assert_select "#card-#{@new_task.slug} [data-test='activity-type-label']", text: "Clarification"
  end

  test "task feedback requires admin" do
    log_in_as(@viewer)

    assert_no_difference "Activity.count" do
      post comment_task_path(@new_task.slug),
           params: {
             activity: {
               activity_type: "qa_feedback",
               description: "Viewer feedback should not be accepted."
             }
           }
    end

    assert_response :redirect
  end

  # === Auth enforcement ===

  test "moves require admin" do
    log_in_as(@viewer)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "done" } }, as: :json
    assert_response :redirect
  end

  test "moves require login" do
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "done" } }, as: :json
    # Format-aware auth (OPSEC-046): AJAX/JSON gets a clean 401, not an HTML redirect.
    assert_response :unauthorized
  end

  # === JSON requests work without CSRF token ===

  test "JSON PATCH works without CSRF token" do
    log_in_as(@admin)
    patch task_path(@new_task.slug, format: :json),
          params: { task: { stage: "submitted" } }, as: :json
    assert_response :success
  end

  # === Reorder ===

  test "reorder writes the 100-spaced rank, top card highest" do
    log_in_as(@admin)
    # Create two tasks in same stage
    t1 = Task.create!(title: "reorder task a here", stage: "designed")
    t2 = Task.create!(title: "reorder task b here", stage: "designed")

    # DOM order top→bottom = [t2, t1]; under `position DESC` the top card must hold
    # the highest rank, 100-spaced (index 0 → len*100, index 1 → (len-1)*100).
    post reorder_tasks_path(format: :json),
         params: { slugs: [t2.slug, t1.slug] }, as: :json
    assert_response :success

    t1.reload
    t2.reload
    assert_equal 200, t2.position, "top card (index 0) gets (len - 0) * 100"
    assert_equal 100, t1.position, "next card (index 1) gets (len - 1) * 100"
    assert_operator t2.position, :>, t1.position
  end

  test "reorder requires admin" do
    log_in_as(@viewer)
    post reorder_tasks_path(format: :json),
         params: { slugs: [@new_task.slug] }, as: :json
    assert_response :redirect
  end

  test "reorder requires login" do
    post reorder_tasks_path(format: :json),
         params: { slugs: [@new_task.slug] }, as: :json
    assert_response :unauthorized
  end
end
