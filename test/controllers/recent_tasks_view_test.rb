require "test_helper"

# /tasks/recent — the flat recency list showcasing per-task testing-phase
# durations + gate verdict chips. Public-read; the kanban board is untouched.
class RecentTasksViewTest < ActionDispatch::IntegrationTest
  setup do
    @new_task = tasks(:new_task)
    @in_progress_task = tasks(:in_progress_task)
  end

  test "[component] recent lists tasks newest-updated first with stamped phase duration cells" do
    build_start = Time.zone.parse("2026-07-08 10:05:00")
    build_end = build_start + 7440
    cert_start = Time.zone.parse("2026-07-08 12:30:00")
    @new_task.update_columns(updated_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
    @in_progress_task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      updated_at: 2.hours.ago,
      testing_phases_version: Task::TestingPhases::VERSION,
      testing_phases: { "phases" => {
        "build" => { "status" => "completed", "seconds" => 7440,
                     "started_at" => build_start.iso8601, "completed_at" => build_end.iso8601 },
        "local_certification" => { "status" => "in_progress", "seconds" => 300,
                                   "started_at" => cert_start.iso8601 },
        "ci" => { "status" => "missing" },
        "review" => { "status" => "missing" }
      } }
    )

    get recent_tasks_path

    assert_response :success
    assert_select "h1", "Recent Tasks"
    assert_select "li[data-test=?]", "recent-task-row", minimum: 2

    newer = response.body.index("data-task-slug=\"#{@new_task.slug}\"")
    older = response.body.index("data-task-slug=\"#{@in_progress_task.slug}\"")
    assert newer && older, "both controlled tasks render rows"
    assert newer < older, "the more recently updated task renders first"

    assert_includes response.body, "2h 4m",
                    "a completed phase renders the compact two-unit duration"
    assert_includes response.body, "5m+",
                    "an in-progress phase ticks with a trailing plus"

    # The releases-table stamp treatment: epoch-carrying range stacks under the
    # duration — a closed span has data-start AND data-end, an in-progress span
    # renders the open "start → …" clock line.
    assert_select "li[data-task-slug=?]", @in_progress_task.slug do
      assert_select "[data-deployment-range][data-start=?][data-end=?]",
                    build_start.to_i.to_s, build_end.to_i.to_s
      assert_select "[data-deployment-range][data-start=?]:not([data-end])", cert_start.to_i.to_s
      assert_select "[data-range-date]", { text: "Jul 8, 2026", minimum: 1 }
      assert_select "[data-range-time]", text: "10:05a → 12:09p"
      assert_select "[data-range-time]", text: "12:30p → …"
    end
    assert_includes response.body, "deploymentRangeFmt",
                    "the client-TZ re-stamp script rides the page"
  end

  test "[component] recent renders stamped gate cells including the failed-then-passed retry story" do
    opened = Time.zone.parse("2026-07-08 09:00:00")
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", success: false, now: opened)
    GateRun.open!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", now: opened + 10.minutes)
    GateRun.close!(subject_type: "task", subject_slug: @new_task.slug, key: "g1_cert", success: true, now: opened + 17.minutes)
    GateRun.open!(subject_type: "task", subject_slug: @new_task.slug, key: "g2a_primary")

    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug do
      assert_select "[data-test=?]", "recent-gate-chip", count: 2
      assert_select "[data-test=?]", "recent-gate-attempts", text: "×2"
      # Each gate cell carries the same stamp stack as the phase cells; the
      # in-flight review renders the open clock line.
      assert_select "[data-test='recent-gate-chip'] [data-deployment-range]", count: 2
      assert_select "[data-range-time]", text: "9:10a → 9:17a"
      assert_select "[data-range-time]", text: /→ …/
    end
    assert_includes response.body, "attempt 2",
                    "the retry story stays one hover away on the cell title"
    assert_includes response.body, "G1 Cert"
    assert_includes response.body, "G2a Primary"
  end

  test "[component] phase tiles wear owner avatars and the review lanes break out primary + light" do
    pikachu = Pokemon.create!(dex: 9001, name: "Pikachu", slug: "pikachu", sprite_url: "/pokemon/pikachu.png")
    Agent.create!(name: "Avi", slug: "avi", avatar: "/agents/avi.png")
    Agent.create!(name: "Shannon", slug: "shannon", avatar: "/agents/shannon.png")
    Agent.create!(name: "Carl", slug: "carl", avatar: "/agents/carl.png")

    @in_progress_task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      updated_at: 1.minute.ago,
      metadata: { "devops" => { "mascot" => pikachu.slug } }
    )

    primary_start = Time.zone.parse("2026-07-08 14:00:00")
    GateRun.open!(subject_type: "task", subject_slug: @in_progress_task.slug, key: "g2a_primary",
                  actor: "shannon", now: primary_start)
    GateRun.close!(subject_type: "task", subject_slug: @in_progress_task.slug, key: "g2a_primary",
                   success: true, actor: "shannon", now: primary_start + 12.minutes)
    light_start = Time.zone.parse("2026-07-08 14:05:00")
    GateRun.open!(subject_type: "task", subject_slug: @in_progress_task.slug, key: "g2b_light",
                  actor: "carl", now: light_start)
    GateRun.close!(subject_type: "task", subject_slug: @in_progress_task.slug, key: "g2b_light",
                   success: true, actor: "carl", now: light_start + 6.minutes)

    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @in_progress_task.slug do
      # Every phase tile wears its owner: mascot on Build/Cert/CI, Avi on Review.
      assert_select "[data-test='recent-task-phases'] [data-test='phase-tile-avatar']", count: 4
      assert_select "[data-test='recent-task-phases'] img[src=?]", "/pokemon/pikachu.png",
                    { minimum: 3 }, "the mascot sprite fronts the three machine phases"
      assert_select "[data-test='recent-task-phases'] img[src=?]", "/agents/avi.png",
                    { count: 1 }, "Avi fronts the Review tile"

      # The review lanes break the overall Review duration into its two seats,
      # each with its reviewer soul + duration.
      assert_select "[data-test=?]", "recent-review-lanes", count: 1
      assert_select "[data-test=?]", "recent-review-lane", count: 2
      assert_select "[data-test='recent-review-lane'] img[src=?]", "/agents/shannon.png", count: 1
      assert_select "[data-test='recent-review-lane'] img[src=?]", "/agents/carl.png", count: 1
      assert_select "[data-test='recent-review-lane']", text: /Primary/
      assert_select "[data-test='recent-review-lane']", text: /Light/
      assert_select "[data-test='recent-review-lane']", text: /12m/
      assert_select "[data-test='recent-review-lane']", text: /6m/
    end
  end

  test "[component] a task with no phases and no gate runs reads as a clean sparse row" do
    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug do
      assert_select "[data-test=?]", "recent-task-phases", count: 1
      assert_select "[data-test=?]", "recent-gate-chip", count: 0
      assert_select "[data-deployment-range]", count: 0
    end
    assert_includes response.body, "—", "never-run phases render dashes, not blanks"
  end

  test "[component] the phase strip renders exactly the four v2 cells, no Accept track" do
    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug do
      # PHASE_KEYS now yields four phases — one cell each, no vestigial fifth track.
      assert_select "[data-test='recent-task-phases'] > div", count: 4
      assert_select "[data-test='recent-task-phases']" do
        assert_select "p", text: "Build"
        assert_select "p", text: "Review"
        assert_select "p", text: "Accept", count: 0
      end
    end
    assert_not_includes response.body, "Operator Acceptance",
                        "the v1 acceptance phase left the public recency surface"
  end

  test "[component] recent excludes archived tasks" do
    @new_task.update_columns(stage: "archived") # rubocop:disable Rails/SkipsModelValidations

    get recent_tasks_path

    assert_response :success
    assert_select "li[data-task-slug=?]", @new_task.slug, count: 0
  end
end
