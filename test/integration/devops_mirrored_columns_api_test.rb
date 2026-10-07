# frozen_string_literal: true

require "test_helper"

# [integration] The mirrored devops columns through the route bin/task and bin/submit
# call: a devops write lands in the column, the payload keeps both field shapes,
# and an invalid approval_status answers 422, never 500.
class DevopsMirroredColumnsApiTest < ActionDispatch::IntegrationTest
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/6161"

  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)

  def headers = { "Authorization" => "Bearer #{token}" }

  def task
    @task ||= Task.create!(title: "Mirrored Columns Api Row", stage: "building",
                           metadata: { "devops" => { "kind" => "feature" } })
  end

  test "a devops write lands in the column and both payload shapes answer" do
    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { pr_url: PR_URL, approval_status: "waiting", session_id: "sess-api" } },
          headers: headers, as: :json

    assert_response :success
    assert_equal PR_URL, task.reload.read_attribute(:pr_url)
    assert_equal "waiting", task.read_attribute(:approval_status)

    get "/api/v1/tasks/#{task.slug}", headers: headers
    data = JSON.parse(response.body)["data"]
    assert_equal PR_URL, data.dig("metadata", "devops", "pr_url"), "bin/task reads the devops key first"
    assert_equal PR_URL, data["pr_url"]
    assert_equal "waiting", data["approval_status"]
    assert_equal "sess-api", data["session_id"]
  end

  test "an invalid approval_status answers 422 and stores nothing" do
    patch "/api/v1/tasks/#{task.slug}", params: { devops: { approval_status: "maybe" } },
                                        headers: headers, as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"].to_s, "must be one of"
    assert_nil task.reload.approval_status
  end
end
