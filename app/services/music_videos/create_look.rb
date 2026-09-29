module MusicVideos
  # One look per labelled performer per music video (pipeline stage 4): an
  # Appearance for the operator's chosen artist, built from this video's stills.
  # The operator made the mapping on the cast panel; nothing here infers who
  # anyone is.
  class CreateLook
    class Refused < StandardError; end

    def self.call(performer) = new(performer).call

    def initialize(performer)
      @performer = performer
      @video = performer.music_video
    end

    # Why no look can be made yet, or nil.
    def refusal
      return "the cast is not confirmed yet" unless @video.cast_confirmed?
      return "#{@performer.name} is not labelled with an artist" if @performer.artist.nil?
      return "#{@performer.artist.name} is a group: label the member on screen instead" if @performer.artist.group?
      return "#{@performer.name} has no stills from this video" if @performer.still_object_keys.empty?

      "#{@performer.name} already has a look for this video" if existing
    end

    def call
      reason = refusal
      raise Refused, reason if reason

      Appearance.transaction do
        person = person_for(@performer.artist)
        Appearance.create!(
          person_slug: person.slug, music_video_slug: @video.slug, performer_ordinal: @performer.ordinal,
          descriptor: Appearance.available_descriptor(person.slug, "#{@video.title} look")
        )
      end
    end

    private

    def existing
      Appearance.live.exists?(music_video_slug: @video.slug, performer_ordinal: @performer.ordinal)
    end

    # A look hangs off a Person. An artist the operator created has none yet, so
    # one is made from the artist's own name (never matched to an existing
    # person by name: that would be guessing who they are).
    def person_for(artist)
      return artist.person if artist.person

      first, *rest = artist.name.split
      person = Person.new(first_name: first, last_name: rest.join(" ").presence || first)
      person.disambiguator = "artist" if Person.exists?(slug: person.name_slug)
      n = 2
      while Person.exists?(slug: person.name_slug)
        person.disambiguator = "artist-#{n}"
        n += 1
      end
      person.save!
      artist.update!(person_slug: person.slug)
      person
    end
  end
end
