module MusicVideos
  # The recast picker's typeahead: People who have at least one look a
  # performer can be recast into (Appearance.recastable), by name or alias,
  # each with those looks. Exact name first, then prefix, then anywhere.
  class RecastAthleteSearch
    LIMIT = 10
    Result = Data.define(:slug, :name, :hint, :looks)

    def self.call(query, limit: LIMIT) = new(query).call(limit:)

    def initialize(query)
      @q = query.to_s.squish.downcase
    end

    def call(limit: LIMIT)
      return [] if @q.empty?

      people = matches.limit(limit).to_a
      looks = Appearance.recastable.where(person_slug: people.map(&:slug)).order(:created_at, :id).group_by(&:person_slug)
      people.map do |person|
        mine = looks.fetch(person.slug, [])
        Result.new(slug: person.slug, name: person.full_name, hint: "#{mine.size} look#{'s' unless mine.size == 1}",
                   looks: mine.map { |look| { slug: look.slug, descriptor: look.descriptor, default: person.default_appearance_slug == look.slug } })
      end
    end

    private

    def matches
      name = "lower(people.first_name || ' ' || people.last_name)"
      like = ActiveRecord::Base.sanitize_sql_like(@q)
      rank = ActiveRecord::Base.sanitize_sql_array(
        ["CASE WHEN #{name} = ? THEN 0 WHEN #{name} LIKE ? THEN 1 WHEN #{name} LIKE ? THEN 2 ELSE 3 END",
         @q, "#{like}%", "% #{like}%"]
      )
      Person.where("#{name} LIKE :c OR lower(people.aliases::text) LIKE :c", c: "%#{like}%")
            .where("EXISTS (SELECT 1 FROM appearances WHERE appearances.person_slug = people.slug " \
                   "AND appearances.retired_at IS NULL AND appearances.music_video_slug IS NULL)")
            .order(Arel.sql("#{rank}, length(#{name}), people.slug"))
    end
  end
end
