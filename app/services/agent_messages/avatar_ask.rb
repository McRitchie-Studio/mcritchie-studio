module AgentMessages
  # An app owner asking their CTO for a new avatar, answered IN CODE with one
  # line and the picker (task cto-animal-avatar-bank, Alex 2026-10-20: "if
  # someone asks for an avatar lets just open the modal again and they can
  # re-pick their avatar. The avatar's physical attributes don't have much
  # material effect on the agent."). Before this the model designed a bat in hex
  # colours and promised a human would follow up.
  #
  # THE MATCH is narrow: a picture word (avatar, portrait, profile picture,
  # pfp, "your look", "your picture/photo/icon/image/face") AND a change word
  # (change, new, redesign, swap, different, pick, another, …), in one message
  # of at most MAX_LENGTH characters from the app's OWNER. Anything else, a
  # longer message, or an admin reads as usual and goes to the model, whose
  # persona (docs/agents/agents/client_cto/persona.md) says the same thing in
  # one line.
  #
  # THE REPLY carries run_meta META, which agent_chats/_turn draws as a "Pick a
  # new avatar" button; it opens the picker the owner's chat page holds
  # (cto_chats/_avatar_picker), and the pick saves through
  # CtoChatsController#avatar. No model runs and no tokens are spent.
  module AvatarAsk
    REPLY = "Happy to change my look. Pick a new avatar below; it updates everywhere right away.".freeze
    META = "avatar_picker".freeze
    SUMMARY = "avatar picker".freeze
    BUTTON = "Pick a new avatar".freeze
    MAX_LENGTH = 200

    PICTURE = /\b(?:avatars?|portraits?|pfp|profile\s+(?:pic(?:ture)?|photo|image|icon)|(?:your|ur)\s+(?:look|picture|pic|photo|icon|image|face|animal))\b/i
    CHANGE = /\b(?:change|changing|new|redesign|re-?design|swap|switch|update|different|pick|choose|another|replace|redo|re-?pick|edit)\b/i

    module_function

    def ask?(text)
      text = text.to_s
      text.length <= MAX_LENGTH && text.match?(PICTURE) && text.match?(CHANGE)
    end

    # Whether MESSAGE is a code reply that offers the picker.
    def picker?(message)
      meta = message.run_meta
      meta.is_a?(Hash) && meta[META] == true
    end
  end
end
