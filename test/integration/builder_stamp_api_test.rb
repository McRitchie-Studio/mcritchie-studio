require "test_helper"

# [integration] The builder stamp, end-to-end through the API route the CLI
# actually calls — not the model in isolation.
#
# THE MODEL WAS NEVER THE BUG. Task#enforce_builder_stamp keyed on the build
# claim correctly and Task#builder_to_stamp read the actor first. What failed was
# the VALUE arriving over this route: `bin/task move <slug> building` sent a
# SESSION ID as `event.actor`, which can never match SOUL_SLUG, so the stamp
# no-op'd on every real build. Six consecutive tasks reached review with built_by
# blank and `bin/reviewer-select` refused on all six.
#
# A model-level test cannot see that, because it sets Current.task_event_actor by
# hand — it assumes the very thing that was wrong. This drives the route.
class BuilderStampApiTest < ActionDispatch::IntegrationTest
  def token
    Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)
  end

  def claim!(task, actor:)
    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "building", event: { actor: actor } },
          headers: { "Authorization" => "Bearer #{token}" },
          as: :json
  end

  test "a build claim carrying a soul actor records the builder" do
    task = Task.create!(title: "Api Soul Claim", stage: "designed", metadata: { "devops" => {} })

    claim!(task, actor: "carl")

    assert_response :success
    assert_equal "carl", task.reload.metadata.dig("devops", "built_by")
  end

  test "a build claim carrying a session id records NO builder" do
    # The exact payload that produced six blank tasks. Stamping a session id
    # would be worse than blank: the reviewer pool is soul-keyed, so it would
    # exclude nobody while LOOKING recorded, and the refusal that currently
    # protects the property would stop firing.
    task = Task.create!(title: "Api Session Claim", stage: "designed", metadata: { "devops" => {} })

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_response :success
    assert_nil task.reload.metadata.dig("devops", "built_by")
  end

  test "a later partial devops write does not erase the recorded builder" do
    # The API replaces the devops subhash WHOLESALE, so a `bin/task update
    # --checks` that never mentions built_by would otherwise delete the record of
    # who built the task — after review had already been routed on it.
    task = Task.create!(title: "Api Builder Defend", stage: "designed", metadata: { "devops" => {} })
    claim!(task, actor: "shannon")

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { checks_run: ["[unit] something"] } },
          headers: { "Authorization" => "Bearer #{token}" },
          as: :json

    assert_response :success
    assert_equal "shannon", task.reload.metadata.dig("devops", "built_by")
  end
end
