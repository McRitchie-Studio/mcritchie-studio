require "test_helper"

class TasksControllerTest < ActionDispatch::IntegrationTest
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

  test "deployments shows the current-release header when a release exists" do
    rel = Release.open!(branch: "release/header-test", qa_url: "https://qa.example/tasks", deployed_sha: "abc1234def567")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)
    rel.assemble!

    get deployments_path

    assert_response :success
    assert_select "#current-release"
    assert_select "#current-release", text: /#{Regexp.escape(rel.slug)}/
    assert_select "#current-release [data-test='release-state-badge']", text: /\AAssembled .+ ago\z/ # consolidated state + time badge
    assert_select "#current-release a[href=?]", task_path(@new_task.slug) # member chip
    # "when present" fields render
    assert_select "#current-release a[href=?]", "https://qa.example/tasks" # QA link
    assert_includes response.body, "abc1234" # deployed SHA (7-char)
  end

  test "deployments rides the Build and Deploy QA Release chip inline (right) with the task pills" do
    Release.delete_all
    rel = Release.open!(branch: "release/qa-kickoff")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)

    get deployments_path

    assert_response :success
    # the kickoff chip shares the member-pills row (not a row of its own): the task
    # pill and the chip both live in the same release-members-row.
    assert_select "#current-release [data-test='release-members-row']" do
      assert_select "a[href=?]", task_path(@new_task.slug)  # the task pill
      assert_select "code", text: /Build and Deploy QA Release/ # the kickoff chip
    end
  end

  test "deployments renders the status badge above the kickoff chip on the current card" do
    Release.delete_all
    rel = Release.open!(branch: "release/badge-order")
    @new_task.update!(stage: "reviewed")
    rel.add(@new_task)
    rel.assemble!

    get deployments_path
    assert_response :success

    card = css_select("#current-release").first.to_html
    badge_at = card.index("release-state-badge")
    chip_at  = card.index("Build and Deploy QA Release")
    assert badge_at, "current card should render the status badge"
    assert chip_at, "current card should render the kickoff chip"
    assert badge_at < chip_at,
           "the top-right status badge must render before the inline kickoff chip"
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

  test "deployments omits the release header when there is no release" do
    Release.delete_all

    get deployments_path

    assert_response :success
    assert_select "#current-release", count: 0
    assert_select "#last-release", count: 0
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

    # No active release → Current shows the muted empty state + kickoff chip,
    # NOT the shipped release dressed up as "current".
    assert_select "#current-release", text: /none active/
    assert_select "#current-release", text: /Build and Deploy QA Release/ # kickoff chip
    assert_select "#current-release", { text: /#{Regexp.escape(shipped.slug)}/, count: 0 },
                  "shipped release must NOT appear under Current"

    # The shipped release lives in the read-only Last Release section.
    assert_select "#last-release"
    assert_select "#last-release", text: /Last Release/
    assert_select "#last-release", text: /#{Regexp.escape(shipped.slug)}/
    assert_select "#last-release [data-test='release-state-badge']", text: /\AShipped .+ ago\z/ # consolidated state + time badge
    assert_select "#last-release a[href=?]", task_path(@new_task.slug) # member chip
    assert_select "#last-release a[href=?]", "https://qa.example/last" # QA link
    assert_includes response.body, "9999abc" # deployed SHA (7-char)
  end

  test "deployments folds the release state + shipped time into one top-right badge" do
    # ui-only consolidation: the card used to carry BOTH a bare "shipped" state pill
    # (left, beside the slug) AND a separate muted "shipped X ago" line (right). They
    # are now ONE state-colored badge reading "Shipped <time> ago" in the header — no
    # duplicate state, no redundant timestamp line.
    Release.delete_all
    shipped = Release.open!(branch: "release/badge-consolidation")
    @new_task.update!(stage: "reviewed")
    shipped.add(@new_task)
    shipped.assemble!
    shipped.ship!

    get deployments_path
    assert_response :success

    # exactly one status badge, folding state + relative time together
    assert_select "#last-release [data-test='release-state-badge']", count: 1 do |els|
      assert_match(/\AShipped .+ ago\z/, els.first.text.strip)
    end
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

    # Both modules sit inside ONE responsive grid container: single column on
    # narrow viewports, two columns on lg+ so they render side by side.
    assert_select "div.grid.grid-cols-1.lg\\:grid-cols-2" do
      assert_select "#current-release", count: 1
      assert_select "#last-release", count: 1
    end
  end

  test "deployments empty-state Current still nests inside the responsive grid beside Last" do
    Release.delete_all
    shipped = Release.open!(branch: "release/grid-empty")
    shipped.ship!

    get deployments_path
    assert_response :success

    # Short empty-state Current + tall Last both live in the grid container.
    assert_select "div.grid.grid-cols-1.lg\\:grid-cols-2" do
      assert_select "#current-release", text: /none active/
      assert_select "#last-release", count: 1
    end
  end

  test "tasks board shows only the Build-lane columns and no release module" do
    Release.open!(branch: "release/build-only") # a release exists, but /tasks must not show it
    get tasks_path

    assert_response :success
    assert_select "h2", "Tasks"
    # Feature-agent lane (+ archived toggle column); submitted is the seam. Blocked is
    # NOT its own column anymore — blocked tasks ride the Building column.
    assert_select "#dropzone-designed"
    assert_select "#dropzone-building"
    assert_select "#dropzone-submitted"
    assert_select "#dropzone-archived"
    assert_select "#dropzone-blocked", count: 0
    # DevOps-only columns absent
    assert_select "#dropzone-reviewed", count: 0
    assert_select "#dropzone-assembled", count: 0
    assert_select "#dropzone-shipped", count: 0
    # the current-release module + kickoff chips live on /deployments, not here
    assert_select "#current-release", count: 0
    assert_not_includes response.body, "Review submitted PRs"
    assert_not_includes response.body, "Run Deployment"
  end

  test "deployments board shows the full pipeline swim lanes (designed through shipped)" do
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
    # copy-paste kickoff commands sit on the column headers
    assert_includes response.body, "Review submitted PRs"
    assert_includes response.body, "Run Deployment"
    # the shipped column's kickoff is the DevOps loop's conclusion
    assert_includes response.body, "Archive completed tasks"
  end

  test "blocked tasks ride the Building column (red hue) on both boards" do
    blocked = Task.create!(title: "blocked rides building", stage: "blocked")
    [tasks_path, deployments_path].each do |path|
      get path
      assert_response :success
      assert_select "#dropzone-building #card-#{blocked.slug}[class*=bg-red]", true,
                    "blocked card should ride the Building column with a red hue on #{path}"
    end
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
  end

  test "stages page outlines tests-run and gate for the Deploy lane" do
    get stages_path
    assert_response :success

    # Deploy steps now spell out their tests-run + gate (devops-cycle-design §1.2)
    assert_includes response.body, "Tests run"
    assert_includes response.body, "Gate"
    assert_includes response.body, "two senior reviewers"     # review delegated, not Avi-solo
    assert_includes response.body, "FROZEN ship SHA"          # Avi's ship-time suite
    assert_includes response.body, "operator gate"            # the one human gate
  end

  test "deployments and stages are public (no login required)" do
    get deployments_path
    assert_response :success
    get stages_path
    assert_response :success
  end

  test "each board page cross-links to the other boards" do
    # The active board hides its own (redundant) toggle button, so a page links
    # to the OTHER board(s); Stages stays reachable from the top-links nav.
    { tasks_path => "tasks", deployments_path => "deployments", stages_path => "stages" }.each do |page, current|
      get page
      assert_response :success
      assert_select %(nav a[href="#{stages_path}"]), { minimum: 1 }, "#{page} missing Stages nav link"
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
                        { "slug" => "shannon", "weight" => "heavy" },
                        { "slug" => "carl", "weight" => "light" }
                      ] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon") # 30m
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi") # 10m
    task
  end

  test "deployments board card shows the deploy crew with avatars and compact durations" do
    task = seed_deploy_crew_task(steffon_avatar: "https://example.com/steffon.png")

    get deployments_path
    assert_response :success

    card = "#card-#{task.slug}"
    assert_select "#{card} [data-test='stage-agent-avatars']"
    # Steffon's image avatar renders (the others fall back to initials)
    assert_select "#{card} img[src='https://example.com/steffon.png']"
    # The Deploy lane is SPLIT into separate compartments (review · assembled ·
    # shipped), each carrying its OWN compact corner pill — assembled (Steffon) and
    # shipped (Avi) are NOT collapsed into one combined deploy duration. This seed has
    # no build-lane events, so three pills land, asserted on the real crew-duration
    # markers (not loose body text): 7200s → 2h (longer review), 1800s → 30m
    # (assembled, its own pill), 600s → 10m (shipped, its own pill).
    pills = "#{card} [data-test='crew-duration']"
    assert_select pills, count: 3
    assert_select pills, text: /2h/  # review compartment (max of the two reviewers)
    assert_select pills, text: /30m/ # assembled compartment (Steffon) — its own pill
    assert_select pills, text: /10m/ # shipped compartment (Avi) — its own pill
  end

  test "task show renders the detailed deploy crew with stage badges, names, weights and durations" do
    task = seed_deploy_crew_task

    get task_path(task.slug)
    assert_response :success

    assert_select "[data-test='stage-agent-avatars']"
    # The detail crew header is "Stage crew" (the whole-journey label) — asserted on
    # the REAL rendered header. The old `response.body` include of "Deploy crew" only
    # passed incidentally because this seed task's TITLE contains "Deploy crew", so it
    # no longer reflected the rendered UI after the header was renamed.
    assert_select "[data-test='stage-agent-avatars'] p.label-upper", text: /Stage crew/
    # one studio-engine badge per completed stage group (reviewed, assembled, shipped)
    assert_select "[data-test='stage-agent-avatars'] span.badge", count: 3
    # every soul is named
    %w[Shannon Carl Steffon Avi].each { |name| assert_includes response.body, name }
    # heavy/light review weights surface
    assert_select "[data-test='stage-agent-avatars']", text: /heavy/
    assert_select "[data-test='stage-agent-avatars']", text: /light/
    # full humanized durations (7200s → about 2 hours), labelled by the stage left
    assert_select "[data-test='stage-agent-avatars']", text: /about 2 hours in Submitted/
  end

  test "task show omits the deploy crew for an old-flow task lacking reviewers and actors" do
    # a shipped task whose Deploy events were conductor-driven (no actor) and that
    # predates the two-senior model (no reviewers metadata) shows no crew.
    task = Task.create!(title: "Old flow crewless task", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 2.hours.ago, seconds_in_from: 600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 1.hour.ago, seconds_in_from: 600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 30.minutes.ago, seconds_in_from: 600)

    get task_path(task.slug)
    assert_response :success
    assert_select "[data-test='stage-agent-avatars']", count: 0
    assert_not_includes response.body, "Deploy crew"
  end

  test "build-lane board cards render no deploy-crew avatars" do
    get tasks_path
    assert_response :success
    assert_select "#card-#{@in_progress_task.slug} [data-test='stage-agent-avatars']", count: 0
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

  test "move task to blocked sets blocked_at and captures blocked_from" do
    log_in_as(@admin)
    patch task_path(@in_progress_task.slug, format: :json),
          params: { task: { stage: "blocked" } }, as: :json
    assert_response :success
    @in_progress_task.reload
    assert_equal "blocked", @in_progress_task.stage
    assert_not_nil @in_progress_task.blocked_at
    assert_equal "building", @in_progress_task.blocked_from
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
            worktree_slug: "contest-flow",
            repositories: "turf-monster, turf-vault",
            branch: "feat/contest-flow",
            pr_url: "https://github.com/amcritchie/turf-monster/pull/149",
            qa_url: "https://qa.turfmonster.media/contests",
            release_train: "2026-06-17-turf",
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
    assert_equal "contest-flow", task.devops_worktree_slug
    assert_equal ["turf-monster", "turf-vault"], task.devops_repositories
    assert_equal ["Contest creates on QA without errors", "Entry submits successfully on QA devnet"], task.devops_acceptance
    assert_equal ["bin/rails test test/controllers/tasks_controller_test.rb"], task.devops_checks_run
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
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

  test "reorder sets positions in order" do
    log_in_as(@admin)
    # Create two tasks in same stage
    t1 = Task.create!(title: "reorder task a here", stage: "designed")
    t2 = Task.create!(title: "reorder task b here", stage: "designed")

    # Reorder: B before A
    post reorder_tasks_path(format: :json),
         params: { slugs: [t2.slug, t1.slug] }, as: :json
    assert_response :success

    t1.reload
    t2.reload
    assert_equal 1, t1.position
    assert_equal 0, t2.position
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
