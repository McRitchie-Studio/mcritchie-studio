module AgentMessages
  # An app owner asking their CTO for a new avatar, answered IN CODE with one
  # line and the picker (task cto-animal-avatar-bank, Alex 2026-10-20: "if
  # someone asks for an avatar lets just open the modal again and they can
  # re-pick their avatar. The avatar's physical attributes don't have much
  # material effect on the agent."). Before this the model designed a bat in hex
  # colours and promised a human would follow up.
  #
  # THE MATCH is narrow, in one message of at most MAX_LENGTH characters from
  # the app's OWNER, with a change word (change, new, redesign, swap,
  # different, pick, another, …) and EITHER the CTO's own picture ("your
  # avatar", "your look", "the CTO's portrait", "a new avatar for you") OR a
  # bare avatar word (avatar, portrait, pfp) with no word of app work (users,
  # page, feature, upload, …), since "a new avatar upload for members" is a
  # feature request. Anything else, or an admin, goes to the model, whose
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

    PICTURE_WORD = /(?:avatar|portrait|pfp|profile\s+(?:pic(?:ture)?|photo|image|icon)|look|picture|pic|photo|icon|image|face|animal)/i
    OWN_PICTURE = /\b(?:your|ur|yr|the\s+cto'?s|cto'?s?)\s+(?:own\s+|current\s+)?#{PICTURE_WORD.source}\b|\b(?:avatar|portrait|pfp|look)\s+for\s+(?:you|yourself)\b/i
    BARE_PICTURE = /\b(?:avatar|portrait|pfp)\b/i
    APP_WORDS = /\b(?:users?|members?|customers?|clients?|people|accounts?|page|pages|screen|feature|upload|uploads|app|site|profiles?|settings|signup|sign-up|form)\b/i
    CHANGE = /\b(?:change|changing|new|redesign|re-?design|swap|switch|update|different|pick|choose|another|replace|redo|re-?pick|edit|instead|make|turn)\b/i

    module_function

    def ask?(text)
      text = text.to_s
      return false if text.length > MAX_LENGTH || !text.match?(CHANGE)

      text.match?(OWN_PICTURE) || (text.match?(BARE_PICTURE) && !text.match?(APP_WORDS))
    end

    # Whether MESSAGE is a code reply that offers the picker.
    def picker?(message)
      meta = message.run_meta
      meta.is_a?(Hash) && meta[META] == true
    end
  end
end
