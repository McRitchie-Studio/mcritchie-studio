require "test_helper"

class TaskTest < ActiveSupport::TestCase
  # --- Workflow 1: Build transitions ---

  test "designed task can start building" do
    task = tasks(:new_task)
    task.build!
    assert_equal "building", task.stage
    assert_not_nil task.started_at
  end

  test "building task can be submitted" do
    task = tasks(:in_progress_task)
    task.submit!
    assert_equal "submitted", task.stage
    assert_not_nil task.submitted_at
  end

  test "[unit] submitting from building settles waiting approval to none" do
    task = Task.create!(
      title: "Approval Exit Build",
      stage: "building",
      metadata: {
        "devops" => {
          "approval_status" => "waiting",
          "local_url" => "http://localhost:3021/tasks"
        }
      }
    )
    requested_at = task.devops["approval_requested_at"]

    task.submit!

    task.reload
    assert_equal "submitted", task.stage
    # The review flow takes over on submit, so the WAITING APPROVAL badge drops —
    # settled to "none", NOT self-approved (no fabricated operator grant).
    assert_equal "none", task.approval_status
    assert_not task.waiting_for_operator_approval?
    # The original request timestamp is preserved as history; no approval was granted.
    assert_equal requested_at, task.devops["approval_requested_at"]
    assert_nil task.devops["approval_approved_at"]
  end

  test "[unit] submitting straight from designed also settles waiting approval" do
    # The old build-exit callback only fired when LEAVING `building`; a
    # designed→submitted jump stranded the WAITING APPROVAL badge on the submitted
    # card. Keying off the transition INTO submitted covers that path too.
    task = Task.create!(
      title: "Approval Skip Building",
      stage: "designed",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    task.submit!

    task.reload
    assert_equal "submitted", task.stage
    assert_equal "none", task.approval_status
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] submitting leaves requested changes untouched" do
    task = Task.create!(
      title: "Approval Exit Blocked",
      stage: "building",
      metadata: {
        "devops" => {
          "approval_status" => "changes_requested",
          "local_url" => "http://localhost:3021/tasks"
        }
      }
    )
    task.block!(by: "avi", kind: "rework") # a block is a building attribute now

    task.submit!

    task.reload
    assert_equal "submitted", task.stage
    # Only the "waiting" request settles on submit; changes_requested carries its
    # own meaning into review and must survive the transition untouched.
    assert_equal "changes_requested", task.approval_status
    assert_nil task.devops["approval_approved_at"]
  end

  test "[unit] submitting leaves an already-approved grant untouched" do
    task = Task.create!(
      title: "Approval Already Granted",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "approved", "approval_approved_at" => "2026-07-01T00:00:00Z" } }
    )

    task.submit!

    task.reload
    assert_equal "approved", task.approval_status, "a real operator grant survives submit"
    assert_equal "2026-07-01T00:00:00Z", task.devops["approval_approved_at"]
  end

  test "[unit] settling waiting on submit is idempotent across a block/resubmit cycle" do
    task = Task.create!(
      title: "Approval Resettle On Resubmit",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    task.submit!
    assert_equal "none", task.reload.approval_status

    # QA rework sends it back to building; the demo is re-flagged waiting, then resubmitted.
    task.block!(by: "avi", kind: "rework")
    md = task.metadata.deep_dup
    md["devops"]["approval_status"] = "waiting"
    task.update!(metadata: md)
    task.submit!

    assert_equal "none", task.reload.approval_status, "re-entering submitted settles again, no-op-safe"
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] an agent-sourced submit settles waiting without tripping the operator guard" do
    task = Task.create!(
      title: "Approval Agent Submit",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    Current.task_event_source = "cli" # the bin/task agent lane, normally barred from granting approval
    assert_nothing_raised { task.submit! }

    task.reload
    assert_equal "none", task.approval_status, "the system settle resolves to the agent-writable none"
    assert_nil task.devops["approval_approved_at"], "no operator grant is fabricated"
  ensure
    Current.reset
  end

  test "[unit] creating straight into submitted settles the request too" do
    # The settle is a stage INVARIANT, not a transition event, so it holds on
    # create as well: a row born past the seam cannot carry a badge that nothing
    # in the pipeline will clear.
    task = Task.create!(
      title: "Approval Born Submitted",
      stage: "submitted",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    assert_equal "none", task.reload.approval_status
    assert_not task.waiting_for_operator_approval?
  end

  # --- the three leaks the OLD one-shot transition callback had. Each was
  # reproduced against the shipped code on 2026-07-27; the operator's report was
  # a SHIPPED card still flashing WAITING APPROVAL. ---

  test "[unit] a later wholesale devops echo cannot restore a settled request" do
    # Leak 1, and the one that actually bit: `bin/task update --checks` PATCHes
    # the WHOLE devops hash, and a hash read before the move still says "waiting".
    # The stage does not change on that write, so a transition callback never
    # fired again.
    task = Task.create!(
      title: "Approval Echo Restore",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )
    task.submit!
    assert_equal "none", task.reload.approval_status

    task.update!(metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } })

    assert_equal "none", task.reload.approval_status,
      "a stale devops echo must not resurrect a request the seam already settled"
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] flagging approval AFTER submitting settles immediately" do
    # Leak 2: there was no move left to settle it, so it stuck forever.
    task = Task.create!(title: "Approval Late Flag", stage: "building")
    task.submit!

    metadata = task.metadata.deep_dup
    (metadata["devops"] ||= {})["approval_status"] = "waiting"
    task.update!(metadata: metadata)

    assert_equal "none", task.reload.approval_status
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] a waiting request cannot ride a later stage move to shipped" do
    # Leak 3: reviewed / assembled / shipped were not the submitted transition,
    # so a restored request rode the whole pipeline. Force one in past the seam
    # (update_column skips the invariant) and assert every later stage clears it.
    task = Task.create!(title: "Approval Rides Pipeline", stage: "building")
    task.submit!

    %w[reviewed assembled shipped archived].each do |stage|
      forced = task.metadata.deep_dup
      (forced["devops"] ||= {})["approval_status"] = "waiting"
      task.update_column(:metadata, forced)

      task.update!(stage: stage)

      assert_equal "none", task.reload.approval_status,
        "moving to #{stage} must settle a stale waiting request, not carry it"
    end
  end

  test "[unit] the backfill sweep settles the rows the old one-shot settle stranded" do
    # 9 such rows were live in production when this was found — one of them a
    # SHIPPED card still flashing WAITING APPROVAL. The invariant fixes the
    # future; nothing saves these rows again, so they need the sweep.
    stranded = %w[submitted reviewed assembled shipped archived].map do |stage|
      task = Task.create!(title: "Stranded #{stage.capitalize} Badge", stage: stage)
      forced = task.metadata.deep_dup
      (forced["devops"] ||= {})["approval_status"] = "waiting"
      task.update_column(:metadata, forced)
      task
    end
    live = Task.create!(
      title: "Live Waiting Request",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting" } }
    )

    settled = Task.settle_stale_operator_approvals!

    assert_equal stranded.map(&:slug).sort, settled.sort
    stranded.each { |task| assert_equal "none", task.reload.approval_status }
    assert_equal "waiting", live.reload.approval_status,
      "a request in a stage that can still act on it must survive the sweep"

    assert_empty Task.settle_stale_operator_approvals!, "re-running the sweep is a no-op"
  end

  test "[unit] the backfill sweep leaves a granted approval alone" do
    task = Task.create!(title: "Shipped With Grant", stage: "shipped")
    forced = task.metadata.deep_dup
    (forced["devops"] ||= {})["approval_status"] = "approved"
    task.update_column(:metadata, forced)

    Task.settle_stale_operator_approvals!

    assert_equal "approved", task.reload.approval_status,
      "the sweep clears stale REQUESTS, never a real operator grant"
  end

  test "[unit] a blocked task still shows its waiting request" do
    # The counter-property: a block parks the task on `building`, where the
    # operator CAN still act on the demo — so a rework re-request must survive.
    task = Task.create!(
      title: "Approval Blocked Survives",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    task.block!(by: "avi", kind: "rework")

    assert_equal "waiting", task.reload.approval_status
    assert task.waiting_for_operator_approval?
  end

  # --- the WAITING APPROVAL badge must pop live over websockets ----------------
  # An agent requests approval by flipping devops.approval_status to "waiting".
  # That changes no stage column and writes no TaskEvent — the spine the live
  # /deployments board listens on — so the badge used to appear only on a full
  # reload. An after_update_commit refreshes the card in place off the DERIVED
  # approval_status change instead (mirrors the event-less gate-run broadcast).

  test "[unit] flipping approval_status to waiting refreshes the board card live" do
    task = Task.create!(
      title: "Approval Pop Waiting",
      stage: "building",
      metadata: { "devops" => { "local_url" => "http://localhost:3021/tasks" } }
    )

    calls = []
    DeploymentsBroadcaster.stub(:approval_change, ->(t) { calls << t.slug }) do
      md = task.metadata.deep_dup
      md["devops"]["approval_status"] = "waiting"
      task.update!(metadata: md)
    end

    assert_equal [task.slug], calls, "the waiting flip must refresh the card so the badge pops without a reload"
  end

  test "[unit] resolving a waiting approval also refreshes the card live" do
    task = Task.create!(
      title: "Approval Pop Clear",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    calls = []
    DeploymentsBroadcaster.stub(:approval_change, ->(t) { calls << t.slug }) do
      md = task.metadata.deep_dup
      md["devops"]["approval_status"] = "changes_requested"
      task.update!(metadata: md)
    end

    assert_equal [task.slug], calls, "clearing the request must also refresh the card so the amber bar drops"
  end

  test "[unit] a metadata write that leaves approval_status unchanged does not re-broadcast" do
    # The board must not be spammed on every `bin/task update --checks` — a
    # wholesale devops rewrite that echoes the same approval_status is not a change.
    task = Task.create!(
      title: "Approval Pop No Spam",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    calls = []
    DeploymentsBroadcaster.stub(:approval_change, ->(t) { calls << t.slug }) do
      md = task.metadata.deep_dup
      md["devops"]["checks_run"] = ["[unit] unrelated check"]
      task.update!(metadata: md)
    end

    assert_empty calls, "an unrelated metadata write must not broadcast an approval refresh"
  end

  test "[unit] blocking a building task keeps approval open" do
    task = Task.create!(
      title: "Approval Still Blocked",
      stage: "building",
      metadata: {
        "devops" => {
          "approval_status" => "waiting",
          "local_url" => "http://localhost:3021/tasks"
        }
      }
    )

    task.block!(by: "steffon", kind: "environment")

    task.reload
    assert_equal "building", task.stage, "a block is a building attribute, not a stage"
    assert task.blocked?
    assert_equal "waiting", task.approval_status
    assert task.waiting_for_operator_approval?
    assert_nil task.devops["approval_approved_at"]
  end

  # --- Operator approval (2026-08-09): approval_status is writable from EVERY
  # lane. The operator approves in words on a live preview; the agent that heard
  # him records it with `bin/task update --approval approved`. The old guard that
  # made "approved" operator-attributed-writes-only is gone: its practical effect
  # was a board pulsing WAITING until the operator clicked a button he had already
  # answered — a chore handed back to him. The source lane survives only as
  # TaskEvent attribution (OPERATOR_APPROVAL_GRANT_SOURCES + the bearer clamp). ---

  test "[unit] agent api write can flip approval to approved" do
    %w[api cli].each do |source|
      task = Task.create!(
        title: "Approval Agent Flip",
        stage: "building", # a waiting request only lives pre-seam (the settle invariant)
        metadata: {
          "devops" => {
            "approval_status" => "waiting",
            "local_url" => "http://localhost:3021/tasks"
          }
        }
      )

      Current.task_event_source = source
      task.update!(metadata: { "devops" => task.devops.merge("approval_status" => "approved") })

      task.reload
      assert_equal "approved", task.approval_status, "source #{source} must record the grant"
      assert task.devops["approval_approved_at"].present?,
             "source #{source} must still get the server-side approval stamp"
    end
  ensure
    Current.reset
  end

  test "[unit] agent write can stamp approval_approved_at directly" do
    task = Task.create!(
      title: "Approval Agent Stamp",
      stage: "building", # a waiting request only lives pre-seam (the settle invariant)
      metadata: { "devops" => { "approval_status" => "waiting" } }
    )
    stamped = 2.hours.ago.iso8601

    Current.task_event_source = "api"
    task.update!(metadata: { "devops" => task.devops.merge("approval_approved_at" => stamped) })

    assert_equal stamped, task.reload.devops["approval_approved_at"]
  ensure
    Current.reset
  end

  test "[unit] operator web session can flip approval to approved" do
    task = Task.create!(
      title: "Approval Operator Flip",
      stage: "building", # a waiting request only lives pre-seam (the settle invariant)
      metadata: {
        "devops" => {
          "approval_status" => "waiting",
          "local_url" => "http://localhost:3021/tasks"
        }
      }
    )

    Current.task_event_source = "web"
    task.update!(metadata: { "devops" => task.devops.merge("approval_status" => "approved") })

    task.reload
    assert_equal "approved", task.approval_status
    assert task.devops["approval_approved_at"].present?
  ensure
    Current.reset
  end

  test "[unit] internal write without request source can approve" do
    task = Task.create!(
      title: "Approval Console Flip",
      stage: "building", # a waiting request only lives pre-seam (the settle invariant)
      metadata: { "devops" => { "approval_status" => "waiting" } }
    )

    task.update!(metadata: { "devops" => task.devops.merge("approval_status" => "approved") })

    assert_equal "approved", task.reload.approval_status
  end

  test "[unit] agent api write keeps non-approved statuses writable" do
    task = Task.create!(
      title: "Approval Agent Statuses",
      stage: "building",
      metadata: { "devops" => { "local_url" => "http://localhost:3021/tasks" } }
    )

    Current.task_event_source = "api"
    %w[waiting changes_requested none].each do |status|
      task.update!(metadata: { "devops" => task.devops.merge("approval_status" => status) })
      assert_equal status, task.reload.approval_status, "agents must keep #{status} writable"
    end
  ensure
    Current.reset
  end

  test "[unit] agent api echo of already-approved metadata stays valid" do
    task = Task.create!(
      title: "Approval Echo Update",
      stage: "submitted",
      metadata: { "devops" => { "approval_status" => "approved" } }
    )

    # bin/task update REPLACES the whole devops hash, echoing the operator's
    # earlier approval back — the echo must not clobber the recorded grant.
    Current.task_event_source = "cli"
    task.update!(metadata: { "devops" => task.devops.merge("pr_url" => "https://github.com/x/y/pull/1") })

    task.reload
    assert_equal "approved", task.approval_status
    assert_equal "https://github.com/x/y/pull/1", task.devops["pr_url"]
  ensure
    Current.reset
  end

  test "[unit] agent echo of existing approval_approved_at stays valid" do
    stamped = Time.current.iso8601
    task = Task.create!(
      title: "Approval Timestamp Echo",
      stage: "submitted",
      metadata: { "devops" => { "approval_status" => "approved", "approval_approved_at" => stamped } }
    )

    Current.task_event_source = "cli"
    task.update!(metadata: { "devops" => task.devops.merge("qa_url" => "https://qa.example.com/x") })

    task.reload
    assert_equal stamped, task.devops["approval_approved_at"]
    assert_equal "https://qa.example.com/x", task.devops["qa_url"]
  ensure
    Current.reset
  end

  test "submitted task can be reviewed" do
    task = tasks(:new_task)
    task.update!(stage: "submitted")
    task.review!
    assert_equal "reviewed", task.stage
    assert_not_nil task.reviewed_at
  end

  # --- builder identity: who built this (devops.built_by) ---

  test "moving to building stamps the build-claim actor onto devops.built_by" do
    Current.task_event_actor = "carl"
    task = tasks(:new_task)
    task.build!

    assert_equal "carl", task.reload.devops_built_by, "the build agent is recorded for reviewer exclusion"
  ensure
    Current.reset
  end

  test "a building move with no actor and no assignee leaves built_by unset" do
    # new_task has no Current actor AND no agent_slug — neither the actor nor the
    # assigned-agent fallback can resolve a soul, so nothing is stamped and an
    # existing value is never clobbered to nil.
    task = tasks(:new_task)
    assert_nil task.agent_slug, "guards the assumption: no assignee to fall back to"
    task.build!

    assert_nil task.reload.devops_built_by
  end

  test "a rework re-claim re-points built_by to the current builder" do
    Current.task_event_actor = "shannon"
    task = tasks(:new_task)
    task.build!
    assert_equal "shannon", task.reload.devops_built_by

    # Bounced back (to submitted), then re-claimed by a different soul — built_by
    # follows on the fresh building transition.
    task.update!(stage: "submitted")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")

    assert_equal "carl", task.reload.devops_built_by, "the latest builder wins on a re-claim"
  ensure
    Current.reset
  end

  test "a soul-slug build actor is stamped and excluded from review end-to-end" do
    # The real build path passes --actor <soul>; the soul is stamped and the
    # reviewer pool then excludes it (a soul never reviews their own work).
    Current.task_event_actor = "carl"
    task = Task.create!(title: "soul builder exclusion task",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_equal "carl", task.reload.devops_built_by, "a soul slug is recorded as the builder"

    decision = ReviewerSelector.explain(task)
    assert_equal "carl", decision["builder"], "the soul builder is identified"
    assert_nil decision["standing_primary"], "Carl yields the primary seat on a PR he built"
    refute_includes decision["candidates"], "carl", "Carl is never a light candidate"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "carl", "a soul never reviews their own work"
  ensure
    Current.reset
  end

  test "a session-id build actor is not stamped and causes no false exclusion" do
    # A bare `bin/task move <slug> building` defaults the actor to the session id
    # (a UUID) — NOT a soul. It must not be stamped as built_by, and must not be
    # reported as excluded (it was never a reviewer candidate). This is the gap
    # that made the feature no-op on the CLI build path while the audit lied.
    Current.task_event_actor = "942a9824-375f-4d13-b60e-85be79ee9880"
    task = Task.create!(title: "session id builder task",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_nil task.reload.devops_built_by, "a session id is not stamped as the builder"

    decision = ReviewerSelector.explain(task)
    assert_nil decision["excluded_builder"], "no soul is falsely excluded"
    assert_equal "carl", decision["standing_primary"], "with no builder, Carl is the standing primary"
    assert_includes decision["candidates"], "shannon", "the light pool (minus QA owner) stays eligible"
    assert_includes decision["candidates"], "steffon", "steffon rejoins the light pool — avi is the QA owner now"
  ensure
    Current.reset
  end

  test "a no-actor re-move to building preserves the existing built_by" do
    # Set a builder, bounce back to submitted, then re-move to building with NO
    # actor (Current cleared) — stamp_builder must leave the prior builder
    # untouched, never clobber it to nil.
    Current.task_event_actor = "shannon"
    task = tasks(:new_task)
    task.build!
    assert_equal "shannon", task.reload.devops_built_by
    Current.reset # the re-claim below carries no actor

    task.update!(stage: "submitted")
    task.update!(stage: "building")

    assert_equal "shannon", task.reload.devops_built_by,
      "a no-actor re-claim leaves the prior builder untouched"
  ensure
    Current.reset
  end

  test "a plain build move records the assigned agent_slug as built_by (no --actor)" do
    # FIX (a): a bare `bin/task move <slug> building` defaults the event actor to
    # the session UUID (not a soul), so the actor path can't stamp. The task's
    # assigned agent_slug is the automatic, no-flag builder source — so
    # reviewer-select auto-excludes the builder WITHOUT the operator passing
    # --builder by hand every time.
    task = Task.create!(title: "assigned builder auto stamp", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build! # no Current actor — the bare-CLI build path

    assert_equal "carl", task.reload.devops_built_by,
      "the assigned agent is recorded as the builder automatically"
  end

  test "a session-id actor still falls back to the assigned agent_slug" do
    # The real bare-CLI move sets the actor to the session UUID. That's not a
    # soul, so it never stamps — but the assigned agent_slug now backstops it.
    Current.task_event_actor = "942a9824-375f-4d13-b60e-85be79ee9880"
    task = Task.create!(title: "session actor assignee stamp", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_equal "carl", task.reload.devops_built_by,
      "a non-soul actor falls back to the assigned builder rather than stamping nothing"
  ensure
    Current.reset
  end

  test "a soul build actor wins over the assigned agent_slug" do
    # An explicit --actor <soul> attribution beats the agent_slug default.
    Current.task_event_actor = "shannon"
    task = Task.create!(title: "actor beats assignee task", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    assert_equal "shannon", task.reload.devops_built_by, "the explicit actor wins"
  ensure
    Current.reset
  end

  test "the agent_slug default never clobbers an existing built_by" do
    # Once stamped, a no-actor re-claim of an assigned task keeps the recorded
    # builder — the agent_slug default only fills a BLANK built_by, it never
    # overwrites (only an explicit --actor re-points on a re-claim).
    Current.task_event_actor = "shannon"
    task = Task.create!(title: "no clobber existing builder", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!
    assert_equal "shannon", task.reload.devops_built_by
    Current.reset

    task.update!(stage: "submitted")
    task.update!(stage: "building") # no actor; agent_slug is carl

    assert_equal "shannon", task.reload.devops_built_by,
      "the agent_slug default fills only a blank built_by, never overwrites"
  ensure
    Current.reset
  end

  test "an assigned build auto-excludes the builder from review end-to-end" do
    # The whole point of FIX (a): assign carl, do a plain build (no actor/flag),
    # and the reviewer pool excludes carl with no manual --builder.
    task = Task.create!(title: "assigned end to end exclude", agent_slug: "carl",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.build!

    decision = ReviewerSelector.explain(task.reload)
    assert_equal "carl", decision["builder"], "the assigned builder is read from devops.built_by"
    assert_nil decision["standing_primary"], "Carl yields the primary seat on a PR he built"
    refute_includes decision["candidates"], "carl", "carl is never a light candidate"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "carl", "carl never reviews the PR carl built"
  end

  # --- the build claim stamps, even with no stage change (builder-stamp-misses-reviewer-guard) ---

  test "a re-claim of a task ALREADY in building stamps the build actor" do
    # THE DEFECT. The fast lane (`bin/task begin`) leaves the task at `building`,
    # so the documented recovery — `bin/task move <slug> building --actor <soul>` —
    # carried NO stage change, `set_stage_timestamp` never fired, and the stamp
    # silently no-op'd at exit 0. The stamp is an INVARIANT of the build claim, not
    # of the transition into it.
    task = tasks(:new_task)
    task.build!
    assert_nil task.reload.devops_built_by, "guards the setup: the first claim named no soul"

    Current.task_event_actor = "carl"
    task.update!(metadata: task.metadata.deep_merge("devops" => {
      "claimed_session" => "sess-reclaim", "claim_nonce" => "n1",
      "claim_expires_at" => 10.minutes.from_now.iso8601
    }))

    assert_equal "carl", task.reload.devops_built_by,
      "a re-claim while already building stamps the builder"
  ensure
    Current.reset
  end

  test "a soul persona backstops the stamp when no actor or assignee resolves" do
    # A session ACTING AS a soul (devops.persona) already paints that soul's face
    # on the card. The builder is then known, so the stamp records it rather than
    # leaving the exclusion blind. A persona only SURVIVES on the record when it
    # names a real Agent (sync_persona_identity drops a typo), so a stored persona
    # is always a real soul.
    task = Task.create!(title: "persona builder stamp",
                        metadata: { "devops" => { "shape" => "backend", "persona" => "alex" } })
    assert_equal "alex", task.devops["persona"], "guards the setup: the persona took"
    task.build!

    assert_equal "alex", task.reload.devops_built_by,
      "the persona the card already shows is recorded as the builder"
  end

  test "a non-claim save while building never stamps a builder" do
    # The guard against over-stamping: the invariant fires on the CLAIM, not on
    # every save. A note/checks write that happens to carry a soul actor (a
    # commenter, a blocker) must not be recorded as the builder.
    task = tasks(:new_task)
    task.build!
    assert_nil task.reload.devops_built_by

    Current.task_event_actor = "shannon"
    task.update!(metadata: task.metadata.deep_merge("devops" => { "checks_run" => ["[unit] noop"] }))

    assert_nil task.reload.devops_built_by,
      "a non-claim save does not make its actor the builder"
  ensure
    Current.reset
  end

  test "a block that lands on building never stamps the blocker as the builder" do
    # block! lands the task on `building` and carries the BLOCKER as the actor.
    # The blocker is not the builder — and the invariant must not undo the
    # exemption the transition path already had.
    task = tasks(:new_task)
    task.update!(stage: "submitted")
    Current.task_event_actor = "avi"
    task.block!(by: "avi", kind: "rework")

    assert_equal "building", task.reload.stage
    assert_nil task.reload.devops_built_by, "the blocker is never recorded as the builder"
  ensure
    Current.reset
  end

  # --- Workflow 2: Deploy transitions ---

  test "reviewed task can be assembled" do
    task = tasks(:new_task)
    task.update!(stage: "reviewed")
    task.assemble!
    assert_equal "assembled", task.stage
    assert_not_nil task.assembled_at
  end

  test "assembled task can be shipped with result" do
    task = tasks(:new_task)
    task.update!(stage: "assembled")
    task.ship!({ output: "done" })
    assert_equal "shipped", task.stage
    assert_not_nil task.completed_at
    assert_equal({ "output" => "done" }, task.result)
  end

  # --- blocked: a `building` attribute, no longer a stage ---

  test "a task can be blocked, capturing where it came from, who, and why" do
    task = tasks(:in_progress_task) # building
    task.block!(by: "avi", kind: "rework")
    assert task.blocked?
    assert_equal "building", task.stage, "a block lands on building, not a blocked stage"
    assert_not_nil task.blocked_at
    assert_equal "building", task.blocked_from
    assert_equal "avi", task.blocked_by
    assert_equal "rework", task.block_kind
  end

  test "blocking a submitted task lands it on building with blocked_from submitted" do
    task = tasks(:new_task)
    task.update!(stage: "submitted")
    task.block!(by: "avi", kind: "rework")
    assert_equal "building", task.stage
    assert_equal "submitted", task.blocked_from, "captures the stage it stalled in"
    assert task.blocked?
  end

  test "a blocked task resumes (unblocks) and clears its block columns" do
    task = tasks(:failed_task) # building + a live block
    assert task.blocked?, "the fixture carries a live block"
    task.unblock!
    assert_equal "building", task.stage
    assert_not task.blocked?
    assert_nil task.blocked_at
    assert_nil task.blocked_by
    assert_nil task.block_kind
  end

  test "block! still posts the qa_feedback marker via its caller (retro regression)" do
    # The GOTCHA: with no →blocked transition, retros/insights must still SEE the
    # block. The durable marker is blocked_at (the column) + the qa_feedback
    # Activity a caller posts alongside — proven here so a future refactor can't
    # silently zero out the block signal.
    task = tasks(:in_progress_task)
    task.block!(by: "avi", kind: "rework")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "please fix")
    assert task.blocked_at.present?, "blocked_at is the durable column marker"
    assert task.ever_blocked?, "the qa_feedback Activity marker survives"
    assert_equal 1, Release::Retro.rework_rounds(task), "retro counts the block off the marker"
  end

  # --- terminal ---

  test "a shipped task can be archived" do
    task = tasks(:done_task)
    task.archive!
    assert_equal "archived", task.stage
    assert_not_nil task.archived_at
  end

  # --- Free movement (no transition restrictions) ---

  test "task can move freely across the two workflows" do
    task = tasks(:new_task)
    %w[building submitted reviewed assembled shipped].each do |stage|
      task.update!(stage: stage)
      assert_equal stage, task.stage
    end
  end

  test "all task stages are valid" do
    Task::STAGES.each do |stage|
      task = Task.new(title: "Task in #{stage}", stage: stage)
      assert task.valid?, "#{stage} should be valid"
    end
  end

  test "stage labels expose two-workflow names" do
    assert_equal "Designed", Task::STAGE_LABELS.fetch("designed")
    assert_equal "Submitted", Task::STAGE_LABELS.fetch("submitted")
    assert_equal "Reviewed", Task::STAGE_LABELS.fetch("reviewed")
    assert_equal "Assembled", Task::STAGE_LABELS.fetch("assembled")
    assert_equal "Shipped", Task::STAGE_LABELS.fetch("shipped")
    assert_not Task::STAGE_LABELS.key?("blocked"), "blocked is no longer a stage"
  end

  test "active_stage_label gives the gerund form for a stage still underway" do
    assert_equal "Assembling", Task.active_stage_label("assembled")
    assert_equal "Reviewing", Task.active_stage_label("reviewed")
    assert_equal "Shipping", Task.active_stage_label("shipped")
    assert_equal "Submitting", Task.active_stage_label("submitted")
    assert_equal "Designing", Task.active_stage_label("designed")
    assert_equal "Building", Task.active_stage_label("building")
    # every stage carries an active form
    assert_equal Task::STAGES.sort, Task::STAGE_ACTIVE_LABELS.keys.sort
    # unknown stages fall back to a humanized key, never blank
    assert_equal "Foo bar", Task.active_stage_label("foo_bar")
  end

  test "build and deploy stage groups share the submitted seam" do
    assert_includes Task::BUILD_STAGES, "submitted"
    assert_includes Task::DEPLOY_STAGES, "submitted"
    assert_equal "designed", Task::BUILD_STAGES.first
    assert_equal "shipped", Task::DEPLOY_STAGES.last
  end

  test "stage change sets the appropriate timestamp" do
    task = tasks(:new_task)
    task.update!(stage: "submitted")
    assert_not_nil task.submitted_at
    task.update!(stage: "shipped")
    assert_not_nil task.completed_at
  end

  # --- Slug ---

  test "slug is generated on create" do
    task = Task.create!(title: "Test slug generation")
    assert task.slug.present?
    assert_equal "test-slug-generation", task.slug # derives from the title now
  end

  test "slug is immutable after creation" do
    task = tasks(:new_task)
    original_slug = task.slug
    task.update!(title: "now a changed title")
    assert_equal original_slug, task.slug
  end

  test "to_param returns slug" do
    task = tasks(:new_task)
    assert_equal task.slug, task.to_param
  end

  # --- Position (event-driven rank: newest on top, 100-gap spacing) ---

  test "position is auto-set on create" do
    task = Task.create!(title: "Auto position test", stage: "designed")
    assert_not_nil task.position
  end

  test "a new task ranks above earlier tasks in its stage (top of column)" do
    existing = Task.where(stage: "designed").maximum(:position) || 0
    task = Task.create!(title: "fresh designed task here", stage: "designed")
    # max + 100 wins the `position DESC` sort, so a new card lands on top.
    assert_equal existing + 100, task.position
  end

  test "a stage move bumps the task to the top of the target stage" do
    task = tasks(:new_task)
    existing = Task.where(stage: "building").maximum(:position) || 0
    task.update!(stage: "building")
    assert_equal "building", task.stage
    assert_equal existing + 100, task.position
  end

  test "successive new tasks each rank above the previous (100-spaced)" do
    t1 = Task.create!(title: "first designed task here", stage: "designed")
    t2 = Task.create!(title: "second designed task here", stage: "designed")
    assert t2.position > t1.position
    assert_equal t1.position + 100, t2.position
  end

  test "ordered scope returns highest position first" do
    top = Task.create!(title: "top of designed column", stage: "designed")
    designed = Task.ordered.where(stage: "designed").to_a
    assert_equal top, designed.first, "the freshest (highest-position) task sorts first"
    positions = designed.map(&:position)
    assert_equal positions.sort.reverse, positions, "ordered is position DESC"
  end

  test "[unit] ordered scope prioritizes tasks waiting for operator approval" do
    normal = Task.create!(title: "normal building peer", stage: "building", position: 10_000)
    waiting = Task.create!(
      title: "approval waiting peer",
      stage: "building",
      position: 100,
      metadata: { "devops" => { "approval_status" => "waiting" } }
    )

    ordered = Task.where(slug: [normal.slug, waiting.slug]).ordered.to_a
    assert_equal [waiting.slug, normal.slug], ordered.map(&:slug)
  end

  test "[unit] the building board column carries blocked cards, ordered by position" do
    older_building = Task.create!(title: "older building card here", stage: "building")
    blocked = Task.create!(title: "stale blocked card here", stage: "building")
    blocked.block!(by: "avi", kind: "rework") # a block is a building attribute now
    reactivated = Task.create!(title: "reactivated building card here", stage: "building")

    grouped = Task.where(slug: [older_building.slug, blocked.slug, reactivated.slug])
                  .ordered
                  .group_by(&:stage)
    column = Task.board_column_tasks(grouped, "building").map(&:slug)

    assert_includes column, blocked.slug, "a blocked task rides the building column"
    assert_equal Array(grouped["building"]).map(&:slug), column,
                 "the building column is just the building stage group now"
  end

  test "tasks default to the designed stage" do
    task = Task.create!(title: "default stage check task")
    assert_equal "designed", task.stage
  end

  # --- Sizing (sealed-bid) ---

  test "size columns accept all valid t-shirt sizes" do
    task = Task.create!(title: "sizing test sample task")
    Task::SIZES.each do |size|
      %i[pm_size po_size dev_size actual_size].each do |col|
        task.update!(col => size)
        assert_equal size, task.public_send(col)
      end
    end
  end

  test "size columns reject invalid sizes" do
    task = Task.new(title: "bad size value task", pm_size: "huge")
    assert_not task.valid?
    assert_includes task.errors[:pm_size], "is not included in the list"
  end

  test "size columns allow nil" do
    task = Task.create!(title: "no sizes set task")
    assert_nil task.pm_size
    assert_nil task.po_size
    assert_nil task.dev_size
    assert_nil task.actual_size
    assert task.valid?
  end

  # --- requires_migration ---

  test "requires_migration scope returns only flagged tasks" do
    flagged = Task.create!(title: "needs migration flag task", requires_migration: true)
    Task.create!(title: "no migration flag task")
    assert_includes Task.requires_migration, flagged
    assert_equal 1, Task.requires_migration.where(title: ["needs migration flag task", "no migration flag task"]).count
  end

  test "requires_migration defaults to false" do
    task = Task.create!(title: "default flag check task")
    assert_equal false, task.requires_migration
  end

  # --- Migration lane ---
  #
  # Task once carried `try_acquire_migration_lane` / `release_migration_lane`
  # (session advisory locks), "covered" here by a test that asserted only
  # `assert_includes [true, false], acquired` — a tautology no implementation could
  # fail, including the broken one it was guarding. Both helpers are gone; the lane
  # is claimed through MigrationLaneClaim, whose exclusivity is proved against real
  # concurrent connections in test/integration/migration_lane_exclusion_race_test.rb.
  # Task keeps only the lane KEY.

  test "[unit] the migration lane key is the one MigrationLaneClaim claims" do
    assert_equal "backend_migration", Task::MIGRATION_LANE
    assert_equal Task::MIGRATION_LANE, MigrationLaneClaim.new(lane: Task::MIGRATION_LANE).lane
  end

  test "[unit] the retired advisory-lock helpers are gone" do
    refute Task.respond_to?(:try_acquire_migration_lane),
           "a session advisory lock cannot back a lane bin/task reaches over HTTP"
    refute Task.respond_to?(:release_migration_lane)
  end

  # --- DevOps metadata ---

  test "normalizes devops metadata lists from strings and arrays" do
    metadata = Task.normalize_devops_metadata(
      "repositories" => "mcritchie-studio, turf-monster\nstudio-engine",
      "risk_tags" => ["auth", "auth", "deploy"],
      "acceptance" => "QA URL works\nProduction stays gated",
      "checks_run" => "bin/rails test\nbin/rubocop",
      "branch" => " feat/example ",
      "worktree_slug" => " task-board-contract "
    )

    assert_equal ["mcritchie-studio", "turf-monster", "studio-engine"], metadata["repositories"]
    assert_equal ["auth", "deploy"], metadata["risk_tags"]
    assert_equal ["QA URL works", "Production stays gated"], metadata["acceptance"]
    assert_equal ["bin/rails test", "bin/rubocop"], metadata["checks_run"]
    assert_equal "feat/example", metadata["branch"]
    assert_equal "task-board-contract", metadata["worktree_slug"]
  end

  test "array-form devops lists keep commas; string-form still splits on commas" do
    metadata = Task.normalize_devops_metadata(
      "acceptance" => ["Header stays pinned, even while scrolling", "Email still works"],
      "risk_tags" => "auth, deploy"
    )

    # Array items are preserved verbatim — a comma inside a sentence is kept.
    assert_equal ["Header stays pinned, even while scrolling", "Email still works"], metadata["acceptance"]
    # String (UI free-text) fields still split on comma and newline.
    assert_equal ["auth", "deploy"], metadata["risk_tags"]
  end

  # Retiring a key from DEVOPS_KEYS used to mean the write vanished behind a 200.
  # That silence is the defect: `release_slug` diverged into two stores precisely
  # because a wrong write looked like a successful one. Every column-backed name
  # now REFUSES the write and names its real home.
  test "[unit] a devops write to a column-backed name raises and names the column" do
    Task::DEVOPS_COLUMN_KEYS.each_key do |key|
      error = assert_raises(ArgumentError, "devops.#{key} must be refused, not dropped") do
        Task.normalize_devops_metadata(key => "some-value")
      end
      assert_match(/devops\.#{Regexp.escape(key)} is not writable/, error.message)
      assert_match(/column/, error.message, "the message must name where the field actually lives")
    end
  end

  test "[unit] block_kind is refused from devops metadata (it is a column now)" do
    error = assert_raises(ArgumentError) { Task.normalize_devops_metadata("block_kind" => "environment") }
    assert_match(/tasks\.block_kind column/, error.message)
    assert_match(/Task#block!/, error.message, "the message must point at the endpoint that does work")
  end

  # A blank asserts nothing, so there is nothing to correct — and raising on it
  # would break callers that build a devops hash with empty placeholders.
  test "[unit] a blank column-backed devops value is skipped, not raised" do
    metadata = nil
    assert_nothing_raised do
      metadata = Task.normalize_devops_metadata("release_slug" => "  ", "kind" => "bug")
    end
    assert_equal "bug", metadata["kind"]
    assert_not metadata.key?("release_slug")
  end

  test "[unit] approval status normalizes and stamps request time" do
    metadata = Task.normalize_devops_metadata(
      "approval_status" => " waiting ",
      "approval_requested_by" => "scyther"
    )

    task = Task.create!(title: "approval helper task", metadata: { "devops" => metadata })

    assert_equal "waiting", task.approval_status
    assert task.waiting_for_operator_approval?
    assert_equal "scyther", task.devops["approval_requested_by"]
    assert task.devops["approval_requested_at"].present?
  end

  test "devops helpers expose stored release metadata" do
    task = Task.create!(
      title: "Ship a feature",
      metadata: {
        "devops" => {
          "kind" => "bug",
          "worktree_slug" => "qa-contest-flow",
          "repositories" => ["turf-monster"],
          "qa_url" => "https://qa.turfmonster.media/contests",
          "requires_release_conductor" => "1",
          "test_plan" => ["bin/rails test"],
          "checks_run" => ["bin/rails test test/models/task_test.rb"]
        }
      }
    )

    assert task.devops?
    assert task.requires_release_conductor?
    assert_equal "bug", task.devops_kind
    assert_equal "qa-contest-flow", task.devops_worktree_slug
    assert_equal ["turf-monster"], task.devops_repositories
    assert_equal "https://qa.turfmonster.media/contests", task.devops_url(:qa)
    assert_equal ["bin/rails test"], task.devops_test_plan
    assert_equal ["bin/rails test test/models/task_test.rb"], task.devops_checks_run
  end

  # `release_train` used to normalize INTO the devops release_slug shadow. Both
  # names now point at the column, so the legacy spelling is refused with the same
  # sentence as the modern one — a caller using the old name gets told where the
  # field went, not a quiet success on a store nothing reads.
  test "[unit] legacy release_train is refused and points at the release_slug column" do
    error = assert_raises(ArgumentError) do
      Task.normalize_devops_metadata("release_train" => "2026-06-17-turf", "kind" => "feature")
    end

    assert_match(/devops\.release_train is not writable/, error.message)
    assert_match(/tasks\.release_slug column/, error.message)
    assert_match(/Release#record_members/, error.message)
  end

  # THE INVARIANT, proved against the path that walks around the normalizer:
  # Api::V1::TasksController#task_params permits `metadata: {}` wholesale, so a raw
  # PATCH can plant devops.release_slug without ever calling normalize. It must not
  # survive the save, and it must not touch the column. Without the
  # shed_column_shadow_keys callback this stores the fiction and the task page
  # renders it — which is the original bug, reachable by a second door.
  test "[unit] a raw metadata write cannot plant a release_slug shadow" do
    task = Task.create!(title: "Shadow proof task", release_slug: "rel-2026-08-12-real")

    task.update!(metadata: { "devops" => { "kind" => "bug", "release_slug" => "rel-typed-by-hand" } })
    task.reload

    assert_not task.devops.key?("release_slug"),
               "a column-backed name must never persist under metadata.devops"
    assert_equal "rel-2026-08-12-real", task.release_slug,
                 "the column is the one store, and a shadow write must not disturb it"
    assert_equal "bug", task.devops["kind"], "shedding must not damage its devops neighbours"
  end

  # The reader half. There is no devops_release_slug any more — the name resolves
  # to the column and to the belongs_to it backs.
  test "[unit] release membership reads from the column and its release record" do
    release = Release.open!
    task = Task.create!(title: "Column reader task", release_slug: release.slug)

    assert_equal release.slug, task.release_slug
    assert_equal release, task.release
    assert_not task.respond_to?(:devops_release_slug),
               "a devops_-prefixed reader would reintroduce the second universe"
  end

  # --- Build claim lease (V2) ---

  test "claim keys survive devops normalization (persist on the board)" do
    metadata = Task.normalize_devops_metadata(
      "claimed_session" => "sess-1",
      "claim_nonce" => "inst-A",
      "claim_expires_at" => "2026-06-23T12:02:00Z"
    )
    assert_equal "sess-1", metadata["claimed_session"]
    assert_equal "inst-A", metadata["claim_nonce"]
    assert_equal "2026-06-23T12:02:00Z", metadata["claim_expires_at"]
  end

  # `building`, explicitly: the build claim is a BUILD-STAGE lease, and
  # Task#enforce_build_claim_invariant sheds the keys from any other stage (a
  # claim on a `designed` task is the phantom the heartbeat already refuses to
  # forge). The stage was incidental to this case before that invariant existed.
  test "claim_live? and heartbeat age reflect a non-expired lease" do
    now = Time.utc(2026, 6, 23, 12, 0, 0)
    task = Task.create!(
      title: "Claimed build task",
      stage: "building",
      metadata: { "devops" => {
        "claimed_session" => "sess-1", "claim_nonce" => "inst-A",
        "claim_expires_at" => (now + 90).utc.iso8601
      } }
    )

    assert task.claim_live?(now: now)
    assert_equal "sess-1", task.claimed_session_id
    assert_equal "inst-A", task.devops_claim_nonce
    # 120s TTL, 90s of lease left ⇒ last heartbeat ~30s ago.
    assert_equal 30, task.claim_heartbeat_seconds_ago(now: now)
  end

  test "claim_live? is false once the lease has expired" do
    now = Time.utc(2026, 6, 23, 12, 0, 0)
    task = Task.create!(
      title: "Stale claim task",
      metadata: { "devops" => {
        "claimed_session" => "sess-1", "claim_nonce" => "inst-A",
        "claim_expires_at" => (now - 5).utc.iso8601
      } }
    )

    refute task.claim_live?(now: now)
  end

  test "an unclaimed task is not live" do
    task = Task.create!(title: "Unclaimed build task")
    refute task.claim_live?
    assert_nil task.claimed_session_id
    assert_nil task.claim_heartbeat_seconds_ago
  end

  # --- Slug: explicit override, else derived from the (terse) title ---

  test "an explicit slug becomes the readable, parameterized Task.slug" do
    task = Task.create!(title: "valid four word title", slug: "Standard Link Model")
    assert_equal "standard-link-model", task.slug
  end

  test "no explicit slug derives the slug from the title" do
    task = Task.create!(title: "Derive slug from title")
    assert_equal "derive-slug-from-title", task.slug
  end

  test "title-derived slugs auto-suffix to stay unique" do
    first = Task.create!(title: "Same short title")
    second = Task.create!(title: "Same short title")
    assert_equal "same-short-title", first.slug
    assert_equal "same-short-title-2", second.slug
  end

  test "an unparameterizable title falls back to hex and does not trickle" do
    task = Task.create!(title: "### @@@ %%%") # 3 'words', parameterizes to blank
    assert_match(/\Atask-[0-9a-f]{12}\z/, task.slug)
    assert_nil task.devops_worktree_slug
  end

  test "the slug seeds worktree_slug and branch (trickle-down)" do
    task = Task.create!(title: "Readable handle here")
    assert_equal "readable-handle-here", task.devops_worktree_slug
    assert_equal "feat/readable-handle-here", task.metadata.dig("devops", "branch")
  end

  test "explicit worktree_slug/branch are not overwritten by the trickle-down" do
    task = Task.create!(title: "Readable handle here", slug: "readable-handle",
                        metadata: { "devops" => { "worktree_slug" => "custom-wt", "branch" => "feat/custom" } })
    assert_equal "custom-wt", task.devops_worktree_slug
    assert_equal "feat/custom", task.metadata.dig("devops", "branch")
  end

  test "slug is immutable after creation (attr_readonly raises on update)" do
    task = Task.create!(title: "Immutable slug test", slug: "original")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { task.update!(slug: "changed") }
    assert_equal "original", task.reload.slug
  end

  test "a duplicate explicit slug is rejected" do
    Task.create!(title: "First dupe task", slug: "dupe")
    dup = Task.new(title: "Second dupe task", slug: "dupe")
    assert_not dup.valid?
    assert_includes dup.errors[:slug], "has already been taken"
  end

  # --- release_repo / gem_release? / release_kind ---

  test "release_repo parses the repo from a github PR url" do
    task = Task.create!(title: "engine version bump task", stage: "reviewed",
                        metadata: { "devops" => { "pr_url" => "https://github.com/McRitchie-Studio/studio-engine/pull/9" } })
    assert_equal "studio-engine", task.release_repo
    assert task.gem_release?
    assert_equal :gem, task.release_kind
  end

  test "release_repo prefers the PR url over the declared repositories" do
    task = Task.create!(title: "mixed repo source task", stage: "reviewed",
                        metadata: { "devops" => {
                          "pr_url" => "https://github.com/McRitchie-Studio/solana-studio/pull/3",
                          "repositories" => ["turf-monster"]
                        } })
    assert_equal "solana-studio", task.release_repo
    assert task.gem_release?
  end

  test "a library-shape task is a gem release via its declared gem repo" do
    task = Task.create!(title: "engine UI primitive", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "library", "repositories" => ["studio-engine"] } })
    assert_equal "studio-engine", task.release_repo
    assert task.gem_release?
    assert_equal :gem, task.release_kind
  end

  test "a library-shape task is a gem release even with no resolvable gem repo" do
    task = Task.create!(title: "library no repos", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "library" } })
    assert task.gem_release?, "library shape is always a gem release"
    assert_equal :gem, task.release_kind
  end

  test "an app task is not a gem release" do
    task = Task.create!(title: "app feature release task", stage: "reviewed",
                        metadata: { "devops" => {
                          "shape" => "backend",
                          "repositories" => ["mcritchie-studio"],
                          "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/77"
                        } })
    assert_equal "mcritchie-studio", task.release_repo
    assert_not task.gem_release?
    assert_equal :app, task.release_kind
  end

  test "a task with no repo metadata classifies as unknown, not a gem" do
    task = Task.create!(title: "bare task no repo", stage: "reviewed")
    assert_nil task.release_repo
    assert_not task.gem_release?
    assert_equal :unknown, task.release_kind
  end

  # --- pr_urls: the per-repo PR register -------------------------------------
  #
  # `pr_url` holds ONE url and #release_repo parses it for the repo a release
  # plans against, so a task naming two repos had exactly one place to record a
  # PR. On 2026-08-13 `land-rails-security-patch` named [mcritchie-studio,
  # turf-monster] with the hub's PR url; turf's PR had nowhere to live, turf was
  # never promoted, and the task was stamped shipped + merged:"main" while turf
  # production ran the unpatched code. These cases pin the register that closes
  # that, at the model — the CLI cases in test/lib/task_cli_test.rb never load
  # Rails and can only assert the outgoing PATCH body.

  HUB_PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836".freeze
  TURF_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/305".freeze
  ENGINE_PR = "https://github.com/McRitchie-Studio/studio-engine/pull/12".freeze

  # NOTE the explicit-hash signature (no keyword args): a brace-less `"k" => v`
  # at a call site whose method accepts keywords is parsed as KEYWORDS in Ruby 3,
  # which swallowed the devops hash and left the positional empty.
  def pr_urls_task(devops)
    Task.create!(title: "per repo pr register task", stage: "reviewed",
                 metadata: { "devops" => devops })
  end

  test "[unit] release_pr_urls folds the singular pr_url in under the repo it names" do
    task = pr_urls_task("pr_url" => HUB_PR, "pr_urls" => { "turf-monster" => TURF_PR })
    assert_equal({ "turf-monster" => TURF_PR, "mcritchie-studio" => HUB_PR }, task.release_pr_urls)
  end

  test "[unit] release_pr_urls on a singular-only task is the one repo it names" do
    task = pr_urls_task("pr_url" => HUB_PR)
    assert_equal({ "mcritchie-studio" => HUB_PR }, task.release_pr_urls)
  end

  # THE PRECEDENCE COLLISION — the singular wins for its own repo. `pr_url` is
  # what #release_repo, bin/dor-check, bin/pr-review and the review flow's
  # pending actions all act on; if a map entry could override it the pipeline
  # would hold two different PRs for one repo and say nothing, and correcting the
  # url with `--pr-url` would be silently undone by the stale explicit entry.
  test "[unit] the singular pr_url WINS over a pr_urls entry for the same repo" do
    stale = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999"
    task = pr_urls_task("pr_url" => HUB_PR, "pr_urls" => { "mcritchie-studio" => stale })
    assert_equal HUB_PR, task.release_pr_urls["mcritchie-studio"],
                 "the field every other reader acts on stays authoritative for its repo"
  end

  test "[unit] a pr_url naming no repo contributes nothing to release_pr_urls" do
    task = pr_urls_task("pr_url" => "https://example.com/not-a-pr",
                        "pr_urls" => { "turf-monster" => TURF_PR })
    assert_equal({ "turf-monster" => TURF_PR }, task.release_pr_urls)
  end

  # A non-Hash `pr_urls` on the record (a hand-written string, a legacy array)
  # degrades to "no map recorded" rather than raising mid-release.
  test "[unit] release_pr_urls ignores a pr_urls that is not a hash" do
    task = pr_urls_task("pr_url" => HUB_PR, "pr_urls" => "turf-monster")
    assert_equal({ "mcritchie-studio" => HUB_PR }, task.release_pr_urls)
  end

  test "[unit] release_pr_urls drops blank repos and blank urls" do
    task = pr_urls_task("pr_urls" => { "turf-monster" => TURF_PR, "" => HUB_PR, "rolio" => "  " })
    assert_equal({ "turf-monster" => TURF_PR }, task.release_pr_urls)
  end

  test "[unit] repos_missing_pr_url names the repo with no recorded url" do
    task = pr_urls_task("repositories" => ["mcritchie-studio", "turf-monster"], "pr_url" => HUB_PR)
    assert_equal ["turf-monster"], task.repos_missing_pr_url
  end

  test "[unit] repos_missing_pr_url is empty once every named repo has a PR" do
    task = pr_urls_task("repositories" => ["mcritchie-studio", "turf-monster"],
                        "pr_url" => HUB_PR, "pr_urls" => { "turf-monster" => TURF_PR })
    assert_empty task.repos_missing_pr_url
  end

  # THE GEM FALSE POSITIVE. A gem task names the gem AND the consumers that must
  # pick the new version up, but the work is ONE PR in the gem repo — the
  # consumers reach production through a published version and the conductor's
  # bump, never through a PR the builder opens. Measured literally, every
  # legitimate engine release reports both consumers "missing a PR": the exact
  # inversion of the failure this query exists to catch.
  test "[unit] a gem task's CONSUMER repos are not missing PRs they must never have" do
    task = pr_urls_task("shape" => "library",
                        "repositories" => ["studio-engine", "mcritchie-studio", "turf-monster"],
                        "pr_url" => ENGINE_PR)
    assert_equal ["studio-engine"], task.pr_bearing_repositories
    assert_empty task.repos_missing_pr_url,
                 "the gem PR covers the release; the consumers ride the published version"
  end

  test "[unit] a gem task with NO gem PR is still reported uncovered" do
    task = pr_urls_task("shape" => "library",
                        "repositories" => ["studio-engine", "mcritchie-studio"])
    assert_equal ["studio-engine"], task.repos_missing_pr_url
  end

  # A gem task whose `repositories` names only consumers (the PR lives in a repo
  # the list never mentions) is covered by the gem PR it recorded.
  test "[unit] a gem task naming no gem repo is covered by the gem PR it recorded" do
    task = pr_urls_task("repositories" => ["mcritchie-studio", "turf-monster"], "pr_url" => ENGINE_PR)
    assert task.gem_release?, "release_repo parses to studio-engine, a registered gem"
    assert_equal ["studio-engine"], task.pr_bearing_repositories
    assert_empty task.repos_missing_pr_url
  end

  # …but a library-shape task with no gem evidence ANYWHERE falls back to the
  # literal list rather than reporting full coverage off an empty set.
  test "[unit] a library task with no gem in play falls back to its literal repositories" do
    task = pr_urls_task("shape" => "library", "repositories" => ["mcritchie-studio"])
    assert_equal ["mcritchie-studio"], task.repos_missing_pr_url
  end

  test "[unit] an app task measures coverage against every repo it names" do
    task = pr_urls_task("shape" => "backend",
                        "repositories" => ["mcritchie-studio", "turf-monster"],
                        "pr_url" => HUB_PR)
    assert_equal ["mcritchie-studio", "turf-monster"], task.pr_bearing_repositories
  end

  # --- normalize_devops_map: what may be STORED ------------------------------

  test "[unit] normalize_devops_map keeps a well-formed repo => url object" do
    assert_equal({ "turf-monster" => TURF_PR },
                 Task.normalize_devops_map("turf-monster" => TURF_PR))
  end

  test "[unit] normalize_devops_map keys a bare list of urls by the repo each names" do
    assert_equal({ "mcritchie-studio" => HUB_PR, "turf-monster" => TURF_PR },
                 Task.normalize_devops_map([HUB_PR, TURF_PR]))
  end

  # THE HASH BRANCH VALIDATES TOO, and that symmetry is the point: it used to take
  # its value verbatim, so a nonsense string satisfied the coverage this register
  # exists to hold — on the only path anything actually writes.
  test "[unit] normalize_devops_map REFUSES a hash value that is not a PR url" do
    error = assert_raises(ArgumentError) { Task.normalize_devops_map("turf-monster" => "lol") }
    assert_match(/names no repo/, error.message)
  end

  test "[unit] normalize_devops_map REFUSES a url filed under the wrong repo" do
    error = assert_raises(ArgumentError) { Task.normalize_devops_map("mcritchie-studio" => TURF_PR) }
    assert_match(/wrong repo/, error.message)
    assert_match(/turf-monster/, error.message, "the error names the repo the url actually points at")
  end

  test "[unit] normalize_devops_map REFUSES a list entry that names no repo" do
    error = assert_raises(ArgumentError) { Task.normalize_devops_map(["https://example.com/nope"]) }
    assert_match(/names no repo/, error.message)
  end

  # A blank value drops rather than raising — it asserts nothing, and it is how
  # the API unsets one entry (every writer sends the whole map).
  test "[unit] normalize_devops_map drops a blank value, which is the API unset" do
    assert_equal({ "turf-monster" => TURF_PR },
                 Task.normalize_devops_map("turf-monster" => TURF_PR, "mcritchie-studio" => ""))
    assert_empty Task.normalize_devops_map("turf-monster" => "")
  end

  test "[unit] normalize_devops_map strips surrounding whitespace" do
    assert_equal({ "turf-monster" => TURF_PR },
                 Task.normalize_devops_map(" turf-monster " => " #{TURF_PR} "))
  end

  # The whole-metadata path: pr_urls is a DEVOPS_MAP_KEY, so it survives
  # normalize_devops_metadata as a map (not stringified), and an empty one drops.
  test "[unit] normalize_devops_metadata stores pr_urls as a map and drops an empty one" do
    normalized = Task.normalize_devops_metadata("pr_urls" => { "turf-monster" => TURF_PR })
    assert_equal({ "turf-monster" => TURF_PR }, normalized["pr_urls"])
    assert_not Task.normalize_devops_metadata("pr_urls" => {}).key?("pr_urls"),
               "an empty map is dropped, so empty and unset are one state"
  end

  test "[unit] Task.repo_from_pr_url is the one parser the instance method delegates to" do
    assert_equal "turf-monster", Task.repo_from_pr_url(TURF_PR)
    assert_nil Task.repo_from_pr_url("https://example.com/not-a-pr")
    assert_nil Task.repo_from_pr_url(nil)
    task = pr_urls_task("pr_url" => TURF_PR)
    assert_equal "turf-monster", task.send(:repo_from_pr_url)
  end

  # --- Per-application release inclusion (Avi's qa-release disposition) ---

  test "[unit] included_in_release? defaults true so a plain reviewed task ships" do
    task = Task.create!(title: "default inclusion task", stage: "reviewed")
    assert task.included_in_release?, "the default is to ship ALL reviewed work"
  end

  test "[unit] an explicit false holds a member out of the release" do
    task = Task.create!(title: "held back task", stage: "reviewed",
                        metadata: { "devops" => { "included_in_release" => "false" } })
    assert_not task.included_in_release?, "an explicit false marks the member held from the release"
  end

  test "[unit] included_in_release survives normalize_devops_metadata as a client key" do
    normalized = Task.normalize_devops_metadata("included_in_release" => "false")
    assert_equal "false", normalized["included_in_release"],
                 "the flag must be a permitted devops key so the API/board can write it"
  end

  test "[unit] reviewed_release_inclusion marks the reviewed app members, grouped by app" do
    included = Task.create!(title: "turf app member in", stage: "reviewed",
                            metadata: { "devops" => {
                              "pr_url" => "https://github.com/McRitchie-Studio/turf-monster/pull/1"
                            } })
    held = Task.create!(title: "hub app member held", stage: "reviewed",
                        metadata: { "devops" => {
                          "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/2",
                          "included_in_release" => "false"
                        } })
    # A non-reviewed task must never appear in the reviewed disposition.
    Task.create!(title: "submitted not reviewed", stage: "submitted",
                 metadata: { "devops" => { "pr_url" => "https://github.com/McRitchie-Studio/turf-monster/pull/9" } })

    inclusion = Task.reviewed_release_inclusion

    assert_equal %w[mcritchie-studio turf-monster].sort, inclusion.keys.sort
    assert inclusion["turf-monster"][:included], "the turf app rides by default (all members included)"
    assert_includes inclusion["turf-monster"][:members], included
    assert_not inclusion["mcritchie-studio"][:included], "one held member flags its whole app as held from release"
    assert_includes inclusion["mcritchie-studio"][:members], held
  end

  test "[unit] an app is held only when EVERY reviewed member is held" do
    Task.create!(title: "turf member shipping", stage: "reviewed",
                 metadata: { "devops" => { "pr_url" => "https://github.com/McRitchie-Studio/turf-monster/pull/3" } })
    Task.create!(title: "turf member held out", stage: "reviewed",
                 metadata: { "devops" => {
                   "pr_url" => "https://github.com/McRitchie-Studio/turf-monster/pull/4",
                   "included_in_release" => "false"
                 } })

    inclusion = Task.reviewed_release_inclusion
    assert_not inclusion["turf-monster"][:included],
               "a single held member holds the whole app so the marker never says 'shipping' over an ejected member"
  end

  # --- Naming discipline: terse title + acceptance, agent_context ---

  test "title must be 3-5 words on create" do
    assert Task.new(title: "fix the login").valid?               # 3
    assert Task.new(title: "add a new login flow").valid?        # 5
    assert_not Task.new(title: "fix login").valid?               # 2
    assert_not Task.new(title: "add a brand new login flow now").valid? # 7
  end

  test "an existing task is grandfathered until its title actually changes" do
    task = Task.create!(title: "valid four word title")
    task.update!(stage: "building") # title untouched → not re-validated
    assert_equal "building", task.reload.stage
    assert_raises(ActiveRecord::RecordInvalid) do
      task.update!(title: "now this title has far too many words to pass") # 9
    end
  end

  test "each acceptance bullet must be 5-12 words on create" do
    ok = Task.new(title: "acceptance length check",
                  metadata: { "devops" => { "acceptance" => ["the user can log in successfully"] } }) # 6
    assert ok.valid?
    short = Task.new(title: "acceptance length check",
                     metadata: { "devops" => { "acceptance" => ["too short here"] } }) # 3
    assert_not short.valid?
  end

  test "acceptance is validated on change but unrelated devops updates are grandfathered" do
    task = Task.create!(title: "acceptance change task",
                        metadata: { "devops" => { "acceptance" => ["the user can log in successfully"] } })
    task.update!(metadata: task.metadata.deep_merge("devops" => { "kind" => "bug" })) # acceptance untouched
    assert_equal "bug", task.devops_kind
    assert_raises(ActiveRecord::RecordInvalid) do
      task.update!(metadata: task.metadata.deep_merge("devops" => { "acceptance" => ["too short"] })) # 2
    end
  end

  test "agent_context stores free-form verbose detail" do
    task = Task.create!(title: "agent context round trip",
                        metadata: { "devops" => { "agent_context" => "Verbose multi-line\nreasoning for agents." } })
    assert_equal "Verbose multi-line\nreasoning for agents.", task.devops_agent_context
  end

  # --- Session resume (V1: store + display + copy) ---

  test "normalize keeps session_id and session_provider (accepted by the API)" do
    metadata = Task.normalize_devops_metadata(
      "session_id" => "2aa216f6-7565-4bf4-bd01-70793c8ba617",
      "session_provider" => "claude"
    )
    assert_equal "2aa216f6-7565-4bf4-bd01-70793c8ba617", metadata["session_id"]
    assert_equal "claude", metadata["session_provider"]
  end

  test "session_id_last4 returns the trailing four chars, nil-safe" do
    with_session = Task.new(title: "session last four",
                            metadata: { "devops" => { "session_id" => "abcd-1234-12ab" } })
    assert_equal "12ab", with_session.session_id_last4

    without = Task.new(title: "no session here")
    assert_nil without.session_id_last4
  end

  test "resume_command builds the claude command from the full session id" do
    task = Task.new(title: "resume claude command",
                    metadata: { "devops" => { "session_id" => "sess-12ab", "session_provider" => "claude" } })
    assert_equal "claude --resume sess-12ab", task.resume_command
  end

  test "resume_command builds the codex command for a codex session" do
    task = Task.new(title: "resume codex command",
                    metadata: { "devops" => { "session_id" => "sess-99zz", "session_provider" => "codex" } })
    assert_equal "codex resume sess-99zz", task.resume_command
  end

  test "resume_command treats a missing provider as claude" do
    task = Task.new(title: "resume default provider",
                    metadata: { "devops" => { "session_id" => "sess-77yy" } })
    assert_equal "claude --resume sess-77yy", task.resume_command
  end

  test "resume_command falls back to claude for an unknown provider" do
    task = Task.new(title: "resume unknown provider",
                    metadata: { "devops" => { "session_id" => "sess-55xx", "session_provider" => "vim" } })
    assert_equal "claude --resume sess-55xx", task.resume_command
  end

  test "resume_command is nil when there is no session id" do
    assert_nil Task.new(title: "no session command").resume_command
  end

  test "resume_command_display truncates to the verb plus last four" do
    claude = Task.new(title: "display claude command",
                      metadata: { "devops" => { "session_id" => "long-session-12ab" } })
    assert_equal "claude --resume …12ab", claude.resume_command_display

    codex = Task.new(title: "display codex command",
                     metadata: { "devops" => { "session_id" => "long-session-99zz", "session_provider" => "codex" } })
    assert_equal "codex resume …99zz", codex.resume_command_display
  end

  test "resume_command_display is nil when there is no session id" do
    assert_nil Task.new(title: "no session display").resume_command_display
  end

  # --- Pokémon mascot (a fun, unique, per-task identifier) ---

  def seed_pokemon(*slugs)
    slugs.each_with_index { |s, i| Pokemon.create!(dex: 900 + i, name: s.capitalize, slug: s, generation: 1) }
  end

  test "create assigns a Pokemon mascot from the deck" do
    seed_pokemon("snorlax", "pikachu", "eevee")
    task = Task.create!(title: "Mascot assignment test task")
    assert_includes %w[snorlax pikachu eevee], task.devops["mascot"]
  end

  test "mascot is unique among live tasks" do
    seed_pokemon("snorlax", "pikachu")
    first = Task.create!(title: "First live mascot task")
    second = Task.create!(title: "Second live mascot task")
    assert_not_equal first.devops["mascot"], second.devops["mascot"]
  end

  test "an explicit mascot override is preserved" do
    seed_pokemon("snorlax")
    task = Task.create!(title: "Override mascot test task",
                        metadata: { "devops" => { "mascot" => "ditto" } })
    assert_equal "ditto", task.devops["mascot"]
  end

  test "active_mascots excludes shipped and archived tasks" do
    seed_pokemon("snorlax", "pikachu", "eevee")
    live = Task.create!(title: "Live mascot holder task")
    shipped = Task.create!(title: "Shipped mascot holder task")
    shipped.update!(stage: "shipped")

    assert_includes Task.active_mascots, live.devops["mascot"]
    assert_not_includes Task.active_mascots, shipped.devops["mascot"]
  end

  test "create leaves mascot unset when the deck is unseeded" do
    task = Task.create!(title: "No deck mascot task")
    assert_nil task.devops["mascot"]
  end

  # --- App identity (status-line color) + agent persona ----------------------

  test "create stamps the app's status-line color from the first repository" do
    task = Task.create!(title: "App color stamp task",
                        metadata: { "devops" => { "repositories" => ["turf-monster"] } })
    assert_equal "#22C55E", task.devops["app_color"], "a Turf Monster task carries green"
  end

  test "app_color is re-stamped on update and follows a repository change" do
    task = Task.create!(title: "App color update task",
                        metadata: { "devops" => { "repositories" => ["turf-monster"] } })
    task.update!(metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
    assert_equal "#B57EDC", task.reload.devops["app_color"], "the tint follows the new repo"
  end

  test "app_color is left unset for a repo with no App row" do
    task = Task.create!(title: "Unknown repo color task",
                        metadata: { "devops" => { "repositories" => ["mystery-app"] } })
    assert_nil task.devops["app_color"], "an unknown app → default tint at render time"
  end

  test "a persona makes the mascot the soul (glyph + tint), not a Pokemon" do
    seed_pokemon("snorlax", "pikachu")
    Agent.create!(name: "Jasper", slug: "jasper", status: "active",
                  metadata: { "emoji" => "🧪", "color" => "#9945FF" })
    task = Task.create!(title: "Act as Jasper task",
                        metadata: { "devops" => { "persona" => "jasper" } })
    assert_equal "Jasper", task.devops["mascot"], "the mascot becomes the soul"
    assert_equal "🧪", task.devops["mascot_emoji"]
    assert_equal "#9945FF", task.devops["mascot_color"]
    refute_includes %w[snorlax pikachu], task.devops["mascot"], "the Pokemon is not drawn over it"
  end

  test "an unknown persona falls through to the Pokemon path" do
    seed_pokemon("snorlax")
    task = Task.create!(title: "Unknown persona task",
                        metadata: { "devops" => { "persona" => "nobody" } })
    assert_equal "snorlax", task.devops["mascot"], "no such soul → keep the session Pokemon"
  end

  test "persona none reverts the mascot to the session Pokemon mid-task" do
    seed_pokemon("snorlax", "pikachu")
    Agent.create!(name: "Jasper", slug: "jasper", status: "active",
                  metadata: { "emoji" => "🧪", "color" => "#9945FF" })
    task = Task.create!(title: "Revert persona task",
                        metadata: { "devops" => { "persona" => "jasper" } })
    assert_equal "Jasper", task.devops["mascot"], "starts as the soul"

    # Simulate the CLI read-modify-write: the prior soul rides back with persona=none,
    # so the clear path must actively nil the stale mascot, not just drop the key.
    task.update!(metadata: { "devops" => { "mascot" => "Jasper", "persona" => "none" } })
    task.reload
    assert_includes %w[snorlax pikachu], task.devops["mascot"], "reverts to a Pokemon"
    assert_nil task.devops["persona"], "the persona key is dropped"
    assert_nil task.devops["mascot_emoji"], "the soul's glyph is cleared"
  end

  # --- reviewers (two-senior review metadata) ---------------------------------

  test "reviewers is empty for an old-flow task without the metadata" do
    assert_equal [], Task.new(title: "no reviewers meta task").reviewers
  end

  test "reviewers normalizes hashes, slug strings, and aliases; drops blanks" do
    task = Task.new(title: "reviewers shape task", metadata: { "reviewers" => [
      { "slug" => "shannon", "weight" => "heavy" },
      { "agent_slug" => " carl ", "depth" => "light" },  # aliases + whitespace
      { "slug" => "steffon", "review_weight" => "heavy" }, # souls-seed key
      "jasper",                                           # bare slug string
      { "slug" => "" },                                   # blank slug, dropped
      { "weight" => "heavy" }                             # no slug, dropped
    ] })

    assert_equal(
      [
        { "slug" => "shannon", "weight" => "heavy" },
        { "slug" => "carl",    "weight" => "light" },
        { "slug" => "steffon", "weight" => "heavy" },
        { "slug" => "jasper",  "weight" => nil }
      ],
      task.reviewers
    )
  end

  test "submitted->reviewed records the same pair bin/reviewer-select would preview" do
    # Integration boundary for AC2: the recorder (stage_event_metadata ->
    # ReviewerSelector.select) writes the reviewers into the submitted->reviewed
    # TaskEvent, while bin/reviewer-select previews them via .decision/.explain —
    # two independent passes. With the per-task seeded tiebreak they must agree,
    # even on a genuine tie (no shape/risk/repo), so Avi never spawns a pair the
    # timeline then contradicts.
    task = Task.create!(title: "reviewer record boundary task", stage: "submitted")
    preview = ReviewerSelector.explain(task)["reviewers"].map { |r| r["slug"] }

    task.review! # submitted -> reviewed; the recorder writes the reviewers

    event = task.task_events.chronological.last
    assert_equal "reviewed", event.to_stage, "the recorded event is the submitted->reviewed transition"
    recorded = Task.normalize_reviewers(event.metadata["reviewers"]).map { |r| r["slug"] }
    assert_equal preview, recorded,
      "the recorded reviewers must match the CLI preview for the same task (no divergence)"
  end

  # --- Mascot backfill (for tasks created before the feature shipped) ---
  #
  # Backfill is global, so the loaded task fixtures are also live + mascotless and
  # get filled too. Tests assert on relative counts + the specific tasks they
  # create, and seed enough Pokémon that no draw falls back to a duplicate.

  def seed_backfill_deck(spare = 3)
    (Task.live.count + spare).times do |i|
      Pokemon.create!(dex: 700 + i, name: "Mon#{i}", slug: "mon-#{i}", generation: 1)
    end
  end

  test "backfill_mascots! fills every live mascotless task with distinct picks and returns the count" do
    a = Task.create!(title: "Backfill task one here")
    b = Task.create!(title: "Backfill task two here")
    [a, b].each { |t| t.update_column(:metadata, {}) }
    seed_backfill_deck

    blank_before = Task.live.count { |t| t.devops["mascot"].blank? }
    count = Task.backfill_mascots!

    assert_equal blank_before, count
    assert_equal 0, Task.live.count { |t| t.devops["mascot"].blank? }, "no live task left mascotless"
    assert a.reload.devops["mascot"].present?
    assert b.reload.devops["mascot"].present?
    assert_not_equal a.devops["mascot"], b.devops["mascot"], "live tasks get distinct mascots"
  end

  test "backfill_mascots! is idempotent — a second run assigns nothing" do
    task = Task.create!(title: "Idempotent backfill task here")
    task.update_column(:metadata, {})
    seed_backfill_deck

    Task.backfill_mascots!
    assert task.reload.devops["mascot"].present?
    assert_equal 0, Task.backfill_mascots!, "a second run assigns nothing"
  end

  test "backfill_mascots! leaves an existing mascot untouched" do
    seed_pokemon("snorlax")
    task = Task.create!(title: "Already has a mascot",
                        metadata: { "devops" => { "mascot" => "ditto" } })

    Task.backfill_mascots!

    assert_equal "ditto", task.reload.devops["mascot"]
  end

  test "backfill_mascots! skips terminal (shipped/archived) tasks" do
    seed_backfill_deck
    shipped = Task.create!(title: "Shipped terminal backfill task")
    shipped.update_columns(stage: "shipped", metadata: {})

    Task.backfill_mascots!

    assert_nil shipped.reload.devops["mascot"], "terminal tasks are not backfilled"
  end

  test "backfill_mascots! captures a failed row to ErrorLog and continues" do
    good = Task.create!(title: "Good backfill task here")
    bad  = Task.create!(title: "Bad backfill task here")
    good.update_column(:metadata, {})
    bad.update_columns(metadata: {}, priority: 99) # invalid priority → update! raises
    seed_backfill_deck
    errors_before = ErrorLog.count

    assert_nothing_raised { Task.backfill_mascots! }

    assert good.reload.devops["mascot"].present?, "the healthy task is still backfilled"
    assert_nil bad.reload.devops["mascot"], "the failing task is skipped, not aborted"
    assert_equal errors_before + 1, ErrorLog.count, "the failure is captured to ErrorLog"
    assert_equal bad.slug, ErrorLog.last.target_name
  end

  # --- per-session mascot -----------------------------------------------------

  test "tasks from the same session share one mascot" do
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", generation: 1)
    Pokemon.create!(dex: 4, name: "Charmander", slug: "charmander", generation: 1)
    a = Task.create!(title: "session mascot a", metadata: { "devops" => { "session_id" => "sess-X" } })
    b = Task.create!(title: "session mascot b", metadata: { "devops" => { "session_id" => "sess-X" } })

    assert a.devops["mascot"].present?
    assert_equal a.devops["mascot"], b.devops["mascot"], "same session → same Pokémon"
  end

  test "a task picked up by a different session swaps its mascot on a build transition" do
    3.times { |i| Pokemon.create!(dex: i + 1, name: "Mon#{i}", slug: "mon#{i}", generation: 1) }
    t = Task.create!(title: "handoff new session task", stage: "building",
                     metadata: { "devops" => { "session_id" => "sess-A" } })
    first = t.devops["mascot"]
    assert first.present?

    # another agent claims it (new session) and makes a build-phase move
    t.update!(stage: "submitted", metadata: t.metadata.deep_merge("devops" => { "session_id" => "sess-B" }))

    assert_not_equal first, t.reload.devops["mascot"], "new session → new Pokémon"
  end

  test "a session-less task still gets a one-off mascot" do
    Pokemon.create!(dex: 1, name: "Bulbasaur", slug: "bulbasaur", generation: 1)
    assert Task.create!(title: "no session task").devops["mascot"].present?
  end

  test "resync_session_mascots! collapses a session's tasks onto one Pokemon" do
    3.times { |i| Pokemon.create!(dex: i + 1, name: "M#{i}", slug: "m#{i}", generation: 1) }
    a = Task.create!(title: "old session task a", metadata: { "devops" => { "session_id" => "S" } })
    b = Task.create!(title: "old session task b", metadata: { "devops" => { "session_id" => "S" } })
    # force the OLD per-task world: same session, DIFFERENT mascots, no session tag
    a.update_columns(metadata: { "devops" => { "session_id" => "S", "mascot" => "m0" } })
    b.update_columns(metadata: { "devops" => { "session_id" => "S", "mascot" => "m1" } })

    Task.resync_session_mascots!

    assert_equal a.reload.devops["mascot"], b.reload.devops["mascot"], "one mascot per session"
  end

  test "the same session keeps its mascot across a build transition" do
    # Regression: mascot_session was stripped by normalize_devops_metadata, so every
    # build transition re-rolled the Pokémon (designed→building showed a different one).
    3.times { |i| Pokemon.create!(dex: i + 1, name: "P#{i}", slug: "p#{i}", generation: 1) }
    t = Task.create!(title: "stable session mascot task",
                     metadata: { "devops" => { "session_id" => "sess-stable" } })
    first = t.devops["mascot"]
    assert first.present?
    assert_equal "sess-stable", t.devops["mascot_session"], "mascot_session must survive the save"

    t.update!(stage: "building") # same session, build transition — must NOT re-roll

    assert_equal first, t.reload.devops["mascot"], "same session keeps one Pokémon across designed→building"
  end

  test "normalize_devops_metadata keeps the mascot_session tag" do
    # The actual stripping point (the API path normalizes; the model alone does not):
    # mascot_session was dropped here, so the saved task lost it and every transition
    # re-rolled. It must survive normalization.
    result = Task.normalize_devops_metadata("mascot" => "graveler", "mascot_session" => "sess-1")

    assert_equal "graveler", result["mascot"]
    assert_equal "sess-1", result["mascot_session"], "mascot_session must survive normalization"
  end

  # --- Auto-derived actual_size (the measured leg of the size trio) -----------

  # Stamp `count` measured tokens onto a task as a single TaskEvent (split across
  # in/out so tokens_total sums them). update_column avoids re-triggering callbacks.
  def stamp_tokens(task, count)
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current,
                             tokens_in: count / 2, tokens_out: count - (count / 2))
  end

  # Stamp `dollars` measured cost onto a task as a single TaskEvent — the size
  # signal behind #derive_actual_size (which now buckets on $cost, not tokens).
  def stamp_cost(task, dollars)
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current, cost: dollars)
  end

  test "derive_actual_size maps total cost through the threshold map" do
    cases = {
      BigDecimal("5")      => "small",  # < $10
      BigDecimal("9.99")   => "small",  # just under the small ceiling
      BigDecimal("10")     => "medium", # the small ceiling is EXCLUSIVE → medium
      BigDecimal("49.99")  => "medium", # just under the medium ceiling
      BigDecimal("50")     => "large",  # the medium ceiling is EXCLUSIVE → large
      BigDecimal("199.99") => "large",  # just under the large ceiling
      BigDecimal("200")    => "xl",     # the large ceiling is EXCLUSIVE → xl
      BigDecimal("491")    => "xl"      # well into xl
    }
    cases.each do |cost, expected|
      task = Task.create!(title: "size boundary task #{cost}", stage: "building")
      stamp_cost(task, cost)
      assert_equal expected, task.derive_actual_size, "$#{cost} → #{expected}"
    end
  end

  test "derive_actual_size is nil with no measured cost (honest, not small)" do
    task = Task.create!(title: "no usage size task", stage: "building")
    # The genesis event carries no cost, so the measured total is zero.
    assert task.total_cost.zero?
    assert_nil task.derive_actual_size, "zero measured cost can't be sized → nil, never a false 'small'"
  end

  test "measured_tokens_total sums tokens_total across all events" do
    task = Task.create!(title: "token sum task", stage: "building")
    stamp_tokens(task, 2_000_000)
    stamp_tokens(task, 3_000_000)
    assert_equal 5_000_000, task.measured_tokens_total
  end

  # --- total_cost (the release-notes card $cost) ------------------------------

  test "total_cost sums the cost across all events, ignoring nil costs" do
    task = Task.create!(title: "cost sum task here", stage: "building")
    # The genesis event carries no cost (nil) — SQL SUM must skip it.
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current, cost: BigDecimal("0.50"))
    task.task_events.create!(to_stage: task.stage, occurred_at: Time.current, cost: BigDecimal("0.37"))

    assert_equal BigDecimal("0.87"), task.total_cost
  end

  test "total_cost is zero for a task with no priced events" do
    task = Task.create!(title: "zero cost task here", stage: "building")
    # Only the (cost-less) genesis event exists.
    assert task.total_cost.zero?, "an unpriced task totals zero, not nil"
  end

  test "shipping auto-derives actual_size from measured cost when blank" do
    task = Task.create!(title: "ship derives size task", stage: "assembled")
    stamp_cost(task, BigDecimal("75")) # → large ($50-$200)
    assert_nil task.actual_size

    task.ship!

    assert_equal "large", task.reload.actual_size, "ship stamps the measured size onto a blank actual_size"
  end

  test "shipping never clobbers a manually set actual_size" do
    task = Task.create!(title: "manual size wins task", stage: "assembled", actual_size: "small")
    stamp_cost(task, BigDecimal("491")) # would derive xl

    task.ship!

    assert_equal "small", task.reload.actual_size, "a manual size is never overwritten by the auto-derivation"
  end

  test "[integration] ship persists a cost-derived actual_size that round-trips through the DB" do
    task = Task.create!(title: "e2e cost sizing task", stage: "assembled")
    # Real ingestion writes cost onto TaskEvents; three stage moves total $120 → large.
    stamp_cost(task, BigDecimal("40"))
    stamp_cost(task, BigDecimal("55"))
    stamp_cost(task, BigDecimal("25"))
    assert_nil task.actual_size

    task.ship!

    reloaded = Task.find(task.id)
    assert_equal BigDecimal("120"), reloaded.total_cost, "total_cost sums the TaskEvent costs in SQL"
    assert_equal "large", reloaded.actual_size, "actual_size = cost bucket ($120 → large), persisted"
  end

  test "shipping with no measured usage leaves actual_size blank" do
    task = Task.create!(title: "ship no usage task", stage: "assembled")

    task.ship!

    assert_nil task.reload.actual_size, "no usage → no size; the ship still completes"
  end

  test "actual_size is only derived at shipped, not earlier stages" do
    task = Task.create!(title: "size only at ship task", stage: "building")
    stamp_tokens(task, 6_000_000)

    task.update!(stage: "submitted")

    assert_nil task.reload.actual_size, "a non-ship transition must not stamp actual_size"
  end

  # --- block_state: the cleared-block re-review tri-state ---

  def block_state_task(stage:)
    Task.create!(title: "block state #{stage} #{SecureRandom.hex(3)}", stage: stage)
  end

  def qa_block(task, description: "please fix it")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: description)
  end

  def resolve_block(task, description: "fixed it")
    Activity.create!(task_slug: task.slug, activity_type: "handoff", description: description,
                     metadata: { "resolves_feedback" => true })
  end

  test "block_state is :never and ever_blocked? false for a task never blocked" do
    task = block_state_task(stage: "submitted")
    assert_not task.ever_blocked?
    assert_equal :never, task.block_state
  end

  test "block_state is :blocked while a qa_feedback is unresolved" do
    task = block_state_task(stage: "submitted")
    qa_block(task)
    assert task.ever_blocked?
    assert_equal :blocked, task.block_state
  end

  test "block_state is :blocked for a live block even with no open feedback" do
    task = block_state_task(stage: "building")
    task.block!(by: "avi", kind: "rework")
    assert task.blocked?
    assert_equal :blocked, task.block_state
  end

  test "block_state is :cleared once a block is resolved and it is back in submitted" do
    task = block_state_task(stage: "submitted")
    qa_block(task)
    resolve_block(task)
    assert_not task.unresolved_feedback?
    assert task.ever_blocked?
    assert_equal :cleared, task.block_state
  end

  test "block_state clears to :never once a cleared task advances past submitted" do
    task = block_state_task(stage: "reviewed")
    qa_block(task)
    resolve_block(task)
    assert task.ever_blocked?, "history still shows a past block"
    assert_equal :never, task.block_state,
      "the amber re-review state only holds while awaiting re-review in submitted"
  end

  test "block_state honors preloaded unresolved/ever_blocked hints (no query)" do
    task = block_state_task(stage: "submitted") # no activities at all
    assert_equal :cleared, task.block_state(unresolved: false, ever_blocked: true)
    assert_equal :blocked, task.block_state(unresolved: true, ever_blocked: false)
    assert_equal :never, task.block_state(unresolved: false, ever_blocked: false)
  end

  # --- merged: the git-location field (crash-recovery for the deploy heartbeats) ---

  test "[unit] merged accepts nil + the known git locations, rejects anything else" do
    task = Task.create!(title: "merged validation task")
    [nil, Task::MERGED_ACCEPTED, Task::MERGED_RELEASE, Task::MERGED_MAIN].each do |value|
      task.merged = value
      assert task.valid?, "merged=#{value.inspect} should be valid"
    end
    task.merged = "somewhere-else"
    assert_not task.valid?, "an unknown merged location must be a hard error"
    assert_includes task.errors[:merged].to_s, "is not included"
  end

  # The accepted-ladder's first rung: review stamps merged:"accepted" when it lands a
  # feat PR on `accepted`. It MUST be a legal value (the whole ladder rests on it),
  # and it is the constant the sweep's promotion keys on.
  test "[unit] merged:accepted is a legal git-location (the accepted-ladder's first rung)" do
    assert_equal "accepted", Task::MERGED_ACCEPTED
    assert_includes Task::MERGED_STATES, Task::MERGED_ACCEPTED
    task = Task.create!(title: "accepted stamp task", stage: "reviewed", merged: Task::MERGED_ACCEPTED)
    assert task.valid?
    assert_equal "accepted", task.reload.merged
  end

  test "[unit] ship! stamps merged=main alongside the shipped stage" do
    task = Task.create!(title: "ship stamps merged task", stage: "assembled",
                        merged: Task::MERGED_RELEASE)
    task.ship!
    assert_equal "shipped", task.reload.stage
    assert_equal Task::MERGED_MAIN, task.merged
  end

  # --- WIP (the DevOps card's tile) ---

  # The operator's definition: designed + building + submitted + reviewed +
  # assembled. Asserted one stage at a time from an EMPTY board, so the test names
  # each stage's own contribution instead of trusting one lump total — a stage
  # silently dropped from the count fails here with its own name.
  test "[unit] wip_count counts each of the five in-flight stages" do
    Task.delete_all

    %w[designed building submitted reviewed assembled].each_with_index do |stage, i|
      Task.create!(title: "wip #{stage} task", stage: stage)
      assert_equal i + 1, Task.wip_count, "a #{stage} task must count toward WIP"
    end
  end

  # The other half of the contract: the two terminal stages are DONE, not WIP.
  # Advancing a counted task must DECREMENT the number (the advance, not just the
  # end state) — a wip_count that ignored `stage` entirely would still pass a
  # "shipped tasks are excluded" test that only ever checked a static board.
  test "[unit] wip_count excludes the terminal stages, and shipping decrements it" do
    Task.delete_all
    task = Task.create!(title: "wip advancing task", stage: "assembled")
    Task.create!(title: "wip resting task", stage: "shipped")
    Task.create!(title: "wip filed task", stage: "archived")

    assert_equal 1, Task.wip_count, "only the assembled task is in flight"

    task.update!(stage: "shipped")
    assert_equal 0, Task.wip_count, "shipping the last live task empties WIP"
  end

  # A blocked task is a `building` task carrying a block marker, not a stage of its
  # own — so it is still open work and must stay in the count. This is the case an
  # `stage NOT IN (shipped, archived)` count gets right and a hand-rolled
  # "count the happy path" one gets wrong.
  test "[unit] wip_count keeps blocked tasks — a block means more building to do" do
    Task.delete_all
    blocked = Task.create!(title: "wip blocked task", stage: "building",
                           blocked_at: Time.current, blocked_from: "submitted",
                           blocked_by: "avi", block_kind: "rework")

    assert blocked.blocked?, "fixture guard: the task must actually read as blocked"
    assert_equal 1, Task.wip_count
  end

  # WIP is the pipeline's number, so it must agree with `live` BY CONSTRUCTION —
  # the card and the mascot deck read the same set. Pinned so a future edit that
  # forks a second stage list here fails instead of quietly drifting.
  test "[unit] wip_count is the live scope's count" do
    Task.delete_all
    %w[designed building submitted reviewed assembled shipped archived].each do |stage|
      Task.create!(title: "wip parity #{stage} task", stage: stage)
    end

    assert_equal Task.live.count, Task.wip_count
    assert_equal 5, Task.wip_count
  end
end
