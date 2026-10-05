module MusicVideos
  # The recast picker's typeahead: every Person, by name or alias, each with
  # the looks a performer can be recast into (Appearance.recastable) and the
  # row facts (People::SearchRows). People who have a look come first, then
  # exact name, prefix, anywhere. A person with no look is listed with
  # "0 looks": the card offers to create one.
  class RecastAthleteSearch
    LIMIT = 10
    Result = Data.define(:slug, :name, :hint, :looks, :avatar_url, :vocation, :team)

    def self.call(query, limit: LIMIT) = new(query).call(limit:)

    def initialize(query)
      @q = query.to_s.squish.downcase
    end

    def call(limit: LIMIT)
      return [] if @q.empty?

      people = matches.limit(limit).to_a
      looks = Appearance.recastable.where(person_slug: people.map(&:slug)).order(:created_at, :id).group_by(&:person_slug)
      rows = People::SearchRows.for(people.map(&:slug))
      people.map do |person|
        mine = looks.fetch(person.slug, [])
        Result.new(slug: person.slug, name: person.full_name, hint: "#{mine.size} look#{'s' unless mine.size == 1}",
                   **rows.fetch(person.slug, People::SearchRows::BLANK).to_h,
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
      look = "EXISTS (SELECT 1 FROM appearances WHERE appearances.person_slug = people.slug " \
             "AND appearances.retired_at IS NULL AND appearances.music_video_slug IS NULL)"
      Person.where("#{name} LIKE :c OR lower(people.aliases::text) LIKE :c", c: "%#{like}%")
            .order(Arel.sql("CASE WHEN #{look} THEN 0 ELSE 1 END, #{rank}, length(#{name}), people.slug"))
    end
  end
end
