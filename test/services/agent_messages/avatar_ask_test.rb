require "test_helper"

# [unit] Which owner messages the CTO chat answers with the avatar picker in
# code (AgentMessages::AvatarAsk, task cto-animal-avatar-bank). Strict on
# purpose (Carl's review): anything that might be app work goes to the model.
class AgentMessagesAvatarAskTest < ActiveSupport::TestCase
  AvatarAsk = AgentMessages::AvatarAsk

  # Every phrase from Carl's probe and the coordinator's list, plus our own,
  # with the answer each must get. true: the picker, in code. false: the model.
  TABLE = {
    # The CTO's own picture: the picker.
    "Can you change your look?" => true,
    "new avatar please" => true,
    "pick a different avatar for yourself" => true,
    "Can you change your avatar?" => true,
    "new avatar" => true,
    "change avatar please" => true,
    "pick a portrait" => true,
    "change your avatar to a fox" => true,
    "I don't like your look, can I change it?" => true,
    "redesign your portrait please" => true,
    "Swap your profile picture for something cooler" => true,
    "Change your look to a bat with purple wings" => true,
    "Can the CTO's avatar be a fox instead?" => true,
    "Make a new avatar for yourself" => true,
    "pick a new avatar" => true,
    # App work: the model (Carl's probe).
    "Can you make your photo upload support HEIC files?" => false,
    "Change your image compression to webp" => false,
    "Update your icon set to match our brand" => false,
    "Make the hero image different on the home page" => false,
    "Add a new avatar field to the signup form" => false,
    "Let users pick a new avatar" => false,
    "Swap the logo for a new animal mascot" => false,
    "can you change the favicon to a new icon" => false,
    "I want a new avatar picker for my customers" => false,
    "Change the avatar size in the header" => false,
    "make a new portrait gallery" => false,
    "new pfp feature for the community" => false,
    "Switch your face detection to the new model" => false,
    "Can you redo your look and feel for the dashboard?" => false,
    "new logo please" => false,
    # App work, or the owner's own avatar: the model (Carl's second probe).
    "Change the default avatar for new signups" => false,
    "Change the avatar on the about section" => false,
    "Make avatars round in comments" => false,
    "Make the avatar round in the comments" => false,
    "new avatar upload flow" => false,
    "Can you make the leaderboard show each avatar?" => false,
    "Swap the portrait on the team section for Jane's headshot" => false,
    "change the bio portrait to my new headshot" => false,
    "Replace the avatar placeholder with initials" => false,
    "add a different avatar for guests" => false,
    "change my avatar" => false,
    "Can I change my avatar on my account?" => false,
    "update the avatar crop to a circle" => false,
    "edit the portrait mode layout" => false,
    # Five words with only a bare avatar word: the model (the persona answers it in one line).
    "I want a new avatar" => false,
    "can we pick a different pfp" => false,
    # Our own: no change word, or a feature.
    "Add avatars to the user profile page" => false,
    "Users should upload an avatar" => false,
    "Change the header colour to blue" => false,
    "I love your avatar" => false,
    "Can we add a new avatar upload for members?" => false,
    "Change the profile page so users pick an avatar" => false,
    "New feature: a waitlist" => false,
    "Change your picture #{'and also build the booking flow with reminders ' * 5}" => false
  }.freeze

  test "[unit] the picker answers only an ask about the CTO's own picture; app work goes to the model" do
    wrong = TABLE.reject { |text, want| AvatarAsk.ask?(text) == want }
    assert_empty wrong.map { |text, want| "#{want ? 'missed' : 'HIJACKED'}: #{text}" }
  end

  test "[unit] the reply is one line with no colours and no human follow-up" do
    refute_includes AvatarAsk::REPLY, "\n"
    refute_match(/#\h{3,6}|follow up|person/i, AvatarAsk::REPLY)
  end
end
