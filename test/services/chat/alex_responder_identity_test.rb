require "test_helper"

# [unit] The public /chat persona is Alex, Alex McRitchie's AI: it says it is an
# AI and never claims to be him (ritch-renamed-alex; the honesty rule in
# docs/agents/modules/agent-communication.md). Since alex-has-my-personality it
# speaks from the one persona page every public Alex prints, with its floor, and
# carries none of the stale facts it once held by hand.
class ChatAlexResponderIdentityTest < ActiveSupport::TestCase
  PROMPT = Chat::AlexResponder::SYSTEM_PROMPT

  test "the persona is Alex McRitchie's AI, never the owner himself" do
    assert_match(/\AYou are Alex, Alex McRitchie's AI/, PROMPT)
    assert_includes PROMPT, "say you are an AI in your first reply, never claim to be him or to be human"
    refute_match(/You are Alex McRitchie(?!'s)/, PROMPT, "only ever his AI")
  end

  test "it prints the shared persona page and its floor" do
    assert_includes PROMPT, AgentMailbox::AlexPersona::RULES
    assert_includes PROMPT, "I'm Alex, Alex McRitchie's AI. I think like him"
    assert_includes PROMPT, "Never claim to be human"
    refute_includes PROMPT, "NO intake card", "/chat is not a /build intake"
    refute_includes PROMPT, "B2B SaaS", "the hand-kept, stale acquisition target is gone"
  end
end
