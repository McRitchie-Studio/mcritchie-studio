require "test_helper"
require_relative "../../../support/devops_key_spread"

module Api
  module V1
    class TasksControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper
      include DevopsKeySpread

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

      # [integration] THE CONTRACT ACROSS THE SEAM, and it needs its own test because
      # both sides pass without it: the model computes these two facts (task_build_
      # claim_invariant_test) and bin/task reads them off stubbed JSON (task_cli_test),
      # and neither notices if the server never SENDS them under these names.
      #
      # A miss here would fail SILENTLY and in the worst direction. bin/task treats a
      # missing holder-scoped key as "an older board" and falls back to the task-wide
      # twin — deliberately, so a schema gap can never reap a live holder. But that
      # same fallback means a renamed key, a trimmed serializer, or a typo restores
      # the exact task-wide reads this task exists to remove, with the whole suite
      # green. So the spelling is asserted here, on the wire, together with the
      # semantics that make it worth sending.
      test "show publishes the holder-scoped liveness facts the lease decision reads" do
        now = Time.current
        task = tasks(:in_progress_task)
        # UUID-shaped on purpose: Task#disowned? reads an actor matching
        # Task::SOUL_SLUG as an unknown owner, so a soul-shaped stand-in like
        # "sess-challenger" would take that branch and stop testing this one.
        holder = "s1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
        challenger = "s3f2a4c5-6d7e-4f80-9b12-c3d4e5f6a7b8"
        task.update!(metadata: { "devops" => ClaimLease.renewed(session: holder, nonce: "inst-A", now: now) })
        TaskEvent.where(task_slug: task.slug).delete_all
        GateRun.where(subject_slug: task.slug).delete_all
        # The holder's last sign of life is older than the idle window.
        TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::CHECKPOINT,
                          occurred_at: now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes),
                          from_stage: "building", to_stage: "cert",
                          metadata: { "status" => "passed", "session" => holder })
        # A queued CHALLENGER certifies the held slug: a checkpoint and an open gate.
        TaskEvent.create!(task_slug: task.slug, kind: TaskEvent::CHECKPOINT, occurred_at: now - 2.minutes,
                          from_stage: "building", to_stage: "cert",
                          metadata: { "status" => "started", "session" => challenger })
        GateRun.create!(subject_type: "task", subject_slug: task.slug, key: "g1_cert", attempt: 1,
                        started_at: now - 2.minutes, finished_at: nil,
                        metadata: { "session" => challenger })

        get api_v1_task_path(task.slug), headers: @headers

        assert_response :success
        body = response.parsed_body["data"]

        assert_equal true, body["gate_in_flight"], "task-wide, a gate really is running"
        assert_operator body["progress_seconds_ago"], :<, 300, "task-wide, progress really is recent"

        assert_equal false, body["holder_gate_in_flight"],
                     "the running gate is the challenger's — sending true here renews an abandoned lease"
        assert_operator body["holder_liveness_seconds_ago"], :>, ClaimLease::DESK_IDLE_SECONDS,
                        "the holder's own last artifact is older than the idle window"
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

      # === A PARTIAL devops PATCH must not delete the rest (api-devops-patch-replaces) ===
      #
      # THE INCIDENT, 2026-08-30. A `PATCH /api/v1/tasks/<slug>` carrying one key
      # ({"devops": {"included_in_release": false}}) took
      # /tasks/mainnet-launch-doc-vault-rename from 20 devops keys to 8. HTTP 200,
      # no warning. Seven of the lost keys — acceptance, agent_context, checks_run,
      # risk_tags, app_color, session_id, session_provider — could not be
      # recovered: the board keeps no task-version history, and the free-text
      # fields exist nowhere else. The task was already `reviewed`, so the lost
      # acceptance criteria were the contract the review had been conducted
      # against.
      #
      # WHY THE FORM PATH'S TESTS DID NOT COVER THIS. The identical bug was found
      # and fixed for the BOARD FORM (see test/controllers/tasks_controller_test.rb,
      # "a board UI edit leaves the devops keys its form omits intact"). The API
      # path was never touched, so two controllers accepting the same field
      # behaved OPPOSITELY — and the API is the one every agent and every bin/
      # script writes through.
      #
      # These assert the PROPERTY over Task::DEVOPS_KEYS, deliberately mirroring
      # the form-path test. Naming today's keys would keep passing while the NEXT
      # key added to the model was still destroyed.

      test "[integration] a partial devops PATCH leaves the devops keys it omits intact" do
        @task.update!(metadata: { "devops" => devops_key_spread, "unrelated" => "kept" })
        # Baseline = what the MODEL actually kept, not what the spread offered. A
        # `designed` task legitimately carries no ClaimLease::CLAIM_KEYS (they live
        # only on `building`), so asserting over the spread would fail on that
        # invariant rather than on the behavior under test.
        stored = @task.reload.devops
        posted = %w[kind]
        unposted = (Task::DEVOPS_KEYS & stored.keys) - posted

        # Vacuity guards. The loop below says nothing unless there really are
        # stored keys this PATCH never mentions, and these four are the ones
        # measured lost in the incident — a fixture that stopped carrying them
        # would make this test pass while proving nothing.
        assert_not_empty unposted, "guard: stored keys must be omitted for this test to mean anything"
        assert_empty %w[agent_context acceptance checks_run risk_tags] - unposted,
                     "guard: the keys measured lost on the board must be in the covered set"

        patch api_v1_task_path(@task.slug),
              params: { devops: { kind: "feature" } }, headers: @headers, as: :json

        assert_response :success
        devops = @task.reload.devops
        assert_equal "feature", devops["kind"], "the posted key is authoritative"
        unposted.each do |key|
          assert_equal stored[key], devops[key],
                       "devops.#{key} was destroyed by an API PATCH that never mentioned it"
        end
      end

      # The blast radius was wider than metadata["devops"]. The API assigned the
      # whole `metadata` COLUMN from the posted params, so a devops PATCH replaced
      # every top-level metadata name too — `reviewers` among them. The form path
      # has always merged onto the stored column; this pins the API to the same.
      test "[integration] a partial devops PATCH leaves the rest of metadata intact" do
        @task.update!(metadata: { "devops" => { "kind" => "bug" }, "unrelated" => "kept" })

        patch api_v1_task_path(@task.slug),
              params: { devops: { branch: "feat/api-devops-patch-replaces" } },
              headers: @headers, as: :json

        assert_response :success
        assert_equal "kept", @task.reload.metadata["unrelated"],
                     "a devops PATCH must not touch the rest of the metadata column"
        # Guards, both halves: the post must actually LAND, and the stored key
        # must SURVIVE. Asserting only the survivor would pass on a controller
        # that dropped the payload entirely.
        assert_equal "feat/api-devops-patch-replaces", @task.devops["branch"],
                     "guard: the posted key must land"
        assert_equal "bug", @task.devops_kind, "guard: the stored key must survive"
      end

      # The OTHER half of the contract, and the reason the merge keys on the POSTED
      # NAMES rather than on the normalized hash. Deleting a key stays expressible —
      # it just has to be said out loud (post it blank) instead of happening by
      # omission. Without this, the fix would trade silent deletion for no deletion.
      test "[integration] a devops PATCH that carries a key blank still clears it" do
        @task.update!(metadata: { "devops" => { "branch" => "feat/old", "agent_context" => "why this exists" } })

        patch api_v1_task_path(@task.slug),
              params: { devops: { branch: "" } }, headers: @headers, as: :json

        assert_response :success
        devops = @task.reload.devops
        assert_not devops.key?("branch"), "a key posted blank must still clear"
        assert_equal "why this exists", devops["agent_context"],
                     "clearing one key must not clear an unposted one"
      end

      # bin/task's ONE deletion idiom, pinned. `--pr-url-for <repo>=none` removes a
      # repo entry; when it removes the last one, bin/task sends `pr_urls: {}` and
      # relies on the key DISAPPEARING (see its merge_devops_map comment, which
      # credited "the server's wholesale devops replace"). Keying the merge on the
      # posted names preserves that: `pr_urls` is posted, so it is dropped from the
      # stored hash, and normalize drops the empty map rather than re-adding it.
      test "[integration] emptying the pr_urls map still removes the key" do
        @task.update!(metadata: { "devops" => {
                        "pr_urls" => { "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/305" },
                        "agent_context" => "why this exists"
                      } })

        patch api_v1_task_path(@task.slug),
              params: { devops: { pr_urls: {} } }, headers: @headers, as: :json

        assert_response :success
        devops = @task.reload.devops
        assert_not devops.key?("pr_urls"), "the last entry removed must unfile the key entirely"
        assert_equal "why this exists", devops["agent_context"],
                     "unfiling the map must not delete an unposted key"
      end

      # --- the builder stamp rides the real API path (builder-stamp-misses-reviewer-guard) ---
      #
      # The route used to be hostile to it: this endpoint replaced metadata["devops"]
      # wholesale, so anything not in the payload was dropped. The stamp is
      # therefore a before_save invariant, and these drive the exact request
      # `bin/task move <slug> building --actor <soul>` sends — the one that
      # silently no-op'd at exit 0 and sent two tasks to review with no builder on
      # record.
      #
      # THE REPLACE IS GONE (api-devops-patch-replaces): the endpoint now merges,
      # so an omitted key survives on its own. The before_save invariant STAYS —
      # it is what defends built_by against a caller that posts the name blank,
      # which the merge honors as a deliberate clear. Note the shape of the old
      # bug: built_by, checks_run, app_color and the mascot keys each earned their
      # own server-side defense against the same wound, one key at a time. The
      # merge is what stops the next key needing one.

      test "[integration] a re-claim PATCH on an already-building task stamps built_by" do
        @task.update!(stage: "building")
        assert_nil @task.reload.devops_built_by, "guards the setup: no builder yet"

        patch api_v1_task_path(@task.slug),
              params: {
                stage: "building", # NOT a stage change — this is the no-op case
                event: { source: "cli", actor: "carl" },
                devops: { claimed_session: "sess-x", claim_nonce: "inst-x",
                          claim_expires_at: 10.minutes.from_now.iso8601 }
              },
              headers: @headers, as: :json

        assert_response :success
        assert_equal "carl", @task.reload.devops_built_by,
          "the re-claim stamps the builder even with no stage transition"
      end

      test "[integration] a later partial devops PATCH cannot drop built_by" do
        @task.update!(stage: "building")
        patch api_v1_task_path(@task.slug),
              params: { stage: "building", event: { source: "cli", actor: "carl" },
                        devops: { claimed_session: "sess-x", claim_nonce: "inst-x",
                                  claim_expires_at: 10.minutes.from_now.iso8601 } },
              headers: @headers, as: :json
        assert_equal "carl", @task.reload.devops_built_by

        # A partial client PATCH that never mentions built_by — the shape that used
        # to wipe any devops key not defended by a before_save.
        patch api_v1_task_path(@task.slug),
              params: { devops: { kind: "bug" } }, headers: @headers, as: :json

        assert_response :success
        assert_equal "carl", @task.reload.devops_built_by,
          "the builder survives a partial PATCH that never mentions it"
      end

      # --- Column-backed names are not devops metadata (release-slug-two-universes) ---
      #
      # The bug this closes: `release_slug` was BOTH a column and a devops key, and
      # a write to the key returned 200 while reaching nothing the release lane
      # reads. A refusal that returns 200 is the defect, so these assert the STATUS
      # as hard as the storage — a silent success is the failure mode.

      test "[integration] a devops release_slug write is refused, not silently dropped" do
        @task.update!(release_slug: "rel-2026-08-12-real")

        patch api_v1_task_path(@task.slug),
              params: { devops: { kind: "bug", release_slug: "rel-typed-by-hand" } },
              headers: @headers, as: :json

        assert_response :unprocessable_entity, "a write to a column-backed name must fail loudly"
        body = response.parsed_body
        assert_match(/devops\.release_slug is not writable/, body["error"].to_s)
        assert_match(/tasks\.release_slug column/, body["error"].to_s,
                     "the error must tell the caller where the field actually lives")

        @task.reload
        assert_equal "rel-2026-08-12-real", @task.release_slug, "the column is untouched by a refused write"
        assert_not @task.devops.key?("release_slug")
      end

      # --- devops.pr_urls: the per-repo PR register ---------------------------
      # The JSON API is the door bin/task writes through, so the map's round trip
      # and its refusals are pinned HERE as well as at the model. A refusal that
      # returns 200 is the defect this register exists to close: the coverage it
      # will be gated on must not be satisfiable by a string nobody validated.

      test "[integration] a devops pr_urls map round-trips through the API" do
        turf = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

        patch api_v1_task_path(@task.slug),
              params: { devops: { kind: "bug", pr_urls: { "turf-monster" => turf } } },
              headers: @headers, as: :json

        assert_response :success
        assert_equal({ "turf-monster" => turf }, @task.reload.devops["pr_urls"])
        assert_equal({ "turf-monster" => turf }, @task.release_pr_urls)
      end

      test "[integration] a pr_urls value that is not a PR url is refused, not stored" do
        patch api_v1_task_path(@task.slug),
              params: { devops: { kind: "bug", pr_urls: { "turf-monster" => "lol" } } },
              headers: @headers, as: :json

        assert_response :unprocessable_entity, "a nonsense url must fail loudly, not read as coverage"
        assert_match(/names no repo/, response.parsed_body["error"].to_s)
        assert_nil @task.reload.devops["pr_urls"]
      end

      test "[integration] a pr_urls url filed under the wrong repo is refused" do
        patch api_v1_task_path(@task.slug),
              params: { devops: {
                kind: "bug",
                pr_urls: { "mcritchie-studio" => "https://github.com/McRitchie-Studio/turf-monster/pull/305" }
              } },
              headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_match(/wrong repo/, response.parsed_body["error"].to_s)
        assert_match(/turf-monster/, response.parsed_body["error"].to_s)
      end

      # Blanking a value is the API-level UNSET — every writer sends the whole
      # map, so this is how a wrong entry comes off the record.
      test "[integration] a blank pr_urls value unsets that entry" do
        hub = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836"
        @task.update!(metadata: { "devops" => { "pr_urls" => {
          "mcritchie-studio" => hub,
          "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/305"
        } } })

        patch api_v1_task_path(@task.slug),
              params: { devops: { pr_urls: { "mcritchie-studio" => hub, "turf-monster" => "" } } },
              headers: @headers, as: :json

        assert_response :success
        assert_equal({ "mcritchie-studio" => hub }, @task.reload.devops["pr_urls"])
      end

      test "[integration] a devops block_kind write is refused and names the block endpoint" do
        patch api_v1_task_path(@task.slug),
              params: { devops: { block_kind: "environment" } },
              headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_match(/tasks\.block_kind column/, response.parsed_body["error"].to_s)
        assert_nil @task.reload.block_kind, "the column stays server-stamped via the block endpoint"
      end

      # `metadata: {}` is permitted wholesale and only overridden when `devops:` is
      # present, so this payload never reaches the normalizer. The model's
      # before_save shed is what keeps the invariant total across BOTH doors.
      test "[integration] a raw metadata devops write cannot plant a release_slug shadow" do
        @task.update!(release_slug: "rel-2026-08-12-real")

        patch api_v1_task_path(@task.slug),
              params: { metadata: { devops: { kind: "bug", release_slug: "rel-typed-by-hand" } } },
              headers: @headers, as: :json

        assert_response :success
        @task.reload
        assert_not @task.devops.key?("release_slug"),
                   "the raw metadata door must not reintroduce the shadow store"
        assert_equal "rel-2026-08-12-real", @task.release_slug
      end

      # The read side agrees: the API serves the COLUMN at top level, which is what
      # bin/conductor and `bin/task field` consume.
      test "[integration] the api serves release_slug as a top-level column" do
        @task.update!(release_slug: "rel-2026-08-12-real")

        get api_v1_task_path(@task.slug), headers: @headers

        assert_response :success
        body = response.parsed_body["data"]
        assert_equal "rel-2026-08-12-real", body["release_slug"]
        assert_nil body.dig("metadata", "devops", "release_slug")
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

      # --- Operator approval (2026-08-09): the bearer API records the grant. The
      # operator approves in words on a live preview and the agent that heard him
      # writes it down, so the board stops pulsing WAITING on a question he already
      # answered. `bin/task update <task> --approval approved` is exactly this
      # PATCH — the end-to-end path the removal had to reopen. ---

      test "[integration] api update can record operator approval" do
        task = Task.create!(
          title: "Approval Api Grant",
          stage: "building", # a waiting request only lives pre-seam (the settle invariant)
          metadata: { "devops" => { "approval_status" => "waiting" } }
        )

        patch api_v1_task_path(task.slug),
              params: { devops: { approval_status: "approved" } },
              headers: @headers,
              as: :json

        assert_response :success
        task.reload
        assert_equal "approved", task.approval_status
        assert task.devops["approval_approved_at"].present?,
               "the server-side approval stamp must still land on a bearer grant"
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

      # The source clamp OUTLIVED the approval guard it was built beside. It is now
      # purely about attribution: the source rides onto the TaskEvent spine, so a
      # bearer PATCH claiming event.source="web" would file agent activity under the
      # operator's name. The clamp normalizes it back to "api". Asserted on a stage
      # move, since that is the write that records a transition event.
      test "[integration] api bearer cannot forge an operator source onto its events" do
        task = Task.create!(title: "Approval Source Forge", stage: "designed")

        patch api_v1_task_path(task.slug),
              params: { event: { source: "web" }, stage: "building" },
              headers: @headers,
              as: :json

        assert_response :success
        assert_equal "building", task.reload.stage
        event = task.task_events.order(:occurred_at).last
        assert_equal "api", event.source, "a forged operator source must clamp back to the agent lane"
      end

      # The clamp rewrites only the source label — a forged source must not otherwise
      # change the outcome of the write.
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

      # THE SELF-FLAG PATH. exclusive-lanes.md (and Carl's + Avi's soul docs) tell a
      # backend Dev to set requires_migration the moment they discover they need a
      # schema change. Until this permit existed the column was writable ONLY through
      # the admin-gated /sizing editor, so every one of those instructions named a
      # behaviour no agent could perform. `bin/task update <slug> --requires-migration`
      # rides this line.
      test "[integration] update permits requires_migration so an agent can self-flag" do
        patch api_v1_task_path(@task.slug), params: { requires_migration: true }, headers: @headers, as: :json

        assert_response :success
        assert @task.reload.requires_migration, "an agent must be able to flag its own task for the lane"
      end

      # Un-flagging matters too: a task that turns out NOT to need a migration hands
      # the lane back and says so. `false` is a VALUE, not an absent parameter.
      test "[integration] update permits clearing requires_migration" do
        @task.update!(requires_migration: true)

        patch api_v1_task_path(@task.slug), params: { requires_migration: false }, headers: @headers, as: :json

        assert_response :success
        refute @task.reload.requires_migration
      end

      test "[integration] create permits requires_migration for a pre-flagged task" do
        post api_v1_tasks_path,
             params: { title: "Pre flagged migration task", requires_migration: true,
                       devops: { shape: "backend" } },
             headers: @headers, as: :json

        assert_response :success
        slug = response.parsed_body.dig("data", "slug")
        assert Task.find_by!(slug: slug).requires_migration, "Avi can pre-flag the lane at refinement"
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

      # The regression this file owns: task_params assigns metadata WHOLESALE as
      # {"devops" => <whitelisted client keys>}, so a PATCH that never mentions the
      # mascot still rewrites its hash. mascot_shiny/color/emoji are server-owned
      # (absent from DEVOPS_KEYS) and used to vanish on the first such write — the
      # `bin/task begin` bind — leaving every later stage-event snapshot to bake the
      # NON-shiny sprite. This walks the real fast-lane order: create, bind, claim.
      test "a devops PATCH cannot wipe the server-owned mascot stamps" do
        Pokemon.create!(dex: 302, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1,
                        avatar_url: "normal-crop.png", sprite_url: "normal-sprite.png",
                        shiny_avatar_url: "shiny-crop.png", shiny_sprite_url: "shiny-sprite.png")
        Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-shiny-patch") }

        post api_v1_tasks_path,
             params: { title: "Keeps its shiny stamps", devops: { session_id: "sess-shiny-patch" } },
             headers: @headers, as: :json
        assert_response :created
        slug = JSON.parse(response.body).dig("data", "slug")
        assert_predicate Task.find_by!(slug: slug), :mascot_shiny?

        # The bind PATCH — worktree_slug only, exactly what bin/agent-worktree sends.
        patch api_v1_task_path(slug), params: { devops: { worktree_slug: slug } },
              headers: @headers, as: :json
        assert_response :success
        task = Task.find_by!(slug: slug)
        assert_predicate task, :mascot_shiny?, "the bind PATCH must not wipe the shiny stamp"
        assert_equal "snorlax", task.devops["mascot"], "…nor the mascot handle it never mentioned"
        assert_equal slug, task.devops["worktree_slug"]

        # …and the snapshot the NEXT stage move bakes still wears the shiny face,
        # which is what the board card's later crew slots render.
        patch api_v1_task_path(slug), params: { stage: "building" }, headers: @headers, as: :json
        assert_response :success
        snapshot = Task.find_by!(slug: slug).task_events.find_by(to_stage: "building").mascot_snapshot
        assert_equal "shiny-crop.png", snapshot["avatar"]
        assert snapshot["shiny"]
      end
    end
  end
end
