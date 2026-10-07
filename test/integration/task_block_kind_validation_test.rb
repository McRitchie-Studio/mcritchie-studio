# frozen_string_literal: true

require "test_helper"

# Task::BLOCK_KINDS is the one copy of the block kinds. bin/task sends `--kind` as
# typed and the model refuses a kind it does not know, so the CLI and the board
# cannot disagree about the list.
class TaskBlockKindValidationTest < ActionDispatch::IntegrationTest
  setup do
    @task = tasks(:new_task)
    @headers = {
      "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}"
    }
  end

  test "[unit] block! stamps every declared kind" do
    Task::BLOCK_KINDS.each do |kind|
      @task.block!(by: "carl", kind: kind)

      assert_equal kind, @task.reload.block_kind
      @task.unblock!
    end
  end

  test "[unit] block! refuses a kind the model does not declare and stamps nothing" do
    error = assert_raises(ActiveRecord::RecordInvalid) { @task.block!(by: "carl", kind: "bogus") }

    assert_match(/Block kind must be one of #{Task::BLOCK_KINDS.join(", ")}/, error.message)
    assert_nil @task.reload.blocked_at, "a refused block lands nothing"
  end

  test "[unit] a row already holding an unknown kind still saves untouched" do
    @task.update_columns(block_kind: "legacy-kind", blocked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

    assert @task.reload.update(priority: 1), "the validation is gated on a change to block_kind"
  end

  test "[integration] the block endpoint answers an unknown kind with a 422 naming the list" do
    patch block_api_v1_task_path(@task.slug), params: { kind: "bogus", by: "carl" }, headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_match(/must be one of environment, rework, dependency/, response.parsed_body["error"].to_s)
    assert_nil @task.reload.blocked_at
  end

  test "[integration] the block endpoint stamps a declared kind" do
    patch block_api_v1_task_path(@task.slug), params: { kind: "dependency", by: "carl" }, headers: @headers, as: :json

    assert_response :success
    assert_equal "dependency", @task.reload.block_kind
  end

  # Guard catalog row 4.2, scoped by decision 6: `bin/task begin` on a REWORK-blocked
  # task clears the block at the claim. Every other block waits on something outside
  # the desk, and an `Escalated:` block waits on Alex, so the endpoint refuses those 409.
  def block_with(kind:, summary:)
    @task.block!(by: "carl", kind: kind)
    Activity.create!(task_slug: @task.slug, activity_type: "qa_feedback", agent_slug: "carl",
                     description: "send-back", metadata: { "summary" => summary, "kind" => kind })
    assert @task.reload.blocked?, "FLOOR: the task must start blocked"
  end

  def unblock(by: "pokemon")
    patch unblock_api_v1_task_path(@task.slug), params: { by: by }.compact, headers: @headers, as: :json
  end

  test "[integration] the unblock endpoint clears a rework block and records who cleared it" do
    block_with(kind: "rework", summary: "fix the failing check")

    assert_difference -> { Activity.where(task_slug: @task.slug, activity_type: "comment").count }, 1 do
      unblock
    end

    assert_response :success
    @task.reload
    refute @task.blocked?
    assert_equal "building", @task.stage
    audit = Activity.where(task_slug: @task.slug, activity_type: "comment").order(:created_at).last
    assert_equal "block_cleared", audit.metadata["kind"]
    assert_equal "pokemon", audit.metadata["cleared_by"]
    assert_equal "rework", audit.metadata["block_kind"]
    assert_equal "carl", audit.metadata["blocked_by"]
    assert_includes audit.description, "pokemon cleared the rework block from carl"
  end

  test "[integration] the unblock endpoint refuses an escalated block with a 409 and keeps it" do
    block_with(kind: "dependency", summary: "Escalated: repeat review bounce")

    assert_no_difference -> { Activity.count } do
      unblock
    end

    assert_response :conflict
    assert_equal "UNBLOCK_REFUSED", response.parsed_body["error_code"]
    assert @task.reload.blocked?, "an escalation waits on Alex; a builder's begin never clears it"
    refute_empty @task.operator_windows, "the escalation window must still be open"
  end

  test "[integration] the unblock endpoint refuses a rework block whose summary is an escalation" do
    block_with(kind: "rework", summary: "Escalated: scope disagreement")

    unblock

    assert_response :conflict
    assert_match(/only Alex answers/, response.parsed_body["error"].to_s)
    assert @task.reload.blocked?
  end

  test "[integration] the unblock endpoint refuses an environment block" do
    block_with(kind: "environment", summary: "Heroku CI is down")

    unblock

    assert_response :conflict
    assert_match(/environment block/, response.parsed_body["error"].to_s)
    assert @task.reload.blocked?
  end

  test "[integration] the unblock endpoint refuses a plain dependency block" do
    block_with(kind: "dependency", summary: "waits on studio-engine 0.92")

    unblock

    assert_response :conflict
    assert_match(/dependency block/, response.parsed_body["error"].to_s)
    assert @task.reload.blocked?
  end

  test "[integration] the unblock endpoint needs a by" do
    block_with(kind: "rework", summary: "fix it")

    unblock(by: nil)

    assert_response :unprocessable_entity
    assert @task.reload.blocked?
  end

  # The control: no live block answers 200 and writes nothing.
  test "[integration] the unblock endpoint answers 200 on a task with no live block" do
    assert_no_difference -> { Activity.count } do
      unblock
    end

    assert_response :success
    assert_nil @task.reload.blocked_at
  end
end
