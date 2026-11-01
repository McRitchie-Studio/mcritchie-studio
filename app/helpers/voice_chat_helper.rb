# Talk to Alex by voice on /chat (epic .agents/epics/studio-voice.md, card 4;
# chat/_voice). The words a person reads about where their voice goes, and which
# embedder (if any) the page runs on a take so the speaker can be named.
module VoiceChatHelper
  # Approved by Alex McRitchie, 2026-11-01. Verbatim: beside the microphone on
  # /chat and on the privacy page (landing/privacy), from this one constant.
  VOICE_PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it " \
                  "into text, then deleted. We never keep the audio.".freeze

  # The hold-to-talk button's words per recorder state (studio-engine
  # studio/voice_recorder COPY, merged one level deep).
  VOICE_RECORDER_COPY = {
    "idle" => { "button" => "Hold to talk" },
    "recording" => { "button" => "Let go to send", "status" => "Listening..." },
    "captured" => { "button" => "Hold to talk", "status" => "" },
    "silent" => { "button" => "Hold to talk" },
    "failed" => { "button" => "Hold to try again" },
    "denied" => { "button" => "Hold to talk" },
    "unsupported" => { "button" => "Hold to talk" }
  }.freeze

  # The chip's first words (the engine's say "tap Record").
  VOICE_CHIP_COPY = {
    "prompt" => { "chip" => "Microphone: hold to talk to allow",
                  "note" => "Hold the talk button once and allow the microphone. Then you can pick one here." }
  }.freeze

  # The embedder the page runs on a take (Studio::VoiceMatch.browser_config),
  # as JSON, or nil. Only for a user whose saved voice came from the app's own
  # embedder: anything else answers embedder_mismatch or no_profile on the
  # server, so downloading the model would buy nothing.
  def voice_chat_embedder(user)
    return nil unless user.respond_to?(:voice_embedding) && user.respond_to?(:voice_embedding_model)
    return nil if user.voice_embedding.blank?

    name = Studio.voice_embedder.to_s
    return nil unless user.voice_embedding_model.to_s == Studio::VoiceMatch.model_id(name)

    Studio::VoiceMatch.browser_config(name).to_json
  rescue ArgumentError, KeyError
    nil
  end
end
