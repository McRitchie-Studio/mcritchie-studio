module MusicVideos
  # The stored swap prompt of a clip or chunk, filled from the cast: who the
  # prompt replaces (VideoClip#swap_target), the athlete and look the operator
  # recast them as, and who stays. The wording lives in ClipPrompt alone.
  class ClipPrompts
    # The prompt for one clip (saved or not). swaps: whose swap set fills it,
    # a MusicVideos::SwapSet; by default the cast card as it stands. An alt
    # video passes its own snapshot, so its prompts never follow the card.
    def self.for(clip, swaps: nil)
      video = clip.music_video
      swaps ||= SwapSet.live(video.video_performers)
      people = video.video_performers.index_by(&:ordinal)
      target = clip.swap_target(swaps)
      present = Array(clip.performer_ordinals).filter_map { |n| people[n] } - [target]
      labelled, background = present.partition(&:artist_slug)
      swap = target && swaps[target.ordinal]
      ClipPrompt.fill(target: target&.label, others: labelled.map(&:label), background: background.any?,
                      athlete: swap&.person_name, look: swap&.look_name, video_kind: video.kind)
    end

    # Rewrite every stored prompt of the video (candidates and chunks) after a
    # recast changed. Returns how many prompts changed.
    def self.refresh!(video)
      video.video_performers.reset
      ActiveRecord::Associations::Preloader.new(records: video.video_performers.to_a,
                                                associations: %i[recast_person recast_appearance]).call
      video.video_clips.reset
      video.video_clips.count do |clip|
        prompt = self.for(clip)
        next false if prompt == clip.prompt

        clip.update_columns(prompt:, updated_at: Time.current)
        true
      end
    end
  end
end
