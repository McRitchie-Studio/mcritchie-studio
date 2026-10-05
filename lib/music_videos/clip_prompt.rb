# frozen_string_literal: true

module MusicVideos
  # The Higgsfield swap prompt for a clip or a chunk. TEMPLATE is the operator's
  # proven prompt (2026-09-29) with "the singer" generalised: edit it here only.
  # {athlete} is filled once the operator recasts the target on the cast panel
  # (the hub's MusicVideos::ClipPrompts); until then it stays a placeholder.
  module ClipPrompt
    TEMPLATE = "Replace {target_description} in this {video} with {athlete}, the football player. " \
               "The player should have his normal hair, athletic build and be in uniform, full pads with " \
               "no helmet (like the {look}model provided). He should also be mouthing all the mouth movements of " \
               "{target_description}. Give him a diamond encrusted watch, necklace, rings, and some designer " \
               "sunglasses. Please keep {keep_others} the same. Please give the video the same cinematic " \
               "lighting as the {source}."
    ATHLETE = "{athlete}"
    NO_TARGET = "the singer"
    NO_OTHERS = "everyone else"
    # What the prompt calls the source. A cinematic video is never a music video.
    VIDEO_WORDS = { "music_video" => "music video", "cinematic" => "video" }.freeze
    SOURCE_WORDS = { "music_video" => "music video", "cinematic" => "original video" }.freeze
    NO_TARGET_BY_KIND = { "cinematic" => "the main person on screen" }.freeze
    PERSON_WORD = /\b(?:man|woman|person|guy|girl|boy|singer|rapper|lady|dancer|kid)\b/i

    module_function

    # target: the target performer's cast label (or nil); others: the labels of
    # the other labelled performers in the window; background: anyone else is there.
    # athlete and look: the operator's recast of the target (a name and a look
    # name), or nil. video_kind: MusicVideo#kind.
    def fill(target:, others: [], background: false, athlete: nil, look: nil, video_kind: "music_video")
      keep = others.map { |label| describe(label) }.uniq
      keep << NO_OTHERS if background || keep.empty?
      who = target ? describe(target) : NO_TARGET
      who = NO_TARGET_BY_KIND.fetch(video_kind.to_s, who) if who == NO_TARGET
      name = plain(athlete)
      look_name = plain(look)
      TEMPLATE.gsub("{target_description}", who)
              .gsub("{keep_others}", sentence(keep))
              .gsub("{video}", VIDEO_WORDS.fetch(video_kind.to_s, VIDEO_WORDS["music_video"]))
              .gsub("{source}", SOURCE_WORDS.fetch(video_kind.to_s, SOURCE_WORDS["music_video"]))
              .gsub("{look}", name && look_name ? "#{look_name} " : "")
              .gsub(ATHLETE) { name || ATHLETE }
    end

    # A name as prompt text: one line, no braces (a brace would read as a blank).
    def plain(text)
      clean = text.to_s.delete("{}").split.join(" ")
      clean.empty? ? nil : clean
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
