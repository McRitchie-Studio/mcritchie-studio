module MusicVideos
  # The stored swap prompt of a clip or chunk, filled from the cast: who the
  # prompt replaces, the athlete and look the operator recast them as, and who
  # stays. The wording lives in ClipPrompt alone.
  #
  # Two shapes (piece 16). When anyone the swap set replaces is on screen in
  # the window, the prompt is LETTERED (ClipPrompt.lettered): one line per
  # swapped person present, "Person B (lead) -> #4 Dak Prescott, Cowboys white
  # (character sheet 1)", leads and background alike, the letter fixed per
  # source (PersonLetters) and the number off the look (appearances.jersey_number,
  # read live, so setting a number later fixes every prompt). Otherwise it is
  # the proven single-target prompt (ClipPrompt.fill) with {athlete} blank.
  class ClipPrompts
    # Clear sightings in the window that make a swapped person a lead (lip-sync)
    # rather than background. Sightings are sampled about every 3 s, so two is
    # about six seconds clearly on screen. The chunk's labelled target always leads.
    LEAD_CLEAR_SIGHTINGS = 2

    # The prompt for one clip (saved or not). swaps: whose swap set fills it,
    # a MusicVideos::SwapSet; by default the cast card as it stands. An alt
    # video passes its own snapshot, so its prompts never follow the card.
    # numbers: appearance slug => jersey number (numbers_for); looked up when nil.
    def self.for(clip, swaps: nil, numbers: nil)
      video = clip.music_video
      swaps ||= SwapSet.live(video.video_performers)
      rows = lettered(clip, swaps:, numbers:)
      return single(clip, swaps) if rows.empty?

      ClipPrompt.lettered(swaps: rows, video_kind: video.kind, framed: Array(clip.reference_frames).any?)
    end

    # The lettered rows of a clip: every swapped person present, in the order
    # of the card's character-sheet downloads (VideoClip#swapped_present), so
    # "character sheet N" in the prompt is the Nth download.
    def self.lettered(clip, swaps:, numbers: nil)
      present = clip.swapped_present(swaps)
      return [] if present.empty?

      numbers ||= numbers_for(swaps)
      people = clip.music_video.video_performers.index_by(&:ordinal)
      present.each_with_index.map do |entry, i|
        ClipPrompt::Swap.new(letter: PersonLetters.for(entry.performer_ordinal), number: numbers[entry.appearance_slug],
                             athlete: entry.person_name, look: entry.look_name, sheet: i + 1,
                             lead: lead?(clip, people[entry.performer_ordinal]))
      end
    end

    # appearance slug => jersey number, for the looks a swap set names.
    def self.numbers_for(swaps)
      slugs = swaps.appearance_slugs
      return {} if slugs.empty?

      Appearance.where(slug: slugs).where.not(jersey_number: nil).pluck(:slug, :jersey_number).to_h
    end

    def self.lead?(clip, performer)
      return false unless performer
      return true if performer.ordinal == clip.target_performer

      from = clip.start_ms - ClipCast::TOLERANCE_MS
      to = clip.end_ms + ClipCast::TOLERANCE_MS
      Array(performer.sightings).count { |s| s["visibility"] == "clear" && s["t_ms"].to_i.between?(from, to) } >=
        LEAD_CLEAR_SIGHTINGS
    end

    # The proven single-target prompt, for a window that swaps nobody.
    def self.single(clip, swaps)
      video = clip.music_video
      people = video.video_performers.index_by(&:ordinal)
      target = clip.swap_target(swaps)
      present = Array(clip.performer_ordinals).filter_map { |n| people[n] } - [target]
      labelled, background = present.partition(&:artist_slug)
      swap = target && swaps[target.ordinal]
      ClipPrompt.fill(target: target&.label, others: labelled.map(&:label), background: background.any?,
                      athlete: swap&.person_name, look: swap&.look_name, video_kind: video.kind)
    end
    private_class_method :single

    # Refill the stored prompts of every source whose cast card swaps someone
    # into this look (its jersey number changed). Returns how many changed.
    def self.refresh_casting!(look)
      slugs = VideoPerformer.where(recast_appearance_slug: look.slug).distinct.pluck(:music_video_slug)
      MusicVideo.where(slug: slugs).sum { |video| refresh!(video) }
    end

    # Rewrite every stored prompt of the video (candidates and chunks) after a
    # recast changed. Returns how many prompts changed.
    def self.refresh!(video)
      video.video_performers.reset
      ActiveRecord::Associations::Preloader.new(records: video.video_performers.to_a,
                                                associations: %i[recast_person recast_appearance]).call
      swaps = SwapSet.live(video.video_performers)
      numbers = numbers_for(swaps)
      video.video_clips.reset
      video.video_clips.count do |clip|
        prompt = self.for(clip, swaps:, numbers:)
        next false if prompt == clip.prompt

        clip.update_columns(prompt:, updated_at: Time.current)
        true
      end
    end
  end
end
