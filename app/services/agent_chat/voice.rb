module AgentChat
  # A spoken message's `voice` (epic .agents/epics/studio-voice.md, card 4): the
  # page posts a held take to the engine's POST /voice/takes, which answers
  # {text, speaker, score, check, duration_ms}, then sends the text to the chat
  # with that answer as `voice`. This is what the row keeps of it, in
  # envelope["voice"]:
  #
  #   {"speaker" => "Alex McRitchie", "score" => 0.8731, "check" => "matched", "duration_ms" => 2140}
  #
  # THE BROWSER IS NOT TRUSTED with the name. `check` must be one of the
  # engine's own (Studio::VoiceTranscription::CHECKS), and the speaker is
  # recomputed here: the signed-in user's own name when the check is
  # "matched", else "Someone new". So a forged post can at most claim to be the
  # account that sent it, never another person, and no free text a visitor
  # chose ever reaches the agent's prompt as a name. `score` is a cosine
  # (-1..1, 4 places) or nil; `duration_ms` is 1..MAX_DURATION_MS or nil.
  # Nothing here is audio: the take itself was never stored.
  module Voice
    class Invalid < StandardError; end

    SOMEONE_NEW = Studio::VoiceTranscription::SOMEONE_NEW
    CHECKS = Studio::VoiceTranscription::CHECKS
    MAX_DURATION_MS = Studio::VoiceTranscription::MAX_DURATION_MS

    module_function

    # The voice hash to store, or nil when the message was typed. Raises
    # Invalid for a `voice` that is not a hash or names an unknown check.
    def from_param(raw, user:)
      return nil if raw.nil? || raw == ""

      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      raise Invalid, "voice must be {speaker, score, check, duration_ms}" unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      check = raw["check"].to_s
      raise Invalid, "voice.check is not one the engine answers" unless CHECKS.include?(check)

      { "speaker" => speaker_for(check, user), "score" => score(raw["score"]), "check" => check,
        "duration_ms" => duration(raw["duration_ms"]) }
    end

    def speaker_for(check, user)
      return SOMEONE_NEW unless check == "matched" && user

      # The engine's own naming (display_name, then name, then email), so the
      # chat and POST /voice/takes always agree on who spoke.
      Studio::VoiceTranscription.speaker_name(user).to_s.strip.presence || SOMEONE_NEW
    end

    def score(raw)
      value = Float(raw, exception: false)
      return nil unless value&.finite?

      value.clamp(-1.0, 1.0).round(4)
    end

    def duration(raw)
      value = Integer(raw.to_s, exception: false) if raw.to_s.match?(/\A\d{1,9}\z/)
      value&.between?(1, MAX_DURATION_MS) ? value : nil
    end
  end
end
