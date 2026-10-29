require "test_helper"
require_relative "../support/agent_message_fixtures"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [integration] alex-has-my-personality: a chat: thread (alex.build's satellite chat)
# goes through the real AgentChat::Ingest and AgentMessages::MemoryBundle, and the
# prompt ContextBuilder lays out from that bundle carries Alex's persona and its
# floor while still answering at the PUBLIC audience, even for the owner's email:
# the persona is public by construction, so it never needs the owner's audience.
class SatelliteChatPersonaTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    @routes = AgentMessages::Routes.new("web" => { "souls" => %w[alex], "apps" => { "alex-build" => %w[alex] } })
    AgentPerson.seed_owner!
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def prompt_for(email)
    visitor = AgentChat::Visitor.new("alex", email: email)
    message = AgentChat::Ingest.new(app: "alex-build", visitor: visitor, ip: "203.0.113.9", routes: @routes)
                               .call("Who is Alex McRitchie, and what does he think about Rails?")
    assert message.thread_key.start_with?("chat:alex:"), message.thread_key
    bundle = JSON.parse(AgentMessages::MemoryBundle.new(message).bundle.to_json)
    [ bundle, AgentMailbox::ContextBuilder.new(soul: "alex", message: JSON.parse(message.slice("channel", "content", "author_name").to_json),
                                               context: bundle, repo_root: Rails.root.to_s, fence: "untrusted-test").prompt ]
  end

  test "a signed-in visitor's chat: thread carries the persona at the public audience" do
    user = User.create!(email: "visitor@example.com", name: "Visitor", role: "viewer")
    bundle, text = prompt_for(user.email)

    assert_equal "public", bundle.dig("audience", "role")
    assert_nil bundle["intake"], "a chat: thread is not a /build intake"
    assert_includes text, "You are speaking with: public"
    assert_includes text, "- PERSONA. You are Alex, Alex McRitchie's AI"
    assert_includes text, "I'm Alex, Alex McRitchie's AI. I think like him"
    assert_includes text, "Never claim to be human"
    refute_includes text, "NO intake card"
  end

  test "the owner's email over the API still gets the public answer, persona and all" do
    bundle, text = prompt_for(users(:alex).email)

    assert_equal "public", bundle.dig("audience", "role")
    assert_includes text, "You are speaking with: public"
    refute_includes text, "your role doc", "GENERAL is the public profile, never the internal role doc"
    assert_includes text, "- PERSONA. You are Alex, Alex McRitchie's AI"
  end
end
