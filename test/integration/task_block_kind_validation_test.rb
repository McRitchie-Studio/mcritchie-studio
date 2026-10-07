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
end
