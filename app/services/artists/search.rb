module Artists
  # The cast panel's typeahead: artists by name and alias, plus People not yet
  # linked to an artist. Ranked exact > prefix > word prefix > contains; at each
  # step a name beats an alias, and an artist beats a bare person on a tie.
  class Search
    LIMIT = 10
    POOL = 30 # per source, taken in rank order, so the merged top LIMIT is exact
    Result = Data.define(:type, :slug, :name, :kind, :hint, :rank)

    NAME_RANKS = [0, 2, 4, 6].freeze
    ALIAS_RANKS = [1, 3, 5, 7].freeze
    PERSON_OFFSET = 0.5

    def self.call(query, limit: LIMIT) = new(query).call(limit:)

    def initialize(query)
      @q = query.to_s.squish.downcase
    end

    def call(limit: LIMIT)
      return [] if @q.empty?

      (artist_results + people_results).sort_by { |r| [r.rank, r.name.length, r.name] }.first(limit)
    end

    private

    def artist_results
      best = {}
      hits = name_hits.map { |slug, rank| [slug, rank, nil] } + alias_hits
      hits.each { |slug, rank, via| best[slug] = [rank, via] if best[slug].nil? || rank < best[slug][0] }

      artists = Artist.includes(:groups, :members).where(slug: best.keys).index_by(&:slug)
      best.filter_map do |slug, (rank, via)|
        artist = artists[slug] or next
        Result.new(type: "artist", slug:, name: artist.name, kind: artist.kind, hint: artist_hint(artist, via), rank:)
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
      rank = rank_sql(column, NAME_RANKS, fallback: ALIAS_RANKS.last)
      scope.order(Arel.sql("#{rank}, length(#{column})")).limit(POOL)
           .pluck(:slug, :first_name, :last_name, Arel.sql(rank)).map do |slug, first, last, r|
        Result.new(type: "person", slug:, name: "#{first} #{last}", kind: "person",
                   hint: "in People, not an artist yet", rank: r + PERSON_OFFSET)
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
