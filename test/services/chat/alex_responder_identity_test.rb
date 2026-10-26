require "test_helper"

# [unit] The public /chat persona is Alex, an AI built by Alex McRitchie: it says
# it is an AI and never claims to be him (ritch-renamed-alex; the honesty rule in
# docs/agents/modules/agent-communication.md).
class ChatAlexResponderIdentityTest < ActiveSupport::TestCase
  PROMPT = Chat::AlexResponder::SYSTEM_PROMPT

  test "the persona is an AI named Alex, never the owner himself" do
    assert_match(/\AYou are Alex, an AI built by Alex McRitchie/, PROMPT)
    assert_includes PROMPT, "say you are an AI in your first reply, never claim to be him"
    refute_match(/You are Alex McRitchie/, PROMPT)
    refute_match(/\bYou (have|run)\b/, PROMPT, "his career is told about him, not as the agent's own")
  end
end
