# frozen_string_literal: true

require "test_helper"

# [integration] THE BOUNCE, DRIVEN THROUGH THE API THE REVIEWER ACTUALLY CALLS.
#
# The unit tier (test/models/reviewer_not_an_author_test.rb) drives the model. This
# one drives the two HTTP writes a review session really makes — `PATCH
# /api/v1/tasks/:slug/block` (bin/task block) followed by the `PATCH
# /api/v1/tasks/:slug` that bin/statusline's build-claim heartbeat fires seconds
# later — because the defect lived in the SEAM between them, not in either one.
#
# The block was always exempt from the builder stamp. The heartbeat that followed it
# was not, and nothing on the wire distinguished a lease renewal from a build claim:
# both are a devops PATCH that rewrites ClaimLease's keys. So the board recorded the
# REVIEWER's session as an unnamed author, `bin/reviewer-select` refused the next
# round, and each of four bounced tasks in one 2026-09-04 review sitting needed a
# hand-passed `--builder <soul>` to move again.
#
# BOTH SESSIONS ARE DISTINCT AND REAL HERE. A test that bounced the task from the
# builder's own session would exercise nothing: the whole mechanism keys on the
# claiming party CHANGING.
class ReviewerBounceAuthorsApiTest < ActionDispatch::IntegrationTest
  BUILDER_SESSION  = "b1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  REVIEWER_SESSION = "c2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"

  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  def auth = { "Authorization" => "Bearer #{token}" }

  def patch_task(slug, params)
    patch "/api/v1/tasks/#{slug}", params: params, headers: auth, as: :json
    assert_response :success
  end

  # `bin/task move <slug> building` — the actor names the builder, the devops slice
  # carries the lease that records WHICH session holds the desk.
  def claim!(task, actor:, session:)
    patch_task(task.slug, stage: "building", event: { actor: actor },
                          devops: ClaimLease.renewed(session: session, nonce: "inst-B"))
  end

  # `bin/task move <slug> submitted` — the mover's session is the default actor.
  def submit!(task, actor:)
    patch_task(task.slug, stage: "submitted", event: { actor: actor })
  end

  # `bin/task block <slug> --kind rework` — the dedicated block endpoint.
  def block!(task, by:)
    patch "/api/v1/tasks/#{task.slug}/block",
          params: { kind: "rework", by: by, event: { actor: by, source: "cli" } },
          headers: auth, as: :json
    assert_response :success
  end

  # `bin/task heartbeat <slug>` — a devops PATCH carrying a fresh lease and NO
  # event at all. That is the whole shape of it: a heartbeat names nobody.
  def heartbeat!(task, session:)
    devops = task.reload.metadata["devops"] || {}
    patch_task(task.slug, devops: devops.merge(
      ClaimLease.renewed(session: session, nonce: "inst-R", prior: devops)
    ))
  end

  def submitted_task(title)
    task = Task.create!(title: title, stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    claim!(task, actor: "shannon", session: BUILDER_SESSION)
    submit!(task, actor: BUILDER_SESSION)
    task.reload
  end

  test "a rework block plus the reviewer's heartbeat leaves the author set whole" do
    task = submitted_task("Bounce Author Set Api")
    TaskReviewClaim.acquire(task_slug: task.slug, session: REVIEWER_SESSION,
                            nonce: "inst-R", reviewer: "carl")

    block!(task, by: "carl")
    heartbeat!(task, session: REVIEWER_SESSION)

    devops = task.reload.metadata["devops"]
    assert_equal "shannon", devops["built_by"]
    assert_equal ["shannon"], devops["builders"]
    assert_nil devops["builders_unattributed"],
               "the reviewer bounced this task; the record must not call that authorship"
  end

  test "reviewer selection still selects after the bounce" do
    # The symptom the operator felt. `builder_known` false is the refusal.
    task = submitted_task("Bounce Selection Still Works")
    TaskReviewClaim.acquire(task_slug: task.slug, session: REVIEWER_SESSION,
                            nonce: "inst-R", reviewer: "carl")

    block!(task, by: "carl")
    heartbeat!(task, session: REVIEWER_SESSION)

    decision = ReviewerSelector.explain(task.reload)
    assert_equal true, decision["builder_known"]
    assert_equal ["shannon"], decision["builders"]
    refute_includes ReviewerSelector.select(task.reload).map { |r| r["slug"] }, "shannon",
                    "and the real author is still excluded from the seats"
  end

  test "an unnamed claim from a session that is NOT reviewing still refuses" do
    # THE FAIL-CLOSED HALF, through the same door. The refusal exists for a real
    # incomplete author set, and a fix that made selection always succeed would
    # satisfy the bug report while destroying the property.
    task = submitted_task("Bounce Failclosed Still Refuses")

    block!(task, by: "carl")
    heartbeat!(task, session: REVIEWER_SESSION)

    assert_equal REVIEWER_SESSION, task.reload.metadata.dig("devops", "builders_unattributed"),
                 "no review claim means an ordinary anonymous handoff"
    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"]
  end
end
