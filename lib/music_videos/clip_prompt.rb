# frozen_string_literal: true

module MusicVideos
  # The Higgsfield swap prompt for a clip. TEMPLATE is the operator's proven
  # prompt (2026-09-29) with "the singer" generalised: edit it here only.
  # {athlete} stays a placeholder; pipeline 4 fills it.
  module ClipPrompt
    TEMPLATE = "Replace {target_description} in this music video with {athlete}, the football player. " \
               "The player should have his normal hair, athletic build and be in uniform, full pads with " \
               "no helmet (like the model provided). He should also be mouthing all the mouth movements of " \
               "{target_description}. Give him a diamond encrusted watch, necklace, rings, and some designer " \
               "sunglasses. Please keep {keep_others} the same. Please give the video the same cinematic " \
               "lighting as the music video."
    ATHLETE = "{athlete}"
    NO_TARGET = "the singer"
    NO_OTHERS = "everyone else"
    PERSON_WORD = /\b(?:man|woman|person|guy|girl|boy|singer|rapper|lady|dancer|kid)\b/i

    module_function

    # target: the target performer's cast label (or nil); others: the labels of
    # the other labelled performers in the window; background: anyone else is there.
    def fill(target:, others: [], background: false)
      keep = others.map { |label| describe(label) }.uniq
      keep << NO_OTHERS if background || keep.empty?
      TEMPLATE.gsub("{target_description}", target ? describe(target) : NO_TARGET)
              .gsub("{keep_others}", sentence(keep))
    end

    # A cast label is the agent's visible cue: "long-haired man" reads as a
    # person, "desk" as the scenes they are in.
    def describe(label)
      text = label.to_s.sub(/\s*\(.*\)\s*\z/, "").strip
      return NO_TARGET if text.empty?
      return text if text.match?(/\A(?:the|a|an)\s/i)

      text.match?(PERSON_WORD) ? "the #{text}" : "the person in the #{text} scenes"
    end

    def sentence(items)
      return items.first if items.size == 1

      "#{items[0..-2].join(', ')} and #{items.last}"
    end
  end
end
