require "test_helper"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [integration] A spoken message from a satellite, from the API to the prompt
# (epic .agents/epics/studio-voice.md): the real POST /api/v1/agent_chat/messages,
# the row as the dispatcher claims it (as_api_json), the real MemoryBundle, and
# the prompt ContextBuilder lays out for Alex and for Turf, whose real soul docs
# it reads. "Spoken by" sits INSIDE the untrusted fence and the thread is
# answered as the public, whoever the app named.
class SatelliteChatVoiceTest < ActionDispatch::IntegrationTest
  FENCE = "untrusted-test".freeze
  ANON = "anon-cookie-token-0001".freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    AgentPerson.seed_owner!
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def say(app, soul, person, voice)
    _row, secret = AppCredential.issue!(app_slug: app, purpose: "agent-chat")
    post api_v1_agent_chat_messages_path, params: { soul: soul, text: "what is on this week?", person: person, voice: voice, ip: "203.0.113.9" },
                                          headers: { "Authorization" => "Bearer #{secret}" }, as: :json
    assert_response :created
    AgentMessage.order(:id).last
  end

  def prompt_for(message)
    bundle = JSON.parse(AgentMessages::MemoryBundle.new(message).bundle.to_json)
    assert_equal "public", bundle.dig("audience", "role"), "every chat: thread is answered as the public"
    AgentMailbox::ContextBuilder.new(soul: message.soul_slug, message: JSON.parse(message.as_api_json.to_json), context: bundle,
                                     repo_root: Rails.root.to_s, fence: FENCE).prompt
  end

  def fenced_message(text) = text[/== THE MESSAGE TO ANSWER.*\z/m]
  def outside_fences(text) = text.gsub(%r{<#{FENCE}>.*?</#{FENCE}>}m, "")

  test "Alex on a satellite: a recognised voice is named inside the fence, at the public audience" do
    user = User.create!(email_verified_at: Time.current, email: "speaker@example.com", name: "Pat Speaker", role: "viewer")
    text = prompt_for(say("alex-build", "alex", { email: user.email }, { speaker: "Alex McRitchie", check: "matched", score: 0.9, duration_ms: 1200 }))

    assert_includes fenced_message(text), "<#{FENCE}>\nFrom: Pat Speaker\nSpoken by: Pat Speaker (voice recognised)\nwhat is on this week?"
    assert_includes outside_fences(text), "The sender SPOKE this message"
    refute_includes outside_fences(text), "Spoken by:", "the line never leaves the fence"
    refute_includes text, "Spoken by: Alex McRitchie", "the forged name reaches no prompt"
  end

  test "Turf on Turf Monster: the owner's email, the one a public-audience Turf answers, gets the line inside the fence" do
    message = say("turf-monster", "turf_monster", { email: users(:alex).email }, { check: "matched", score: 0.9, duration_ms: 1200 })
    assert_equal "received", message.status, "the owner's role is answered"
    assert_includes AgentMessage.claimable(soul: "turf_monster").pluck(:id), message.id

    text = prompt_for(message)
    assert_includes fenced_message(text), "Spoken by: Alex McRitchie (voice recognised)\nwhat is on this week?"
    assert_includes outside_fences(text), "The sender SPOKE this message"
    refute_includes outside_fences(text), "Spoken by:"
  end

  test "Turf on Turf Monster: a voice not recognised says so, even on the owner's email" do
    text = prompt_for(say("turf-monster", "turf_monster", { email: users(:alex).email }, { check: "below_threshold", score: 0.2 }))

    assert_includes fenced_message(text), "Spoken by: Someone new (voice not recognised)"
    refute_includes fenced_message(text), "Spoken by: Alex McRitchie"
  end

  test "an anonymous visitor on McRitchie Industries is Someone new inside the fence" do
    message = say("mcritchie-industries", "alex", { anon_token: ANON }, { speaker: "Alex McRitchie", check: "matched", score: 0.99 })
    text = prompt_for(message)

    assert_includes fenced_message(text), "Spoken by: Someone new (voice not recognised)"
    refute_includes text, "Spoken by: Alex McRitchie"
  end

  test "Turf's public visitor is held, not claimed: no prompt is built until an operator releases it" do
    message = say("turf-monster", "turf_monster", { anon_token: ANON }, { check: "no_profile" })

    assert_equal "held", message.status
    assert_not_includes AgentMessage.claimable(soul: "turf_monster").pluck(:id), message.id
    assert_equal "Someone new", message.envelope.dig("voice", "speaker")
  end
end
