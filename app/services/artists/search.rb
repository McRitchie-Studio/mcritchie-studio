module Artists
  # The cast panel's naming typeahead ("Who is this on screen?"): artists by
  # name and alias, plus People not yet linked to an artist, except sports
  # people (athletes and coaches): those are who REPLACES a performer, picked
  # in the swap search, and offering them here made naming a footballer as the
  # on-screen artist one keystroke away. An athlete already linked to an artist
  # still comes back, as that artist. Ranked exact > prefix > word prefix > contains; at each
  # step a name beats an alias, and an artist beats a bare person on a tie.
  # Every result carries its row facts: a headshot, a vocation and a team
  # (People::SearchRows). An artist with no Person has no headshot or team and
  # reads "musician", or "group".
  class Search
    LIMIT = 10
    POOL = 30 # per source, taken in rank order, so the merged top LIMIT is exact
    Result = Data.define(:type, :slug, :name, :kind, :hint, :rank, :avatar_url, :vocation, :team)
    Hit = Data.define(:type, :slug, :name, :kind, :hint, :rank, :person_slug)

    NAME_RANKS = [0, 2, 4, 6].freeze
    ALIAS_RANKS = [1, 3, 5, 7].freeze
    PERSON_OFFSET = 0.5

    def self.call(query, limit: LIMIT) = new(query).call(limit:)

    def initialize(query)
      @q = query.to_s.squish.downcase
    end

    def call(limit: LIMIT)
      return [] if @q.empty?

      hits = (artist_results + people_results).sort_by { |r| [r.rank, r.name.length, r.name] }.first(limit)
      rows = People::SearchRows.for(hits.map(&:person_slug))
      hits.map do |hit|
        row = rows.fetch(hit.person_slug, People::SearchRows::BLANK)
        Result.new(**hit.to_h.except(:person_slug), avatar_url: row.avatar_url, team: row.team,
                   vocation: row.vocation || (hit.kind == "group" ? "group" : ("musician" if hit.type == "artist")))
      end
    end

    private

    def artist_results
      best = {}
      hits = name_hits.map { |slug, rank| [slug, rank, nil] } + alias_hits
      hits.each { |slug, rank, via| best[slug] = [rank, via] if best[slug].nil? || rank < best[slug][0] }

      artists = Artist.includes(:groups, :members).where(slug: best.keys).index_by(&:slug)
      best.filter_map do |slug, (rank, via)|
        artist = artists[slug] or next
        Hit.new(type: "artist", slug:, name: artist.name, kind: artist.kind, hint: artist_hint(artist, via), rank:,
                person_slug: artist.person_slug)
      end
    end

    def name_hits
      column = "lower(artists.name)"
      ranked(Artist.all, column, NAME_RANKS).pluck(:slug, Arel.sql(rank_sql(column, NAME_RANKS)))
    end

    def alias_hits
      column = "lower(artist_aliases.name)"
      ranked(ArtistAlias.all, column, ALIAS_RANKS).pluck(:artist_slug, Arel.sql(rank_sql(column, ALIAS_RANKS)), :name)
    end

    def people_results
      column = "lower(people.first_name || ' ' || people.last_name)"
      scope = Person.where("#{column} LIKE :c OR lower(people.aliases::text) LIKE :c", c: pattern("%*%"))
                    .where("NOT EXISTS (SELECT 1 FROM artists WHERE artists.person_slug = people.slug)")
                    .where("people.athlete IS NOT TRUE AND people.coach IS NOT TRUE")
                    .where("people.primary_vocation IS NULL OR people.primary_vocation NOT IN ('athlete', 'coach')")
      rank = rank_sql(column, NAME_RANKS, fallback: ALIAS_RANKS.last)
      scope.order(Arel.sql("#{rank}, length(#{column})")).limit(POOL)
           .pluck(:slug, :first_name, :last_name, Arel.sql(rank)).map do |slug, first, last, r|
        Hit.new(type: "person", slug:, name: "#{first} #{last}", kind: "person",
                hint: "in People, not an artist yet", rank: r + PERSON_OFFSET, person_slug: slug)
      end
    end

    def ranked(scope, column, ranks)
      scope.where("#{column} LIKE ?", pattern("%*%"))
           .order(Arel.sql("#{rank_sql(column, ranks)}, length(#{column})")).limit(POOL)
    end

    # exact, prefix, word prefix, contains; `fallback` ranks a row the column does not contain.
    def rank_sql(column, ranks, fallback: nil)
      exact, prefix, word, contains = ranks
      sql = "CASE WHEN #{column} = ? THEN #{exact} WHEN #{column} LIKE ? THEN #{prefix} " \
            "WHEN #{column} LIKE ? THEN #{word} WHEN #{column} LIKE ? THEN #{contains} ELSE #{fallback || contains} END"
      ActiveRecord::Base.sanitize_sql_array([sql, @q, pattern("*%"), pattern("% *%"), pattern("%*%")])
    end

    def pattern(shape) = shape.sub("*", ActiveRecord::Base.sanitize_sql_like(@q))

    def artist_hint(artist, via_alias)
      parts = []
      parts << "aka #{via_alias}" if via_alias
      if artist.group?
        members = artist.members.map(&:name).uniq.first(3)
        parts << "members: #{members.join(', ')}" if members.any?
      elsif artist.groups.any?
        parts << "member of #{artist.groups.map(&:name).uniq.first(2).join(', ')}"
      end
      parts.join(" · ").presence
    end
  end
end
