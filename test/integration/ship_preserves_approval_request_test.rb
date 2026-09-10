require "test_helper"

# [integration] `bin/ship` must not discard a pending operator-approval request.
#
# THE DEFECT, measured THREE TIMES IN ONE NIGHT on 2026-09-09 — turf PRs 644 (a
# P1), 647 and 653. In each case a builder followed the documented build flow
# exactly:
#
#   bin/task update <slug> --local-url http://localhost:<port>/<path> --approval waiting
#   bin/ship <slug> -m "..."
#
# ...and `bin/ship`'s step 8/8 — which is literally `bin/task move <slug>
# submitted`, bin/ship:783 — settled the request to "none" on the way through. Ship
# said so out loud (the drop warning added on 2026-09-08), so this was never a
# silence bug. It was the two halves of the fast lane disagreeing: the documented
# flow says ASK BEFORE THE PR, and the documented handoff threw the request away.
# Following the docs produced the discard every time.
#
# WHY IT COST SOMETHING. A waiting request floats the card to the top of its column
# (Task.ordered) and pulses it (#waiting_for_operator_approval?). That is the ONLY
# mechanism in the system that asks for Mr. McRitchie's attention. Discarding it
# means a builder who correctly asked for a human look got none — on PR 644 the
# unlooked-at change was user-facing copy on a money page, shown after a wallet
# signature.
#
# THE FIX is one stage: `submitted` joined Task::APPROVAL_REQUEST_STAGES, moving the
# settle seam from the `submitted` boundary to the `reviewed` one. The window now
# matches the artifact — a request says "open this local URL", that URL is served by
# the task's desk, and a desk is reclaimable once the work merges, which is exactly
# `reviewed`.
#
# WHAT THIS FILE ASSERTS, and it is the PERSISTED FIELD, never the warning string:
# a test that only checked the message would have passed against the shipped defect,
# which printed a perfectly accurate warning about a request it was destroying.
class ShipPreservesApprovalRequestTest < ActionDispatch::IntegrationTest
  LOCAL_URL = "http://localhost:3021/contests/demo".freeze

  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  def auth = { "Authorization" => "Bearer #{token}" }

  def building_task(devops = {})
    Task.create!(title: "Ship Keeps Approval Row", stage: "building",
                 metadata: { "devops" => { "kind" => "bug" }.merge(devops) })
  end

  # Exactly what `bin/task update <slug> --local-url U --approval waiting` sends.
  def request_approval!(task)
    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { approval_status: "waiting", local_url: LOCAL_URL } },
          headers: auth, as: :json
  end

  # Exactly what `bin/ship` step 8/8 sends — it shells out to `bin/task move <slug>
  # submitted`, which PATCHes the stage with a "cli"-sourced event and NO devops
  # (the whole-hash echo happens only on a move to `building`, bin/task:2871).
  def ship_handoff!(task)
    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "submitted", event: { source: "cli" } },
          headers: auth, as: :json
  end

  # And what review sends when it merges the feat PR onto `accepted`.
  def review_merge!(task)
    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "reviewed", event: { source: "cli" } },
          headers: auth, as: :json
  end

  # --- THE REGRESSION ---

  test "the ship handoff leaves a pending approval request PERSISTED as waiting" do
    task = building_task

    request_approval!(task)
    assert_response :success
    assert_equal "waiting", task.reload.approval_status, "precondition: the request landed at building"

    ship_handoff!(task)

    assert_response :success
    task.reload
    assert_equal "submitted", task.stage, "the handoff still advances the task"
    # THE ASSERTION THE WHOLE FILE EXISTS FOR. Read off the reloaded record, not off
    # the response body and not off any warning text.
    assert_equal "waiting", task.approval_status,
                 "bin/ship must carry the request into review, not discard it"
    assert task.waiting_for_operator_approval?, "so the card still pulses"
    assert_equal LOCAL_URL, task.devops["local_url"],
                 "and the page the operator is being asked to open is still on the record"
  end

  test "a handoff that discards nothing stamps no drop receipt" do
    # The receipt is what `bin/task move`'s warning compares across the PATCH. If the
    # handoff stopped dropping the request but still stamped a drop, every ship would
    # announce a discard that did not happen — and a warning readers learn to skip is
    # the defect the warning was written to prevent.
    task = building_task
    request_approval!(task)

    ship_handoff!(task)

    assert_nil task.reload.devops["approval_request_dropped_at"],
               "nothing was dropped, so nothing may be receipted"
  end

  test "the preserved request floats the card to the top of the review column" do
    # The float and the pulse are the mechanism; preserving the field is only worth
    # something because Task.ordered ranks on it, and it does so with no stage
    # condition at all — which is why honouring a request at `submitted` needed no
    # board change. Two later-positioned tasks so a bare `position DESC` order would
    # put the asking card last.
    asking = building_task
    request_approval!(asking)
    ship_handoff!(asking)

    quiet_one = Task.create!(title: "Ship Quiet Row One", stage: "submitted")
    quiet_two = Task.create!(title: "Ship Quiet Row Two", stage: "submitted")

    ranked = Task.where(stage: "submitted").ordered.to_a

    assert_operator ranked.index(asking), :<, ranked.index(quiet_one),
                    "a waiting request must outrank a newer card in the same column"
    assert_operator ranked.index(asking), :<, ranked.index(quiet_two)
    assert_equal asking, ranked.first, "and it sits at the top, where the operator looks"
  end

  # --- the seam still exists; it just moved one stage later ---

  test "the merge to reviewed settles the carried request and receipts the drop" do
    task = building_task
    request_approval!(task)
    ship_handoff!(task)

    review_merge!(task)

    assert_response :success
    task.reload
    assert_equal "reviewed", task.stage
    assert_equal "none", task.approval_status,
                 "past the window the desk is reclaimable, so the request points at nothing"
    assert_not task.waiting_for_operator_approval?
    assert task.devops["approval_request_dropped_at"].present?,
           "and the drop stays auditable at the boundary that still drops"
  end

  # --- SURFACE IT, DO NOT BLOCK (surface-waiting-request-at-merge, 2026-09-10) ---
  #
  # Mr. McRitchie's decision: review may merge while the request is still waiting,
  # and nothing refuses — but the settle is no longer silent. Driven through the
  # same three PATCHes the fast lane and review send, in the order they send them.

  test "[integration] merging over a waiting request is never refused and leaves an addressed note" do
    task = building_task("built_by" => "steffon")
    request_approval!(task)
    assert_response :success
    assert_equal "steffon", task.reload.devops["approval_requested_by"],
                 "the request names who asked, with no actor on the write"

    ship_handoff!(task)
    assert_response :success
    assert_equal "waiting", task.reload.approval_status, "it rides into review, still asking"

    # What `bin/task merged <slug> accepted` sends, then the move. Both answer 2xx:
    # a waiting request refuses NEITHER step of the merge boundary.
    patch "/api/v1/tasks/#{task.slug}", params: { merged: "accepted" }, headers: auth, as: :json
    assert_response :success, "the merged stamp is not refused"
    review_merge!(task)
    assert_response :success, "the move to reviewed is not refused"

    task.reload
    assert_equal "reviewed", task.stage
    assert_equal "none", task.approval_status

    notes = Activity.for_task(task).where("metadata->>'kind' = ?", "approval_request_unanswered").to_a
    assert_equal 1, notes.size, "the settle leaves exactly one record"
    assert_equal "steffon", notes.first.metadata["addressed_to"], "addressed to the setter, not the merger"
    assert_equal LOCAL_URL, notes.first.metadata["local_url"]
    assert_includes notes.first.description, "--approval approved", "and says how he can still answer"

    # He still can: the answer is legal past the merge, and it lands.
    patch "/api/v1/tasks/#{task.slug}", params: { devops: { approval_status: "approved" } },
                                        headers: auth, as: :json
    assert_response :success
    assert_equal "approved", task.reload.approval_status
  end

  test "the settle never fabricates an operator grant" do
    # A state-machine settle must not invent an outcome nobody chose. "approved" here
    # would misreport the operator-acceptance metric with a grant that was never given.
    task = building_task
    request_approval!(task)
    ship_handoff!(task)
    review_merge!(task)

    task.reload
    assert_equal "none", task.approval_status
    assert_nil task.devops["approval_approved_at"], "no approval window was ever closed"
  end

  # --- the request stays actionable for the whole time it is alive ---

  test "the operator's verdict is recordable while the task sits in review" do
    # The invariant behind the settle is that a waiting badge may exist only where
    # something can clear it. This is the half that makes `submitted` qualify: the
    # operator looks at the local demo and an agent records what he said, from the
    # agent lane, at the stage the card is actually sitting in.
    task = building_task
    request_approval!(task)
    ship_handoff!(task)

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { approval_status: "approved" } },
          headers: auth, as: :json

    assert_response :success
    task.reload
    assert_equal "approved", task.approval_status
    assert_not task.waiting_for_operator_approval?, "the badge clears because it was ANSWERED"
    assert task.devops["approval_approved_at"].present?, "and the acceptance window closes for real"
  end

  test "a rework bounce re-arms the request instead of losing it" do
    # `bin/task block --kind rework` parks the task on `building`, which is also
    # inside the window — so a request that survived the handoff survives the
    # send-back too and re-pulses with nobody re-asking. This is the "re-arm" shape
    # for free, on top of the request surviving the handoff in the first place.
    task = building_task
    request_approval!(task)
    ship_handoff!(task)

    # RELOAD FIRST. `block!` assigns stage: "building", and this object's in-memory
    # stage is still the "building" it was created with — Rails writes only CHANGED
    # attributes, so without the reload the stage column is left at "submitted" and
    # the stale metadata rides along with it.
    task.reload.block!(by: "carl", kind: "rework")

    task.reload
    assert_equal "building", task.stage, "a block is a building attribute"
    assert_equal "waiting", task.approval_status, "the bounce must not eat the request either"
    assert task.waiting_for_operator_approval?
  end
end
