module MusicVideos
  # What a cast card shows for who is on screen and the swap that naming offers,
  # as the page renders it and as the naming endpoint answers it (JSON), so a
  # name saved without a reload paints the same card a reload would.
  #
  #   state: {kind: "artist", slug, name, avatar_url, vocation, team}, {kind: "extra"}, or nil.
  #   offer: the named Person, when they have a look to be swapped in as
  #          ("Swap with <name>?"), with their search row and looks; else nil.
  module CastCardNaming
    module_function

    # rows/looks: preloaded People::SearchRows and LookOptions, keyed by person slug (the panel batches them).
    def state(performer, rows: nil)
      return { kind: "extra" } if performer.extra?
      artist = performer.artist or return

      row = artist.person_slug && (rows || People::SearchRows.for([artist.person_slug]))[artist.person_slug]
      { kind: "artist", slug: artist.slug, name: artist.name, avatar_url: row&.avatar_url,
        vocation: row&.vocation || (artist.group? ? "group" : "musician"), team: row&.team }
    end

    def offer(performer, rows: nil, looks: nil)
      person = performer.artist&.person or return
      mine = (looks || LookOptions.for([person.slug])).fetch(person.slug, [])
      return if mine.empty?

      row = (rows || People::SearchRows.for([person.slug]))[person.slug] || People::SearchRows::BLANK
      { slug: person.slug, name: person.full_name, **row.to_h, looks: mine.map(&:to_h) }
    end
  end
end
