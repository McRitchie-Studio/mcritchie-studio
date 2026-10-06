module MusicVideos
  # The operator's recast for one performer, as the cast card's Replace with
  # search and Keep Original checkbox send it:
  #
  #   person_slug (+ appearance_slug)  a pick: swap on, to this athlete in this
  #                                    look, Keep Original unchecked.
  #                                    An athlete with no look yet is saved
  #                                    alone and stays pending
  #                                    (VideoPerformer#recast_pending?).
  #   keep                             Keep Original checked, swap OFF: the athlete and look stay
  #                                    remembered (recast_keep), read by nothing.
  #   swap                             Keep Original unchecked: back ON with what is remembered. A
  #                                    remembered look that is gone falls back
  #                                    to the athlete alone (pending).
  #   clear                            forget the recast entirely (the card's Clear).
  #
  # Allowed before and after the cast is confirmed, so every stored prompt of
  # the video is refreshed with each change.
  class RecastPerformer
    class Refused < StandardError; end

    def initialize(performer)
      @performer = performer
    end

    def call(person_slug: nil, appearance_slug: nil, keep: false, swap: false, clear: false)
      VideoPerformer.transaction do
        @performer.update!(attributes(person_slug, appearance_slug, keep, swap, clear))
        ClipPrompts.refresh!(@performer.music_video)
      end
      @performer
    end

    private

    def attributes(person_slug, appearance_slug, keep, swap, clear)
      return { recast_person_slug: nil, recast_appearance_slug: nil, recast_keep: false } if clear
      return { recast_keep: true } if keep
      return swap_back_on if swap
      raise Refused, "choose an athlete and one of their looks, or turn the swap off" if person_slug.blank?
      if appearance_slug.blank? && Appearance.recastable.exists?(person_slug:)
        raise Refused, "choose one of that athlete's looks, or turn the swap off"
      end

      { recast_person_slug: person_slug, recast_appearance_slug: appearance_slug, recast_keep: false }
    end

    # Nothing remembered: on names nobody, which is the same row as off.
    def swap_back_on
      look = @performer.recast_appearance_slug
      live = look.present? && Appearance.recastable.exists?(slug: look, person_slug: @performer.recast_person_slug)
      { recast_keep: false, recast_appearance_slug: (look if live) }
    end
  end
end
