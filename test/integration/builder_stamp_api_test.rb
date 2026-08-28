require "test_helper"

# [integration] The builder stamp, through the API route the CLI calls.
#
# WHAT THIS FILE LOOKED LIKE BEFORE, and why it was worthless: it drove
# Task#builder_to_stamp, which was never broken. A reviewer deleted all 40 lines
# of the production change and 7 of 7 tests still passed. Green tests over a dead
# feature. These cover the mechanism that ACTUALLY carries a builder — rule 4,
# agent_slug — because that is what the fast lane now populates.
class BuilderStampApiTest < ActionDispatch::IntegrationTest
  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  def claim!(task, actor:)
    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "building", event: { actor: actor } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  test "a task created with an agent records that soul as the builder" do
    # THE WHOLE FIX. `bin/task begin --agent carl` sets agent_slug; rule 4 stamps
    # built_by from it. No new code, no marker, no --actor — the seam already
    # existed and no documented path passed the flag.
    task = Task.create!(title: "Agent Slug Builder Probe", stage: "designed",
                        agent_slug: "carl", metadata: { "devops" => {} })

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_response :success
    assert_equal "carl", task.reload.metadata.dig("devops", "built_by"),
                 "agent_slug must carry the builder even when the actor is a session id"
  end

  test "no agent and a session actor leaves the builder blank" do
    # The status quo the fast lane produced for six consecutive tasks. Blank is
    # the CORRECT outcome for an unidentified builder — reviewer-select then
    # fails closed and refuses, which is why the fix is to identify the builder
    # rather than to loosen the selector.
    task = Task.create!(title: "No Agent Builder Probe", stage: "designed",
                        metadata: { "devops" => {} })

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_response :success
    assert_nil task.reload.metadata.dig("devops", "built_by")
  end

  test "a recorded builder survives a later partial devops write" do
    # NOTE: the actor here is a UUID on purpose. An earlier draft passed "sess"
    # and it was STAMPED AS THE BUILDER — ReviewerSelector#soul? is shape-only and
    # never consults AgentActivity::SOULS, so any lowercase word passes. That is a
    # real hazard (a typo'd `heartbeat stefon` would stamp stefon, LIFT the
    # fail-closed refusal, and exclude nobody) and it has its own task; it is not
    # this diff's to fix, but do not let a test paper over it.
    #
    # The API replaces devops WHOLESALE, so a `--checks` update that never
    # mentions built_by would otherwise erase who built the task — after review
    # had already been routed on it.
    task = Task.create!(title: "Builder Defend Probe Task", stage: "designed",
                        agent_slug: "shannon", metadata: { "devops" => {} })
    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { checks_run: ["[unit] something"] } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_equal "shannon", task.reload.metadata.dig("devops", "built_by")
  end
end
