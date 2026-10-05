module People
  # What a typeahead row shows beside a person's name: a headshot, the primary
  # vocation and the current team. Built for a whole result page at once, in a
  # fixed number of queries however many people are on it.
  #
  #   headshot  our mirrored ESPN portrait (Athlete#headshot_url, then
  #             Coach#headshot_url), else people.avatar_url, else nil: the row
  #             draws a placeholder. Never the ESPN URL itself.
  #   vocation  people.primary_vocation (Person::VOCATIONS), nil when none.
  #   team      the athlete's own team (athletes.team_slug, the column the
  #             person page reads), else an unexpired contract's, else the
  #             coach's. The team's name, or the slug in words when no team
  #             row exists.
  class SearchRows
    HEADSHOT_WIDTH = 100
    Row = Data.define(:avatar_url, :vocation, :team)
    BLANK = Row.new(avatar_url: nil, vocation: nil, team: nil)

    def self.for(slugs) = new(slugs).call

    def initialize(slugs)
      @slugs = Array(slugs).compact.uniq
    end

    def call
      return {} if @slugs.empty?

      people = Person.where(slug: @slugs).pluck(:slug, :avatar_url, :primary_vocation)
      people.to_h do |slug, avatar, vocation|
        [slug, Row.new(avatar_url: headshots[slug] || avatar.presence, vocation:, team: team_name(team_slugs[slug]))]
      end
    end

    private

    def athletes = @athletes ||= Athlete.where(person_slug: @slugs).includes(:image_caches).index_by(&:person_slug)

    def coaches = @coaches ||= Coach.where(person_slug: @slugs).includes(:image_caches).order(:id).group_by(&:person_slug)

    def headshots
      @headshots ||= @slugs.index_with do |slug|
        athletes[slug]&.headshot_url(width: HEADSHOT_WIDTH) ||
          coaches.fetch(slug, []).filter_map { |coach| coach.headshot_url(width: HEADSHOT_WIDTH) }.first
      end
    end

    def team_slugs
      @team_slugs ||= begin
        contracts = Contract.where(person_slug: @slugs).order(:id).select(&:active?).group_by(&:person_slug)
        @slugs.index_with do |slug|
          athletes[slug]&.team_slug.presence || contracts.dig(slug, 0)&.team_slug || coaches.dig(slug, 0)&.team_slug
        end
      end
    end

    def team_name(slug)
      return if slug.blank?

      @teams ||= Team.where(slug: team_slugs.values.compact.uniq).pluck(:slug, :name).to_h
      @teams[slug] || slug.tr("-", " ").titleize
    end
  end
end
