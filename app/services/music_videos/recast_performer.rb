module MusicVideos
  # The operator's recast for one performer: an athlete (Person) in one of
  # their looks, "keep as is", or clear. Allowed before and after the cast is
  # confirmed, so every stored prompt of the video is refreshed with it.
  class RecastPerformer
    class Refused < StandardError; end

    def initialize(performer)
      @performer = performer
    end

    def call(person_slug: nil, appearance_slug: nil, keep: false, clear: false)
      VideoPerformer.transaction do
        @performer.update!(attributes(person_slug, appearance_slug, keep, clear))
        ClipPrompts.refresh!(@performer.music_video)
      end
      @performer
    end

    private

    def attributes(person_slug, appearance_slug, keep, clear)
      return { recast_person_slug: nil, recast_appearance_slug: nil, recast_keep: false } if clear
      return { recast_person_slug: nil, recast_appearance_slug: nil, recast_keep: true } if keep
      raise Refused, "choose an athlete and one of their looks, or keep as is" if person_slug.blank? || appearance_slug.blank?

      { recast_person_slug: person_slug, recast_appearance_slug: appearance_slug, recast_keep: false }
    end
  end
end
