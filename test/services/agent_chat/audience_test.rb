require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] A satellite chat is answered as the PUBLIC, whoever an app's credential
# names (AgentMessages::MemoryBundle#audience_person, #private_channel?): one
# bearer token must never buy the owner's audience, notes, history or Google.
# The thread stays the person's, shared across apps.
class AgentChatAudienceTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    @routes = AgentMessages::Routes.new("web" => { "souls" => %w[alex], "apps" => { "alex-build" => %w[alex], "turf-monster" => %w[alex] } })
    @owner = AgentPerson.seed_owner!
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def chat(text, email:, app: "alex-build")
    visitor = AgentChat::Visitor.new("alex", email: email)
    AgentChat::Ingest.new(app: app, visitor: visitor, ip: "203.0.113.4", routes: @routes).call(text)
  end

  def bundle(message) = AgentMessages::MemoryBundle.new(message).bundle

  test "the owner's email over the API is the owner's person but answered as the public" do
    discord = agent_message!(soul: "alex", author_ref: "500", person: @owner, content: "my private Discord ask",
                             status: "completed", response_text: "owner-only answer")
    AgentPersonNote.record_from!(discord, [ "Owner keeps the bank PIN in the red folder." ])

    message = chat("what do you know about me?", email: users(:alex).email)
    assert_equal @owner, message.person, "the thread and the person stay the owner's"

    out = bundle(message)
    assert_equal({ "role" => "public", "client_domain" => nil }, out["audience"].slice("role", "client_domain"))
    assert_nil out["google_context"]
    refute_includes out["user"]["facts"].map { _1["body"] }, "Owner keeps the bank PIN in the red folder.",
                    "a note from the owner's Discord, in the same domain, is not read in a satellite chat"
    refute_includes out.to_json, "my private Discord ask", "the person layer reads only the satellite chats"
    refute_includes out.to_json, discord.response_text
  end

  test "a note learned in a satellite chat is still read there" do
    user = User.create!(email: "baker@example.com", name: "Baker", role: "viewer")
    first = chat("I run a bakery", email: user.email)
    AgentPersonNote.record_from!(first, [ "Runs a bakery." ])

    assert_equal [ "Runs a bakery." ], bundle(chat("what next?", email: user.email))["user"]["facts"].map { _1["body"] }
  end

  test "a non-owner signed in over the API is the public too" do
    user = User.create!(email: "client@example.com", name: "Client", role: "viewer")
    AgentMessages::WebIngest.person_for(user).set_role!("team")

    out = bundle(chat("hi", email: user.email))
    assert_equal "public", out["audience"]["role"]
    assert_nil out["google_context"]
  end

  test "the thread is still one across apps: the second app's turn sees the first's" do
    user = User.create!(email: "builder@example.com", name: "Builder", role: "viewer")
    first = chat("asked on alex.build", email: user.email)
    first.update!(status: "completed", completed_at: Time.current, response_text: "answered on alex.build")

    out = bundle(chat("asked on turf", email: user.email, app: "turf-monster"))
    assert_equal [ "asked on alex.build" ], out["thread"]["turns"].map { _1["content"] }
    assert_equal first.thread_key, out["thread"]["key"]
  end
end
