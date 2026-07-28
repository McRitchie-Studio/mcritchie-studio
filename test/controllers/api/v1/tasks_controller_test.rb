require "test_helper"

module Api
  module V1
    class TasksControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      # Stands in for Avi::Sizer.new(task) in the perform-through sizing test.
      SizerReturning = Struct.new(:size) { def call = size }

      setup do
        @task = tasks(:new_task)
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      # [integration] The show projection carries the PROGRESS fact beside the claim.
      # bin/task's claim gate reads these to tell a second agent what the holder has
      # actually produced ("last durable progress 2.5h ago · g1_cert failed") instead
      # of inferring health from a heartbeat that survives a wedge.
      test "show projects the progress fact alongside the live claim" do
        now = Time.current
        task = tasks(:in_progress_task)
        task.update!(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: now) })
        TaskEvent.where(task_slug: task.slug).delete_all
        # to_stage IS the checkpoint's name (record_checkpoint_event writes it there).
        TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::CHECKPOINT, occurred_at: now - 3.minutes,
                          from_stage: "building", to_stage: "cert", metadata: { "status" => "started" })

        get api_v1_task_path(task.slug), headers: @headers

        assert_response :success
        body = response.parsed_body["data"]
        assert_in_delta 180, body["progress_seconds_ago"], 5
        assert_equal "cert started", body["last_progress_label"]
        assert_equal false, body["progress_quiet"]
        assert body["last_progress_at"].present?
      end

      # The projection the claim gate reads must name a NON-cert checkpoint correctly:
      # this is the string a second agent sees before deciding to take the desk.
      test "show names a review check-in by its own lane, not as a cert" do
        now = Time.current
        task = tasks(:in_progress_task)
        task.update!(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: now) })
        TaskEvent.where(task_slug: task.slug).delete_all
        TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::CHECKPOINT, occurred_at: now - 3.minutes,
                          from_stage: "building", to_stage: "review_primary_complete",
                          metadata: { "status" => "passed" })

        get api_v1_task_path(task.slug), headers: @headers

        assert_response :success
        assert_equal "review_primary_complete passed", response.parsed_body["data"]["last_progress_label"]
      end

      # A live claim that has landed nothing in hours reads quiet — and the lease is
      # untouched by it. The task is still HELD; nothing was reclaimed.
      test "show reports a quiet claim without touching the lease" do
        now = Time.current
        task = tasks(:in_progress_task)
        task.update!(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: now) })
        TaskEvent.where(task_slug: task.slug).delete_all
        silence = ClaimLease::PROGRESS_QUIET_SECONDS + 30.minutes
        TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::CHECKPOINT, occurred_at: now - silence,
                          from_stage: "building", to_stage: "cert", metadata: { "status" => "started" })
        lease_before = task.devops.slice(*ClaimLease::CLAIM_KEYS)

        get api_v1_task_path(task.slug), headers: @headers

        assert_equal true, response.parsed_body["data"]["progress_quiet"]
        assert_equal lease_before, task.reload.devops.slice(*ClaimLease::CLAIM_KEYS),
                     "reading the progress fact must never mutate the claim"
        assert task.claim_live?, "a quiet desk is still an occupied desk"
      end

      # Fail safe: a task with no durable artifact reads UNKNOWN, never quiet.
      test "show reports unknown progress for a task that has produced nothing" do
        task = tasks(:in_progress_task)
        task.update!(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A") })
        TaskEvent.where(task_slug: task.slug).delete_all

        get api_v1_task_path(task.slug), headers: @headers

        body = response.parsed_body["data"]
        assert_nil body["progress_seconds_ago"]
        assert_nil body["last_progress_at"]
        assert_equal false, body["progress_quiet"], "absence of evidence must never read as trouble"
      end

      test "update stores devops metadata" do
        patch api_v1_task_path(@task.slug),
              params: {
                title: @task.title,
                devops: {
                  kind: "bug",
                  worktree_slug: "task-board-contract",
                  repositories: "mcritchie-studio",
                  local_url: "http://localhost:3004/tasks",
                  qa_url: "https://qa.mcritchie.studio/tasks",
                  release_slug: "rel-2026-06-17-studio",
                  requires_release_conductor: "true",
                  acceptance: ["Task card shows the devops metadata", "QA URL opens the QA board"],
                  test_plan: "bin/rails test",
                  checks_run: ["bin/rails test test/controllers/api/v1/tasks_controller_test.rb"]
                }
              },
              headers: @headers,
              as: :json

        assert_response :success
        @task.reload
        assert_equal "bug", @task.devops_kind
        assert_equal "task-board-contract", @task.devops_worktree_slug
        assert_equal ["mcritchie-studio"], @task.devops_repositories
        assert_equal "http://localhost:3004/tasks", @task.devops_url(:local)
        assert_equal ["Task card shows the devops metadata", "QA URL opens the QA board"], @task.devops_acceptance
        assert_equal ["bin/rails test test/controllers/api/v1/tasks_controller_test.rb"], @task.devops_checks_run
        assert @task.requires_release_conductor?
      end

      # --- Cert evidence is a MACHINE-OWNED namespace (regression: an agent that
      # recorded its tier-tagged test plan AFTER certifying wiped the
      # fingerprint-bound cert lines, and bin/dor-check then reported
      # "full-suite: MISSING" on code it had just certified). The API is the path
      # bin/task PATCHes, so the guard must hold here, not only in the CLI. ---

      test "[integration] api checks_run update preserves cert evidence" do
        full = "[full-suite@1512171634558ef1234567890abcdef123456789] bin/rails test (782 runs, 0 failures)"
        rubocop = "[rubocop@1512171634558ef1234567890abcdef123456789] bin/rubocop (clean)"
        task = Task.create!(
          title: "Api Cert Evidence Guard",
          stage: "building",
          metadata: { "devops" => { "kind" => "bug", "checks_run" => [full, rubocop] } }
        )

        # The exact payload `bin/task update <slug> --checks "[unit] ..."` sends
        # once the CLI's read-merge is out of the picture: author lines only.
        patch api_v1_task_path(task.slug),
              params: { devops: { kind: "bug", checks_run: ["[unit] bin/rails test test/models"] } },
              headers: @headers,
              as: :json

        assert_response :success
        task.reload
        assert_includes task.devops_checks_run, full, "the API dropped the full-suite cert evidence"
        assert_includes task.devops_checks_run, rubocop, "the API dropped the rubocop cert evidence"
        assert_includes task.devops_checks_run, "[unit] bin/rails test test/models"
      end

      # --- Operator approval lane (regression: a builder PATCHed
      # approval_status=approved right after submitting — self-approving its own
      # demo). Approving belongs to the admin-gated board UI; API bearer writes
      # may only request approval. ---

      test "[integration] api update cannot self-approve operator approval" do
        task = Task.create!(
          title: "Approval Api Guard",
          stage: "building", # a waiting request only lives pre-seam (the settle invariant)
          metadata: { "devops" => { "approval_status" => "waiting" } }
        )

        patch api_v1_task_path(task.slug),
              params: { devops: { approval_status: "approved" } },
              headers: @headers,
              as: :json

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_match(/operator/i, body["error"])
        task.reload
        assert_equal "waiting", task.approval_status
        assert_nil task.devops["approval_approved_at"]
      end

      test "[integration] api update keeps approval waiting writable" do
        task = Task.create!(
          title: "Approval Api Waiting",
          stage: "building",
          metadata: { "devops" => { "local_url" => "http://localhost:3021/tasks" } }
        )

        patch api_v1_task_path(task.slug),
              params: { devops: { approval_status: "waiting", local_url: "http://localhost:3021/tasks" } },
              headers: @headers,
              as: :json

        assert_response :success
        task.reload
        assert_equal "waiting", task.approval_status
        assert task.devops["approval_requested_at"].present?
      end

      test "[integration] api update echoing prior approval stays accepted" do
        task = Task.create!(
          title: "Approval Api Echo",
          stage: "submitted",
          metadata: { "devops" => { "approval_status" => "approved" } }
        )

        # bin/task update replaces the whole devops hash, echoing the operator's
        # earlier approval alongside the new field — a non-flip must pass.
        patch api_v1_task_path(task.slug),
              params: { devops: { approval_status: "approved", pr_url: "https://github.com/x/y/pull/2" } },
              headers: @headers,
              as: :json

        assert_response :success
        task.reload
        assert_equal "approved", task.approval_status
        assert_equal "https://github.com/x/y/pull/2", task.devops["pr_url"]
      end

      # Rework regression (Carl primary request-changes): the bearer API sets
      # Current.task_event_source from the request body, so a forged
      # event.source="web" would let an agent claim the operator lane and
      # self-approve in one PATCH. The controller now clamps a forged operator
      # source back to "api", so the model guard still rejects the flip.
      test "[integration] api bearer cannot forge operator source to self-approve" do
        task = Task.create!(
          title: "Approval Source Forge",
          stage: "building", # a waiting request only lives pre-seam (the settle invariant)
          metadata: { "devops" => { "approval_status" => "waiting" } }
        )

        patch api_v1_task_path(task.slug),
              params: { event: { source: "web" }, devops: { approval_status: "approved" } },
              headers: @headers,
              as: :json

        assert_response :unprocessable_entity
        assert_match(/operator/i, JSON.parse(response.body)["error"])
        task.reload
        assert_equal "waiting", task.approval_status
        assert_nil task.devops["approval_approved_at"]
      end

      # Second bypass vector: approval_approved_at is an agent-writable devops
      # scalar and TestingPhases#acceptance_phase trusts it, so stamping it
      # directly would close the acceptance phase without ever touching
      # approval_status. A forged operator source must not enable that either.
      test "[integration] api bearer cannot stamp approval timestamp to close acceptance" do
        task = Task.create!(
          title: "Approval Timestamp Forge",
          stage: "building", # a waiting request only lives pre-seam (the settle invariant)
          metadata: { "devops" => { "approval_status" => "waiting" } }
        )

        patch api_v1_task_path(task.slug),
              params: { event: { source: "web" }, devops: { approval_approved_at: Time.current.iso8601 } },
              headers: @headers,
              as: :json

        assert_response :unprocessable_entity
        assert_match(/operator/i, JSON.parse(response.body)["error"])
        assert_nil task.reload.devops["approval_approved_at"]
      end

      # The clamp targets ONLY the operator claim — a forged source with a benign
      # agent-writable status must still succeed (source normalized to "api").
      test "[integration] forged operator source still allows waiting request" do
        task = Task.create!(
          title: "Approval Forge Waiting",
          stage: "building",
          metadata: { "devops" => { "local_url" => "http://localhost:3021/tasks" } }
        )

        patch api_v1_task_path(task.slug),
              params: { event: { source: "web" }, devops: { approval_status: "waiting", local_url: "http://localhost:3021/tasks" } },
              headers: @headers,
              as: :json

        assert_response :success
        assert_equal "waiting", task.reload.approval_status
      end

      test "create preserves commas inside array acceptance items" do
        post api_v1_tasks_path,
             params: {
               title: "Comma in acceptance",
               devops: {
                 repositories: ["mcritchie-studio"],
                 acceptance: ["Header stays pinned, even while scrolling", "Email still works as expected"]
               }
             },
             headers: @headers,
             as: :json

        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        created = Task.find_by!(slug: slug)
        assert_equal ["Header stays pinned, even while scrolling", "Email still works as expected"], created.devops_acceptance
      end

      test "create with a custom slug sets a readable slug and trickles to worktree_slug + branch" do
        post api_v1_tasks_path,
             params: { slug: "Readable Handle Here", title: "valid four word title", devops: { repositories: ["mcritchie-studio"] } },
             headers: @headers,
             as: :json

        assert_response :created
        created = Task.find_by!(slug: "readable-handle-here")
        assert_equal "readable-handle-here", created.devops_worktree_slug
        assert_equal "feat/readable-handle-here", created.metadata.dig("devops", "branch")
      end

      test "update ignores a slug in the body (slug is create-only)" do
        original = @task.slug
        patch api_v1_task_path(@task.slug),
              params: { slug: "hacked-slug", title: "renamed task title here" },
              headers: @headers,
              as: :json

        assert_response :success
        @task.reload
        assert_equal original, @task.slug, "update must not change the immutable slug"
        assert_equal "renamed task title here", @task.title
      end

      test "create enforces the 3-5 word title (naming discipline)" do
        post api_v1_tasks_path,
             params: { title: "way too many words in this task title now" }, # 9 words
             headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match(/3-5 words/, JSON.parse(response.body)["error"])
      end

      test "create enforces 5-12 word acceptance bullets" do
        post api_v1_tasks_path,
             params: { title: "valid four word title", devops: { acceptance: ["too short"] } },
             headers: @headers, as: :json
        assert_response :unprocessable_entity
      end

      test "create accepts a compliant title and acceptance" do
        post api_v1_tasks_path,
             params: { title: "valid four word title", devops: { acceptance: ["the user can log in fine"] } },
             headers: @headers, as: :json
        assert_response :created
      end

      # A scalar `event` (e.g. ?event=foo) used to raise TypeError in the
      # before_action when it symbol-indexed a String. Guard it: the move still
      # lands and source falls back to the default "api".
      test "a scalar event param does not raise and falls back to source=api" do
        patch api_v1_task_path(@task.slug),
              params: { stage: "building", event: "oops" },
              headers: @headers, as: :json

        assert_response :success
        @task.reload
        event = @task.task_events.chronological.last
        assert_equal "building", event.to_stage
        assert_equal "api", event.source
      end

      test "create assigns a Pokemon mascot persisted in devops" do
        Pokemon.create!(dex: 905, name: "Snorlax", slug: "snorlax", generation: 1)
        post api_v1_tasks_path,
             params: { title: "Api mascot create task", devops: { repositories: ["mcritchie-studio"] } },
             headers: @headers, as: :json

        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        assert_equal "snorlax", Task.find_by!(slug: slug).devops["mascot"]
      end

      test "create honors an explicit mascot through devops normalization" do
        post api_v1_tasks_path,
             params: { title: "Api mascot override task", devops: { repositories: ["mcritchie-studio"], mascot: "gyarados" } },
             headers: @headers, as: :json

        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        assert_equal "gyarados", Task.find_by!(slug: slug).devops["mascot"]
      end

      # --- Fix (A): a missing slug returns a clean 404, not a 500 ---------------

      # The exact body is a CONTRACT, not cosmetics: bin/task's not-found
      # classifier (task_not_found_response? -> EXIT_TASK_NOT_FOUND) and the
      # older-CLI stderr fallback in bin/agent-worktree both key on this exact
      # "task not found" message. Rewording it downgrades a genuine not-found to
      # a failed read (fail-safe, but it wedges reclaim for deleted slugs) —
      # change all three together or not at all.
      test "show returns 404 with a JSON error for an unknown slug" do
        get api_v1_task_path("does-not-exist-slug"), headers: @headers, as: :json

        assert_response :not_found
        assert_equal "task not found", JSON.parse(response.body)["error"]
      end

      test "show returns 200 for a known slug" do
        get api_v1_task_path(@task.slug), headers: @headers, as: :json

        assert_response :success
        assert_equal @task.slug, JSON.parse(response.body).dig("data", "slug")
      end

      test "show includes latest task conversation activity" do
        Activity.create!(
          task_slug: @task.slug,
          activity_type: "comment",
          description: "Older note."
        )
        latest = Activity.create!(
          task_slug: @task.slug,
          activity_type: "qa_feedback",
          description: "Latest blocker feedback."
        )

        get api_v1_task_path(@task.slug), headers: @headers, as: :json

        assert_response :success
        activity = response.parsed_body.dig("data", "latest_activity")
        assert_equal latest.id, activity.fetch("id")
        assert_equal "qa_feedback", activity.fetch("activity_type")
        assert_equal "Latest blocker feedback.", activity.fetch("description")
      end

      test "show includes unresolved feedback and review progress state" do
        @task.update!(stage: "submitted")
        @task.record_intent_event(
          to_stage: "reviewed",
          reviewers: [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }]
        )
        Activity.create!(
          task_slug: @task.slug,
          activity_type: "qa_feedback",
          description: "Needs rework before release."
        )
        Activity.create!(
          task_slug: @task.slug,
          activity_type: "handoff",
          description: "Clarifying context only."
        )

        get api_v1_task_path(@task.slug), headers: @headers, as: :json

        assert_response :success
        task = response.parsed_body.fetch("data")
        assert_equal true, task.fetch("review_in_progress")
        feedback = task.fetch("unresolved_feedback")
        assert_equal "qa_feedback", feedback.fetch("activity_type")
        assert_equal "Needs rework before release.", feedback.fetch("description")
      end

      test "[integration] show JSON includes the gates projection with the latest attempt" do
        GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert", success: true,
                       sops: [{ "sop" => "full-suite", "result" => "pass" }])

        get api_v1_task_path(@task.slug), headers: @headers, as: :json

        assert_response :success
        gates = response.parsed_body.dig("data", "gates", "gates")
        assert_equal 1, gates.dig("g1_cert", "attempt")
        assert_equal true, gates.dig("g1_cert", "success")
        assert_equal ["full-suite"], gates.dig("g1_cert", "sops").map { |s| s["sop"] }
        assert_nil gates.dig("g2a_primary", "attempt"), "never-attempted gate carries the all-nil row"
      end

      test "[integration] show self-heals a stale gates cache from gate_runs" do
        GateRun.close!(subject_type: "task", subject_slug: @task.slug, key: "g2b_light", success: false)
        # Simulate a pre-backfill / version-bumped row: raw column is stale.
        @task.update_columns(gates: {}, gates_version: 0)

        get api_v1_task_path(@task.slug), headers: @headers, as: :json

        assert_response :success
        gates = response.parsed_body.dig("data", "gates", "gates")
        assert_equal false, gates.dig("g2b_light", "success"), "stale cache rebuilds live from gate_runs"
      end

      test "update returns 404 for an unknown slug" do
        patch api_v1_task_path("nope-not-here"),
              params: { title: "renamed task title here" }, headers: @headers, as: :json

        assert_response :not_found
        assert_equal "task not found", JSON.parse(response.body)["error"]
      end

      test "destroy returns 404 for an unknown slug" do
        delete api_v1_task_path("nope-not-here"), headers: @headers, as: :json

        assert_response :not_found
      end

      # --- Fix (B): list includes stage + rejects unsupported filter params -----

      test "index includes each task's stage so callers skip a per-task show" do
        get api_v1_tasks_path, headers: @headers, as: :json

        assert_response :success
        items = JSON.parse(response.body)["data"]
        assert items.any?, "expected fixtures to produce list items"
        items.each { |item| assert item.key?("stage"), "list item missing stage: #{item['slug']}" }
        in_progress = items.find { |item| item["slug"] == tasks(:in_progress_task).slug }
        assert_equal "building", in_progress["stage"]
      end

      test "index filters by stage" do
        get api_v1_tasks_path(stage: "building"), headers: @headers, as: :json

        assert_response :success
        items = JSON.parse(response.body)["data"]
        assert items.any?, "expected at least one building task"
        assert(items.all? { |item| item["stage"] == "building" })
      end

      test "index rejects an unsupported filter param instead of returning all" do
        get api_v1_tasks_path(status: "submitted"), headers: @headers, as: :json

        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "UNSUPPORTED_PARAM", body["error_code"]
        assert_match(/status/, body["error"])
        assert_match(/did you mean 'stage'/, body["error"])
      end

      test "index still accepts pagination params" do
        get api_v1_tasks_path(page: 1, per_page: 2), headers: @headers, as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert_operator body["data"].size, :<=, 2
        assert_equal 2, body.dig("meta", "per_page")
      end

      # The persona round-trip over the API — what `bin/task --persona <soul>` drives:
      # setting it stamps the soul as the status-line mascot, and `--persona none`
      # reverts to a session Pokémon (the mid-task clear path).
      test "persona via the API stamps the soul, and persona none reverts to a Pokemon" do
        Agent.create!(name: "Jasper", slug: "jasper", status: "active",
                      metadata: { "emoji" => "🧪", "color" => "#9945FF" })
        Pokemon.create!(dex: 9001, name: "Snorlax", slug: "snorlax", generation: 1)

        patch api_v1_task_path(@task.slug), params: { devops: { persona: "jasper" } }, headers: @headers, as: :json
        assert_response :success
        assert_equal "Jasper", @task.reload.devops["mascot"], "the soul becomes the mascot"
        assert_equal "🧪", @task.devops["mascot_emoji"]

        patch api_v1_task_path(@task.slug), params: { devops: { persona: "none" } }, headers: @headers, as: :json
        assert_response :success
        assert_equal "snorlax", @task.reload.devops["mascot"], "persona none reverts to the Pokemon"
        assert_nil @task.devops["persona"], "the persona key is dropped"
      end

      # The size trio is permitted as top-level columns so bin/task's --po-size /
      # --dev-size / --pm-size (and the building-claim --dev-size) actually persist.
      test "update permits the size columns at top level" do
        patch api_v1_task_path(@task.slug),
              params: { po_size: "medium", dev_size: "large", pm_size: "small" },
              headers: @headers, as: :json

        assert_response :success
        @task.reload
        assert_equal "medium", @task.po_size
        assert_equal "large", @task.dev_size
        assert_equal "small", @task.pm_size
      end

      test "update rejects an out-of-range size with a 422" do
        patch api_v1_task_path(@task.slug), params: { po_size: "huge" }, headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_nil @task.reload.po_size, "an invalid size is not persisted"
      end

      # The accepted-ladder's first rung: `bin/task merged <slug> accepted` PATCHes
      # the git-location as a top-level column, so `merged` must be permitted.
      test "update permits the merged git-location and validates it" do
        patch api_v1_task_path(@task.slug), params: { merged: "accepted" }, headers: @headers, as: :json
        assert_response :success
        assert_equal "accepted", @task.reload.merged

        patch api_v1_task_path(@task.slug), params: { merged: "nowhere" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "accepted", @task.reload.merged, "an unknown git-location is rejected, not persisted"
      end

      # End-to-end size lifecycle through the API: Avi creates + sizes (po_size) →
      # the builder claims at building (dev_size) → ship auto-derives actual_size
      # from the measured token total. The trio (po/dev/actual) all land.
      test "size lifecycle: create po_size, claim dev_size, ship auto-derives actual_size" do
        # 1) Avi creates and sizes the task (po_size — the default sizer).
        post api_v1_tasks_path,
             params: { title: "Sized lifecycle demo task", po_size: "medium", devops: { shape: "backend" } },
             headers: @headers, as: :json
        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        task = Task.find_by!(slug: slug)
        assert_equal "medium", task.po_size

        # 2) The builder claims it at `building`, stamping its own dev_size.
        patch api_v1_task_path(slug), params: { stage: "building", dev_size: "large" }, headers: @headers, as: :json
        assert_response :success
        task.reload
        assert_equal "building", task.stage
        assert_equal "large", task.dev_size

        # Measured $cost accumulates across the build (recorded on TaskEvents).
        task.task_events.create!(to_stage: "building", occurred_at: Time.current,
                                 cost: BigDecimal("75")) # $75 → large ($50-$200)

        # 3) Ship → actual_size auto-derives from the measured cost total.
        patch api_v1_task_path(slug), params: { stage: "shipped" }, headers: @headers, as: :json
        assert_response :success
        task.reload
        assert_equal "shipped", task.stage
        assert_equal "medium", task.po_size, "the PO forecast is retained"
        assert_equal "large", task.dev_size, "the dev forecast is retained"
        assert_equal "large", task.actual_size, "actual_size auto-derives from measured usage at ship"
      end

      test "creating a task without a po_size enqueues Avi's async sizer" do
        assert_enqueued_jobs 1, only: AviSizingJob do
          post api_v1_tasks_path,
               params: { title: "Api sizes this one" },
               headers: @headers, as: :json
        end
        assert_response :created
      end

      test "creating a task WITH a po_size does not enqueue the sizer" do
        assert_no_enqueued_jobs only: AviSizingJob do
          post api_v1_tasks_path,
               params: { title: "Api presizes this", po_size: "small" },
               headers: @headers, as: :json
        end
        assert_response :created
        assert_equal "small", Task.find_by!(slug: JSON.parse(response.body).dig("data", "slug")).po_size
      end

      test "the enqueued sizer sets po_size and stamps the agent=avi attribution on the creating session" do
        slug = nil
        Avi::Sizer.stub(:new, ->(*) { SizerReturning.new("medium") }) do
          perform_enqueued_jobs(only: AviSizingJob) do
            post api_v1_tasks_path,
                 params: { title: "End to end sizing", devops: { session_id: "sess-int-9" } },
                 headers: @headers, as: :json
            slug = JSON.parse(response.body).dig("data", "slug")
          end
        end

        task = Task.find_by!(slug: slug)
        assert_equal "medium", task.po_size
        assert AgentActivity.exists?(session_id: "sess-int-9", agent: "avi", task_slug: slug),
               "sizing must surface in the creator's heartbeat as an agent=avi event"
      end
    end
  end
end
