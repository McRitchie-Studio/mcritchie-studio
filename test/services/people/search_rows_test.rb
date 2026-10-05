require "test_helper"

# [unit] People::SearchRows — what a typeahead row shows beside a name: the
# mirrored headshot (else the person's avatar, else nothing), the primary
# vocation, and the current team; for a whole page of results in a fixed
# number of queries. Every person and team here is synthetic.
module People
  class SearchRowsTest < ActiveSupport::TestCase
    setup do
      @team = Team.create!(slug: "test-city-testers", name: "Test City Testers")
      @other = Team.create!(slug: "test-town-triers", name: "Test Town Triers")
    end

    def person(last_name, **attrs) = Person.create!(first_name: "Test", last_name:, **attrs)

    def rostered(last_name, team: @team, headshot: true, **attrs)
      person(last_name, athlete: true, **attrs).tap do |p|
        profile = Athlete.create!(person_slug: p.slug, sport: "football", team_slug: team&.slug)
        next unless headshot

        ImageCache.create!(owner: profile, purpose: "headshot", variant: "100", content_type: "image/png",
                           s3_key: "headshots/nfl/test/#{p.slug}/100.png")
        ImageCache.create!(owner: profile, purpose: "headshot", variant: "400", content_type: "image/png",
                           s3_key: "headshots/nfl/test/#{p.slug}/400.png")
      end
    end

    def row(person) = SearchRows.for([person.slug]).fetch(person.slug)

    test "an athlete gets the small mirrored headshot, their primary vocation and their team" do
      athlete = rostered("Row Athlete", avatar_url: "https://img.example/own.png")

      found = row(athlete)
      assert_equal athlete.athlete_profile.headshot_url(width: 100), found.avatar_url
      assert_match %r{/100\.png}, found.avatar_url
      assert_equal %w[athlete Test\ City\ Testers], [found.vocation, found.team]
    end

    test "no mirrored headshot falls back to the person's avatar, then to nothing" do
      with_avatar = rostered("Row Avatar", headshot: false, avatar_url: "https://img.example/own.png")
      bare = person("Row Bare")

      assert_equal "https://img.example/own.png", row(with_avatar).avatar_url
      assert_equal SearchRows::BLANK, row(bare)
    end

    test "the vocation is the primary one, not the first" do
      star = rostered("Row Star")
      star.update!(vocations: %w[athlete actor entertainer], primary_vocation: "entertainer")

      assert_equal "entertainer", row(star).vocation
    end

    test "the team is the athlete's own, else an unexpired contract's, else the coach's" do
      contracted = person("Row Contracted", athlete: true)
      Contract.create!(person_slug: contracted.slug, team_slug: @other.slug, contract_type: "active", expires_at: 1.year.ago)
      assert_nil row(contracted).team, "an expired contract names no current team"
      mock = Team.create!(slug: "test-mock-mockers", name: "Test Mock Mockers")
      Contract.create!(person_slug: contracted.slug, team_slug: mock.slug, contract_type: "mock_pick")
      assert_nil row(contracted).team, "a mock pick is a projection, not a team"
      Contract.create!(person_slug: contracted.slug, team_slug: @team.slug, contract_type: "active")
      assert_equal "Test City Testers", row(contracted).team

      coach = person("Row Coach", coach: true)
      Coach.create!(person_slug: coach.slug, team_slug: @other.slug, role: "head_coach", sport: "football")
      assert_equal %w[coach Test\ Town\ Triers], [row(coach).vocation, row(coach).team]

      own = rostered("Row Own", team: @other)
      Contract.create!(person_slug: own.slug, team_slug: @team.slug, contract_type: "active")
      assert_equal "Test Town Triers", row(own).team, "the athlete's own team column wins"
    end

    test "a team slug with no team row reads as words, never blank" do
      orphan = rostered("Row Orphan", team: nil)
      orphan.athlete_profile.update_columns(team_slug: "test-harbor-hawks")

      assert_equal "Test Harbor Hawks", row(orphan).team
    end

    test "nobody asked for, nobody known and an empty page are all empty" do
      assert_equal({}, SearchRows.for([]))
      assert_equal({}, SearchRows.for([nil, "nobody-here"]))
    end

    test "ten rows cost the same queries as one" do
      people = Array.new(10) do |n|
        rostered("Row Crowd #{n}", team: n.even? ? @team : @other).tap do |p|
          Contract.create!(person_slug: p.slug, team_slug: @team.slug, contract_type: "active")
          Coach.create!(person_slug: p.slug, team_slug: @other.slug, role: "head_coach", sport: "football")
        end
      end
      count = ->(slugs) do
        seen = 0
        counter = ->(*, payload) { seen += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          ActiveRecord::Base.uncached { SearchRows.for(slugs) }
        end
        seen
      end

      one = count.call([people.first.slug])
      assert_operator one, :>, 0
      assert_equal one, count.call(people.map(&:slug))
      assert_equal 10, SearchRows.for(people.map(&:slug)).values.count { |r| r.avatar_url && r.team }
    end
  end
end
