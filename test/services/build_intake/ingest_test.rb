require "test_helper"

# [unit] A message typed into the /build chat (BuildIntake::Ingest): the row it
# becomes, the visitor person, the bot shield, the cap reply written in code, and
# an answer completing with an intake card (AgentMessage#complete!).
class BuildIntakeIngestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    @request = AppRequest.create!(prompt: "A league site with schedules")
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def ingest(text, user: nil, client_id: nil, bot_reason: nil, ip: "203.0.113.4", request: @request)
    BuildIntake::Ingest.new(request: request, user: user, ip: ip).call(text, client_id: client_id, bot_reason: bot_reason)
  end

  test "a signed-out visitor's message is a received row for Ray on the request's thread" do
    message = ingest("A league site with schedules", client_id: "client-0001")

    assert_equal %w[web ray chat received build], [ message.channel, message.soul_slug, message.routed_by, message.status, message.channel_ref ]
    assert_equal "web:build:#{@request.token}", message.thread_key
    assert_equal "public", message.person.role
    assert AgentPersonIdentity.exists?(platform: "web", external_id: "build:#{@request.token}", agent_person_id: message.person_id)
    assert_equal false, message.envelope["signed_in"]
    assert_equal 24, message.envelope["ip_hash"].length
    refute_includes message.envelope.to_json, "203.0.113.4", "the raw IP is never stored"
    assert_equal message, AgentMessage.claimable(soul: "ray").first

    assert_equal message, ingest("A league site with schedules", client_id: "client-0001"), "a double submit stores one row"
    assert_equal message.person, ingest("And standings").person, "one visitor person per request"
  end

  test "a signed-in visitor writes as their own person, on the same thread" do
    user = User.create!(email: "builder@example.com", name: "Builder", role: "viewer")
    ingest("first, signed out")
    message = ingest("now signed in", user: user)
    assert_equal AgentMessages::WebIngest.person_for(user), message.person
    assert_equal BuildIntake.thread_key(@request.token), message.thread_key
    assert_equal true, message.envelope["signed_in"]
  end

  test "the bot shield holds a flagged message, so it is never answered" do
    message = ingest("price?", bot_reason: "no_browser_proof")
    assert_equal "held", message.status
    assert_equal "no_browser_proof", message.events.find_by(kind: "bot_shield").detail["reason"]
    assert_empty AgentMessage.claimable(soul: "ray")
  end

  test "past the cap the visitor reads the sign-in line from code and no model runs" do
    BuildIntake.policy = BuildIntake.policy.dup.tap { |p| p.turns_per_request = 2 }
    2.times { |i| ingest("q#{i}").update!(status: "completed", response_text: "a") }

    capped = ingest("one more")
    assert_equal "completed", capped.status
    assert_equal BuildIntake::Caps::CAP_SUMMARY, capped.action_summary
    assert_match(/Sign in to continue/, capped.response_text)
    assert_equal "posted", capped.reply_status, "delivered at once; the page shows it on its next poll"
    assert capped.events.exists?(kind: "intake_capped")
    assert_empty AgentMessage.claimable(soul: "ray")
  end

  test "Ray's answer with an intake card stores the checked card; a catalog proposal is refused" do
    message = ingest("A league site")
    AgentMessage.claim!(soul: "ray", worker: "mac-1")
    text = "Here are three names for your CTO.\n===PROPOSAL===\n" \
           '{"kind": "intake", "card": "cto", "names": ["Coach", "Ref", "Scout"], "portrait": "harbor"}'
    message.reload.complete!(worker: "mac-1", response_text: text)

    message.reload
    assert_equal "Here are three names for your CTO.", message.response_text, "the block never shows"
    assert_equal({ "card" => "cto", "names" => %w[Coach Ref Scout], "portrait" => "harbor" }, message.intake_card)
    assert_equal 0, AgentProposal.count, "a build thread never stores an AgentProposal"

    second = ingest("anything else?")
    AgentMessage.claim!(soul: "ray", worker: "mac-1")
    second.reload.complete!(worker: "mac-1", response_text: "Sure.",
                            proposal: { "kind" => "ask", "capability" => "board_status", "params" => {} })
    assert_nil second.reload.intake_card
    assert second.events.exists?(kind: "intake_refused")
    assert_equal 0, AgentProposal.count
  end

  test "the delivered answer is marked posted with no broadcast" do
    message = ingest("hello")
    AgentMessage.claim!(soul: "ray", worker: "mac-1")
    message.reload.complete!(worker: "mac-1", response_text: "Hi! What do you want to build?")
    perform_enqueued_jobs(only: AgentMessageReplyJob)
    assert_equal "posted", message.reload.reply_status
    assert_equal "web:#{message.id}", message.reply_external_id
  end
end
