module AgentMessages
  # An app owner asking their CTO for a new avatar, answered IN CODE with one
  # line and the picker (task cto-animal-avatar-bank, Alex McRitchie 2026-10-20: "if
  # someone asks for an avatar lets just open the modal again and they can
  # re-pick their avatar. The avatar's physical attributes don't have much
  # material effect on the agent."). Before this the model designed a bat in hex
  # colours and promised a human would follow up.
  #
  # THE MATCH is strict (Carl's review: a loose match hijacked "Change your
  # image compression to webp"). WHEN IN DOUBT, THE MODEL ANSWERS: a missed ask
  # costs one model reply, a false one swallows real app work. A message of at
  # most MAX_LENGTH characters from the app's OWNER is an ask only when ALL of:
  #
  #   it names a change   CHANGE (change, new, redesign, swap, pick, …)
  #   it is about the CTO's OWN picture
  #                       OWN_PICTURE: "your avatar / portrait / pfp / profile
  #                       pic / picture / look", "the CTO's avatar", "an avatar
  #                       for you(rself)"; or a bare avatar word (avatar,
  #                       portrait, pfp) ONLY when the whole message is that
  #                       ask: BARE_MAX_WORDS words or fewer ("new avatar",
  #                       "pick a portrait"), and never "my avatar" (the
  #                       owner's own). Never photo, image, icon, face or pic
  #                       on their own, which are app nouns far more often
  #   it names no app work
  #                       APP_WORDS, applied to EVERY branch: users, page,
  #                       feature, upload, size, header, gallery, logo,
  #                       compression, dashboard, "look and feel", …
  #
  # Anything else, or an admin, goes to the model, whose persona
  # (docs/agents/agents/client_cto/persona.md) says the same thing in one line.
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
    BARE_MAX_WORDS = 4

    OWN_PICTURE = /\b(?:your|ur|yr|the\s+cto'?s|cto'?s?)\s+(?:own\s+|current\s+)?(?:avatar|portrait|pfp|profile\s+pic(?:ture)?|picture|look)\b|\b(?:avatar|portrait|pfp|look)\s+for\s+(?:you|yourself)\b/i
    BARE_PICTURE = /\b(?:avatar|portrait|pfp)\b/i
    APP_WORDS = /\b(?:users?|members?|customers?|clients?|people|community|visitors?|players?|accounts?|pages?|home(?:page)?|screens?|features?|fields?|forms?|pickers?|signup|sign-up|uploads?|files?|heic|webp|png|jpe?g|svg|size|sizes|header|footer|nav(?:bar)?|hero|gallery|galleries|logo|logos|favicon|icons?|icon\s+set|brand|branding|mascot|images?|photos?|compression|detection|model|dashboard|feel|style|css|theme|colou?rs?|button|settings|app|site|website|database|api)\b/i
    CHANGE = /\b(?:change|changing|new|redesign|re-?design|swap|switch|update|different|pick|choose|another|replace|redo|re-?pick|edit|instead|make|turn)\b/i

    module_function

    def ask?(text)
      text = text.to_s
      return false if text.length > MAX_LENGTH || !text.match?(CHANGE)

      return false if text.match?(APP_WORDS)

      text.match?(OWN_PICTURE) || bare_ask?(text)
    end

    # "new avatar", "change avatar please": a bare avatar word in a message that
    # is nothing but the ask (Carl's second review: "Change the default avatar
    # for new signups" is app work).
    def bare_ask?(text)
      words = text.gsub(/[^\p{L}\p{N}'\s-]/u, " ").split
      words.size <= BARE_MAX_WORDS && text.match?(BARE_PICTURE) && !text.match?(/\bmy\s+(?:avatar|portrait|pfp)\b/i)
    end

    # Whether MESSAGE is a code reply that offers the picker.
    def picker?(message)
      meta = message.run_meta
      meta.is_a?(Hash) && meta[META] == true
    end
  end
end
