module MusicVideos
  # "Generate a new look" on a cast card: a new look (Appearance) for the
  # athlete the operator chose, named by him ("Broncos blue"). The athlete
  # becomes the performer's recast if he was not already; the look is NOT
  # chosen for him, so the card still asks which look. The character sheet
  # is started by the caller (Appearances::SheetBuild), outside this
  # transaction, so the job never runs before the look is committed.
  class CreateRecastLook
    class Refused < StandardError; end

    def initialize(performer, person_slug:, descriptor:, reference_url: nil)
      @performer = performer
      @person = Person.find_by(slug: person_slug.to_s)
      @descriptor = descriptor.to_s.squish
      @reference_url = reference_url.to_s.strip.presence
    end

    # Why no look can be made, or nil.
    def refusal
      return "choose who replaces #{@performer.name} first" if @person.nil?
      return "name the look, for example its colours" if @descriptor.empty?

      if Appearance.live.exists?(person_slug: @person.slug, descriptor: @descriptor)
        "#{@person.full_name} already has a look named #{@descriptor}: choose it from the list"
      end
    end

    def call
      reason = refusal
      raise Refused, reason if reason

      Appearance.transaction do
        look = Appearance.create!(person_slug: @person.slug, descriptor: @descriptor, reference_url: @reference_url)
        unless @performer.recast_person_slug == @person.slug
          @performer.update!(recast_person_slug: @person.slug, recast_appearance_slug: nil, recast_keep: false)
          ClipPrompts.refresh!(@performer.music_video)
        end
        look
      end
    end
  end
end
