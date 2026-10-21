require "test_helper"

# [unit] Which owner messages the CTO chat answers with the avatar picker in
# code (AgentMessages::AvatarAsk, task cto-animal-avatar-bank). Narrow on
# purpose: anything else goes to the model.
class AgentMessagesAvatarAskTest < ActiveSupport::TestCase
  AvatarAsk = AgentMessages::AvatarAsk

  test "[unit] an ask to change the avatar, portrait or look matches" do
    [
      "Can you change your avatar?",
      "I want a new avatar",
      "redesign your portrait please",
      "Swap your profile picture for something cooler",
      "can we pick a different pfp",
      "Change your look to a bat with purple wings",
      "Can the CTO's avatar be a fox instead?",
      "Make a new avatar for yourself"
    ].each { |text| assert AvatarAsk.ask?(text), text }
  end

  test "[unit] app work, a bare mention, and a long brief go to the model" do
    [
      "Add avatars to the user profile page",
      "Users should upload an avatar",
      "Change the header colour to blue",
      "I love your avatar",
      "Can we add a new avatar upload for members?",
      "Change the profile page so users pick an avatar",
      "New feature: a waitlist",
      "Change your avatar #{'and also build the booking page with reminders ' * 5}"
    ].each { |text| refute AvatarAsk.ask?(text), text }
  end

  test "[unit] the reply is one line with no colours and no human follow-up" do
    refute_includes AvatarAsk::REPLY, "\n"
    refute_match(/#\h{3,6}|follow up|person/i, AvatarAsk::REPLY)
  end
end
