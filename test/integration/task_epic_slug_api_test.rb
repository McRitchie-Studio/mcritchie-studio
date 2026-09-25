# frozen_string_literal: true

require "test_helper"

# [integration] `tasks.epic_slug` through the JSON API — the door `bin/task
# --epic` writes through and the read the boards' `?epic=` filter shares.
#
# The property under test is that the column is reachable ONLY as a top-level
# field: written on create and PATCH, cleared by `null` or `"none"`, refused when
# it is not a slug, refused LOUDLY when posted under `devops` (the shadow store
# release_slug once diverged into), and served back on GET so a read-back can
# confirm the write landed. Its own file rather than an append to
# test/controllers/api/v1/tasks_controller_test.rb, which is a large shared
# surface; this block needs nothing from that harness beyond the bearer token.
class TaskEpicSlugApiTest < ActionDispatch::IntegrationTest
  setup do
    @task = tasks(:new_task)
    @headers = {
      "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
    }
  end

  test "[integration] create accepts epic_slug as a top-level field and returns it" do
    post api_v1_tasks_path,
         params: { title: "Epic Created Task", epic_slug: "DevOps-V3" },
         headers: @headers, as: :json

    assert_response :created
    body = response.parsed_body["data"]
    assert_equal "devops-v3", body["epic_slug"], "normalized on the way in, served back on the way out"
    assert_equal "devops-v3", Task.find_by!(slug: body["slug"]).epic_slug
    assert_nil body.dig("metadata", "devops", "epic_slug"), "the column write must not also seed a devops shadow"
  end

  test "[integration] update writes epic_slug to the column" do
    patch api_v1_task_path(@task.slug),
          params: { epic_slug: "devops-v3" },
          headers: @headers, as: :json

    assert_response :success
    assert_equal "devops-v3", @task.reload.epic_slug
    assert_equal "devops-v3", response.parsed_body["data"]["epic_slug"]
  end

  test "[integration] a JSON null clears epic_slug" do
    @task.update!(epic_slug: "devops-v3")

    patch api_v1_task_path(@task.slug),
          params: { epic_slug: nil },
          headers: @headers, as: :json

    assert_response :success
    assert_nil @task.reload.epic_slug
  end

  # The CLI's `--epic none` spelling, honoured server-side so a raw API caller
  # has a clear it can type.
  test "[integration] the string none clears epic_slug" do
    @task.update!(epic_slug: "devops-v3")

    patch api_v1_task_path(@task.slug),
          params: { epic_slug: "none" },
          headers: @headers, as: :json

    assert_response :success
    assert_nil @task.reload.epic_slug
  end

  test "[integration] an epic_slug that is not a slug is refused with a 422 quoting the rule" do
    patch api_v1_task_path(@task.slug),
          params: { epic_slug: "DevOps V3!" },
          headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_match(/must be a slug/, response.parsed_body["error"].to_s)
    assert_nil @task.reload.epic_slug, "nothing is stored on a refusal"
  end

  # THE SHADOW-STORE REFUSAL. A devops write to the name must be a 422 naming the
  # column and the flag that works — never a 200 for a write the chip and the
  # filter would never see.
  test "[integration] a devops epic_slug write is refused and names the column and --epic" do
    @task.update!(epic_slug: "devops-v3")

    patch api_v1_task_path(@task.slug),
          params: { devops: { kind: "chore", epic_slug: "typed-under-devops" } },
          headers: @headers, as: :json

    assert_response :unprocessable_entity
    error = response.parsed_body["error"].to_s
    assert_match(/devops\.epic_slug is not writable/, error)
    assert_match(/tasks\.epic_slug column/, error)
    assert_match(/--epic/, error, "the refusal must name the command that DOES work")
    @task.reload
    assert_equal "devops-v3", @task.epic_slug, "the column is untouched by a refused write"
    assert_nil @task.metadata.dig("devops", "epic_slug")
  end

  # Omission means UNCHANGED — the same rule as every other column and devops name.
  test "[integration] an unrelated patch leaves epic_slug alone" do
    @task.update!(epic_slug: "devops-v3")

    patch api_v1_task_path(@task.slug),
          params: { devops: { branch: "feat/unrelated" } },
          headers: @headers, as: :json

    assert_response :success
    assert_equal "devops-v3", @task.reload.epic_slug
  end

  test "[integration] show serves epic_slug as a top-level key" do
    @task.update!(epic_slug: "devops-v3")

    get api_v1_task_path(@task.slug), headers: @headers, as: :json

    assert_response :success
    assert_equal "devops-v3", response.parsed_body["data"]["epic_slug"]
  end

  test "[integration] index ?epic= narrows to that epic's tasks through the shared normalization" do
    member = Task.create!(title: "Epic Index Member", epic_slug: "devops-v3")
    other = Task.create!(title: "Epic Index Other", epic_slug: "other-epic")
    plain = Task.create!(title: "Epic Index Plain")

    get api_v1_tasks_path(epic: "DevOps-V3"), headers: @headers, as: :json

    assert_response :success
    slugs = response.parsed_body["data"].map { |row| row["slug"] }
    assert_includes slugs, member.slug
    refute_includes slugs, other.slug
    refute_includes slugs, plain.slug
  end

  # `epic` is a supported index param, so it must not trip the unsupported-param
  # 400 that guards `?status=`.
  test "[integration] index accepts epic beside the other filters" do
    member = Task.create!(title: "Epic Stage Member", epic_slug: "devops-v3", stage: "building")
    Task.create!(title: "Epic Stage Other", epic_slug: "devops-v3", stage: "designed")

    get api_v1_tasks_path(epic: "devops-v3", stage: "building"), headers: @headers, as: :json

    assert_response :success
    assert_equal [member.slug], response.parsed_body["data"].map { |row| row["slug"] }
  end
end
