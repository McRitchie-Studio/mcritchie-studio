module MusicVideos
  # The operator's answer for one performer: an existing artist, a person from
  # People (an artist is made for them), a brand-new artist, an extra, or clear.
  class ResolvePerformer
    class Refused < StandardError; end

    def initialize(performer)
      @performer = performer
    end

    def call(artist_slug: nil, person_slug: nil, new_artist_name: nil, new_artist_kind: nil, extra: false, clear: false)
      raise Refused, "the cast is already confirmed" if @performer.music_video.cast_confirmed?

      VideoPerformer.transaction do
        attrs = if clear then { artist_slug: nil, extra: false }
                elsif extra then { artist_slug: nil, extra: true }
                else { artist_slug: pick_artist(artist_slug, person_slug, new_artist_name, new_artist_kind).slug, extra: false }
                end
        @performer.update!(attrs)
      end
      @performer
    end

    private

    def pick_artist(artist_slug, person_slug, new_name, new_kind)
      return Artist.find_by!(slug: artist_slug) if artist_slug.present?
      return artist_for_person(Person.find_by!(slug: person_slug)) if person_slug.present?
      raise Refused, "choose an artist, a person, or name a new artist" if new_name.blank?

      name = new_name.squish
      Artist.create!(slug: Artist.available_slug(name), name:, kind: new_kind.presence || "person")
    end

    def artist_for_person(person)
      Artist.find_by(person_slug: person.slug) ||
        Artist.create!(slug: Artist.available_slug(person.slug), name: person.full_name, kind: "person",
                       person_slug: person.slug)
    end
  end
end
