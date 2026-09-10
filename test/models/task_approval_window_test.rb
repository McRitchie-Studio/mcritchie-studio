require "test_helper"

# [unit] THE OPERATOR-APPROVAL REQUEST WINDOW — which stages a `waiting` request may
# live in, and what happens at the boundary where it stops being actionable.
#
# Split out of test/models/task_test.rb on 2026-09-09, when that file's
# config/test_health.yml ceiling (2266) refused the cases below. This is the split
# the ceiling asks for: the window is one coherent property with its own boundary,
# and it needs nothing from task_test.rb's harness.
#
# THE RULE. Task::APPROVAL_REQUEST_STAGES is an ALLOW-list of the stages where the
# LOCAL DEMO a request points at can still be served — `designed`, `building` and
# `submitted`. Outside it, Task#settle_operator_approval_past_request_window resolves
# a `waiting` request to `none` on EVERY save. It is a stage INVARIANT, not a
# transition event; the three leaks that shape had are at the bottom of this file.
#
# THE SEAM MOVED on 2026-09-09, from the `submitted` boundary to the `reviewed` one.
# `bin/ship`'s handoff was discarding requests the documented build flow told builders
# to set — three times in one night, on turf PRs 644, 647 and 653. The window now
# matches the artifact: a desk is reclaimable once the work merges, which is exactly
# `reviewed`. The end-to-end half of that regression, driven through the real PATCH
# `bin/ship` issues, is test/integration/ship_preserves_approval_request_test.rb.
class TaskApprovalWindowTest < ActiveSupport::TestCase
  test "[unit] submitting from building carries a waiting approval into review" do
    # THE REGRESSION for the defect measured three times on 2026-09-09 (turf PRs
    # 644, 647, 653). `submitted` is inside APPROVAL_REQUEST_STAGES, so the handoff
    # move carries the request rather than discarding it, and the card keeps
    # pulsing — in the review column instead of nowhere.
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
    assert_equal "waiting", task.approval_status,
      "the handoff must not discard a request the operator was asked to act on"
    assert task.waiting_for_operator_approval?, "so the board still pulses"
    assert_nil task.devops["approval_request_dropped_at"],
      "and nothing was dropped, so no receipt may be stamped"
    # The original request timestamp is preserved; no approval was granted.
    assert_equal requested_at, task.devops["approval_requested_at"]
    assert_nil task.devops["approval_approved_at"]
  end

  test "[unit] reviewing a submitted task settles waiting approval to none" do
    # The seam itself, at its new home. Review merges the PR onto `accepted` and
    # moves the task to `reviewed`; the desk serving the local demo is reclaimable
    # from that moment, so the request points at nothing and the badge drops —
    # settled to "none", NOT self-approved (no fabricated operator grant).
    task = Task.create!(
      title: "Approval Exit Review",
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
    task.review!

    task.reload
    assert_equal "reviewed", task.stage
    assert_equal "none", task.approval_status
    assert_not task.waiting_for_operator_approval?
    assert_equal requested_at, task.devops["approval_requested_at"]
    assert_nil task.devops["approval_approved_at"]
  end

  test "[unit] jumping straight from designed past the window also settles waiting approval" do
    # The old build-exit callback only fired when LEAVING `building`; a
    # designed→(past the window) jump stranded the WAITING APPROVAL badge. The
    # settle is a stage INVARIANT, so it covers that path too — from any origin.
    task = Task.create!(
      title: "Approval Skip Building",
      stage: "designed",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    task.review!

    task.reload
    assert_equal "reviewed", task.stage
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
    # Only the "waiting" request is ever settled; changes_requested carries its
    # own meaning into review and must survive every transition untouched.
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

  test "[unit] settling waiting past the window is idempotent across a block/resubmit cycle" do
    task = Task.create!(
      title: "Approval Resettle On Resubmit",
      stage: "building",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    task.submit!
    task.review!
    assert_equal "none", task.reload.approval_status

    # QA rework sends it back to building; the demo is re-flagged waiting, then resubmitted.
    task.block!(by: "avi", kind: "rework")
    md = task.metadata.deep_dup
    md["devops"]["approval_status"] = "waiting"
    task.update!(metadata: md)
    task.submit!
    task.review!

    assert_equal "none", task.reload.approval_status, "re-entering reviewed settles again, no-op-safe"
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] an agent-sourced merge settles waiting without tripping the operator guard" do
    task = Task.create!(
      title: "Approval Agent Submit",
      stage: "submitted",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    Current.task_event_source = "cli" # the bin/task agent lane, normally barred from granting approval
    assert_nothing_raised { task.review! }

    task.reload
    assert_equal "none", task.approval_status, "the system settle resolves to the agent-writable none"
    assert_nil task.devops["approval_approved_at"], "no operator grant is fabricated"
  ensure
    Current.reset
  end

  test "[unit] creating straight past the window settles the request too" do
    # The settle is a stage INVARIANT, not a transition event, so it holds on
    # create as well: a row born past the window cannot carry a badge that nothing
    # in the pipeline will clear.
    task = Task.create!(
      title: "Approval Born Reviewed",
      stage: "reviewed",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    assert_equal "none", task.reload.approval_status
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] creating straight into submitted keeps the request live" do
    # The other side of the same invariant, and the one the 2026-09-09 fix turns
    # on: `submitted` is INSIDE the window, so a row born there — a ship that
    # creates and hands off in one motion — keeps a badge review can still act on.
    task = Task.create!(
      title: "Approval Born Submitted",
      stage: "submitted",
      metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } }
    )

    assert_equal "waiting", task.reload.approval_status
    assert task.waiting_for_operator_approval?
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
    task.review!
    assert_equal "none", task.reload.approval_status

    task.update!(metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3021/tasks" } })

    assert_equal "none", task.reload.approval_status,
      "a stale devops echo must not resurrect a request the seam already settled"
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] flagging approval AFTER the window settles immediately" do
    # Leak 2: there was no move left to settle it, so it stuck forever.
    task = Task.create!(title: "Approval Late Flag", stage: "building")
    task.submit!
    task.review!

    metadata = task.metadata.deep_dup
    (metadata["devops"] ||= {})["approval_status"] = "waiting"
    task.update!(metadata: metadata)

    assert_equal "none", task.reload.approval_status
    assert_not task.waiting_for_operator_approval?
  end

  test "[unit] a waiting request cannot ride a later stage move to shipped" do
    # Leak 3: reviewed / assembled / shipped were not the submitted transition,
    # so a restored request rode the whole pipeline. Force one in past the window
    # (update_column skips the invariant) and assert every later stage clears it.
    # Unchanged by the 2026-09-09 seam move: every stage below is still outside
    # APPROVAL_REQUEST_STAGES, which is what keeps this leak closed.
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
    #
    # `submitted` LEFT this list on 2026-09-09. It reads on the "survives" side
    # below now, because a request there is live rather than stranded — the sweep
    # takes only rows outside APPROVAL_REQUEST_STAGES, and taking a live one would
    # silently un-ask a question the operator has not answered.
    stranded = %w[reviewed assembled shipped archived].map do |stage|
      task = Task.create!(title: "Stranded #{stage.capitalize} Badge", stage: stage)
      forced = task.metadata.deep_dup
      (forced["devops"] ||= {})["approval_status"] = "waiting"
      task.update_column(:metadata, forced)
      task
    end
    live = %w[designed building submitted].map do |stage|
      Task.create!(title: "Live Waiting #{stage.capitalize}", stage: stage,
                   metadata: { "devops" => { "approval_status" => "waiting" } })
    end

    settled = Task.settle_stale_operator_approvals!

    assert_equal stranded.map(&:slug).sort, settled.sort
    stranded.each { |task| assert_equal "none", task.reload.approval_status }
    live.each do |task|
      assert_equal "waiting", task.reload.approval_status,
        "#{task.stage}: a request in a stage that can still act on it must survive the sweep"
    end

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
end
