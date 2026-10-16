require "test_helper"

# [integration] The lane cap at the claim, through the API route `bin/task begin`'s
# child `move <slug> building` calls (docs/agents/system/client-pipeline.md): past
# the tier's cap the PATCH is refused with a message naming the tier and the
# upgrade, and the task stays in designed; the hub is never capped.
class BuildingLaneCapApiTest < ActionDispatch::IntegrationTest
  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)

  def claim!(task)
    patch "/api/v1/tasks/#{task.slug}", params: { stage: "building", event: { actor: "pokemon", source: "cli" } },
                                        headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  def task!(title, stage:, repo: "turf-monster")
    Task.create!(title: title, stage: stage, metadata: { "devops" => { "repositories" => [ repo ] } })
  end

  test "[integration] begin's claim is refused at the cap, naming the tier and the upgrade" do
    apps(:turf_monster).update!(package_tier: "vibe")
    task!("Holding the lane", stage: "building")
    waiting = task!("Waiting its turn", stage: "designed")

    claim!(waiting)

    assert_response :unprocessable_entity
    error = response.parsed_body["error"]
    assert_match(/Turf Monster is on the Vibe tier: 1 of 1 building lane in use/, error)
    assert_match(/upgrade to Builder for 2 lanes/, error)
    assert_equal "designed", waiting.reload.stage

    apps(:turf_monster).update!(package_tier: "builder")
    claim!(waiting)
    assert_response :success
    assert_equal "building", waiting.reload.stage
  end

  test "[integration] the hub's claims are never capped" do
    apps(:mcritchie_studio).update!(package_tier: "vibe")
    task!("Hub one", stage: "building", repo: "mcritchie-studio")
    claim!(task!("Hub two", stage: "designed", repo: "mcritchie-studio"))
    assert_response :success
  end
end
