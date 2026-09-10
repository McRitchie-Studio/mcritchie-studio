require "test_helper"

# [integration] The approval-request guard through the route `bin/task update
# --approval` actually calls.
#
# The unit matrix (test/models/task_approval_request_guard_test.rb) pins the fold.
# This file pins the thing the operator loop actually depends on: that the CLI's
# HTTP call comes back NON-2XX when the request cannot be honoured, because
# bin/task's `api` helper turns any non-2xx into `die!` — a non-zero exit. That is
# the whole remedy. A 200 here is the defect, no matter what the model does.
#
# The two rows reproduced on 2026-09-07, at the SAME stage, minutes apart:
#   --approval waiting  -> exit 0, read-back "none"      DROPPED
#   --approval approved -> exit 0, read-back "approved"  LANDED
#
# THAT STAGE WAS `submitted`, AND IT IS NO LONGER A SETTLING STAGE. On 2026-09-09
# `submitted` joined APPROVAL_REQUEST_STAGES, because the ship handoff was
# discarding requests the documented build flow told builders to set — three times
# in one night. So the refusal cases below are driven at `reviewed`, the first stage
# past the request window. The rule under test is unchanged; only the boundary it is
# evaluated at moved. The `submitted` half now lives in
# test/integration/ship_preserves_approval_request_test.rb, which asserts the
# request SURVIVES the very PATCH bin/ship issues.
class ApprovalRequestGuardApiTest < ActionDispatch::IntegrationTest
  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  # Exactly the shape `bin/task update <slug> --approval <value>` sends.
  def update_approval!(task, value, extra = {})
    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { approval_status: value }.merge(extra) },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  def task_at(stage, devops = {})
    Task.create!(title: "Approval Guard Api Row", stage: stage,
                 metadata: { "devops" => { "kind" => "bug" }.merge(devops) })
  end

  # --- ROW 1, the dropped request: must now be a LOUD refusal ---

  test "requesting approval past the request window is refused with a non-2xx" do
    task = task_at("reviewed")

    update_approval!(task, "waiting")

    assert_response :unprocessable_entity,
                    "a request that cannot be honoured must not answer 200 — bin/task exits 0 on 2xx"
    body = JSON.parse(response.body)
    assert_includes body["error"].to_s, "reviewed", "the refusal must name the stage"
    assert_includes body["error"].to_s, "waiting", "the refusal must name the value"
    assert_not task.reload.waiting_for_operator_approval?,
               "and no request is left pending — the refusal wrote nothing"
  end

  test "the refusal is not confined to one stage" do
    %w[reviewed assembled shipped archived].each do |stage|
      update_approval!(task_at(stage), "waiting")

      assert_response :unprocessable_entity, "#{stage}: every settling stage refuses the same way"
    end
  end

  # --- ROW 2, the grant: must keep working exactly as measured ---

  test "granting approval past the request window still succeeds" do
    task = task_at("reviewed")

    update_approval!(task, "approved")

    assert_response :success, "the second measured row must stay green"
    assert_equal "approved", task.reload.approval_status
  end

  # --- the stages where the request IS actionable: unchanged ---

  test "requesting approval where the operator can act still succeeds" do
    Task::APPROVAL_REQUEST_STAGES.each do |stage|
      task = task_at(stage)

      update_approval!(task, "waiting")

      assert_response :success, "#{stage}: the operator gate must still be openable"
      assert_equal "waiting", task.reload.approval_status
      assert task.reload.waiting_for_operator_approval?, "#{stage}: and the board must pulse"
    end
  end

  # --- the control the coordinator already held ---

  test "a devops write that never mentions approval is untouched past the window" do
    task = task_at("reviewed")

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { local_url: "http://localhost:3011/tasks" } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success, "this is a VALUE rule, not a stage lock on the devops blob"
    assert_equal "http://localhost:3011/tasks", task.reload.devops["local_url"]
  end

  test "a refused call lands none of its keys" do
    # bin/task takes --approval and --local-url in ONE call. The original defect's
    # worst property was the SPLIT outcome: local_url landed while the request
    # vanished, so the call looked like it worked. Failing closed means all or
    # nothing, and the caller retries the whole line.
    task = task_at("reviewed")

    update_approval!(task, "waiting", local_url: "http://localhost:3011/tasks")

    assert_response :unprocessable_entity
    task.reload
    assert_nil task.devops["local_url"], "a refused write must not half-land"
    assert_not task.waiting_for_operator_approval?
  end

  test "asking for approval on the same call that moves past the window is refused" do
    # The stage is judged where the save LANDS, not where it came from. Posting the
    # request and the move together asks for something this very save settles away,
    # so reading the STORED stage here would wave it through.
    task = task_at("submitted")

    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "reviewed", devops: { approval_status: "waiting" } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :unprocessable_entity, "the effective stage decides, not the stored one"
    assert_equal "submitted", task.reload.stage, "and the refusal takes the whole save with it"
  end

  test "asking for approval on the same call that hands off is honoured" do
    # The mirror image, and the 2026-09-09 fix seen from the effective-stage rule:
    # `submitted` is INSIDE the window, so a builder who asks and hands off in ONE
    # call gets what he asked for rather than a 422 or a silent drop.
    task = task_at("building")

    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "submitted", devops: { approval_status: "waiting" } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    task.reload
    assert_equal "submitted", task.stage
    assert_equal "waiting", task.approval_status, "the effective stage can hold the request"
  end

  # --- the internal settle keeps working: a move is not a request ---

  # "Silently" used to be this test's word for "without a 422". The settle now
  # leaves a note addressed to the setter (surface-waiting-request-at-merge), so the
  # name says only what is asserted: it settles, and the move is never refused.
  test "merging a task that carries a live request still settles and is never refused" do
    task = task_at("submitted", "approval_status" => "waiting")

    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "reviewed" },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success, "a stage move asks for nothing; it must never raise"
    assert_equal "none", task.reload.approval_status
  end
end
