require "test_helper"

# [unit] People::Merge, the one person merge: every row that names the source
# moves to the keeper or is dropped as a twin, a moved row whose slug is built
# from the person's takes the keeper's, and a refusal rolls the whole merge back.
class People::MergeTest < ActiveSupport::TestCase
  setup do
    @bills = teams(:buffalo_bills)
    @keep = Person.create!(first_name: "Merge", last_name: "Keeper", athlete: true)
    @source = Person.create!(first_name: "Merge", last_name: "Source", athlete: true)
  end

  def merge! = People::Merge.call!(keep: @keep, source: @source)

  test "[unit] a moved contract takes the keeper's slug, so the source's name is free again" do
    contract = Contract.create!(person_slug: @source.slug, team_slug: @bills.slug, contract_type: "active")
    assert_equal "merge-source-buffalo-bills", contract.slug

    merge!

    assert_equal "merge-keeper-buffalo-bills", contract.reload.slug
    assert_not Person.exists?(@source.id)
    newcomer = Person.create!(first_name: "Merge", last_name: "Source")
    assert_nothing_raised { Contract.create!(person_slug: newcomer.slug, team_slug: @bills.slug, contract_type: "active") }
  end

  test "[unit] a re-parented athlete profile and its grades take the keeper's slugs" do
    athlete = Athlete.create!(person_slug: @source.slug, sport: "football", position: "QB")
    grade = AthleteGrade.create!(athlete_slug: athlete.slug, season_slug: seasons(:nfl_2025).slug)

    merge!

    assert_equal "merge-keeper-athlete", athlete.reload.slug
    assert_equal @keep.slug, athlete.person_slug
    assert_equal "merge-keeper-athlete", grade.reload.athlete_slug
    assert_equal "merge-keeper-athlete-#{seasons(:nfl_2025).slug}", grade.slug
  end

  test "[unit] a coach the keeper already holds is dropped and its rankings move to the twin" do
    keep_coach = Coach.create!(person_slug: @keep.slug, team_slug: @bills.slug, role: "head_coach", sport: "football")
    source_coach = Coach.create!(person_slug: @source.slug, team_slug: @bills.slug, role: "head_coach", sport: "football")
    ranking = CoachRanking.create!(coach_slug: source_coach.slug, season_slug: seasons(:nfl_2025).slug,
                                   rank_type: CoachRanking::RANK_TYPES.first, rank: 3)

    stats = merge!

    assert_not Coach.exists?(source_coach.id)
    assert_equal keep_coach.slug, ranking.reload.coach_slug
    assert_equal "#{keep_coach.slug}-#{ranking.rank_type}-#{seasons(:nfl_2025).slug}", ranking.slug
    assert_equal 1, stats[:coaches_dropped]
  end

  test "[unit] pointers with no association follow the keeper" do
    artist = Artist.create!(slug: "merge-source-artist", name: "Merge Source", sort_name: "Source, Merge", kind: "person",
                            person_slug: @source.slug)
    news = News.create!(title: "Merge story", url: "https://example.com/merge", primary_person_slug: @source.slug,
                        secondary_person_slug: @source.slug)

    merge!

    assert_equal @keep.slug, artist.reload.person_slug
    assert_equal [@keep.slug, @keep.slug], news.reload.values_at(:primary_person_slug, :secondary_person_slug)
    assert_includes @keep.reload.aliases, "Merge Source"
  end

  test "[unit] a refusal anywhere rolls the whole merge back" do
    contract = Contract.create!(person_slug: @source.slug, team_slug: @bills.slug, contract_type: "active")
    # Another row already holds the slug the moved contract would derive.
    squatter = Contract.create!(person_slug: people(:josh_allen).slug, team_slug: teams(:miami_dolphins).slug, contract_type: "active")
    squatter.update_columns(slug: "merge-keeper-buffalo-bills")

    assert_raises(Sluggable::SlugRefused) { merge! }

    assert Person.exists?(@source.id)
    assert_equal @source.slug, contract.reload.person_slug
    assert_equal "merge-source-buffalo-bills", contract.slug
  end

  test "[unit] a person cannot be merged into themselves" do
    assert_raises(ArgumentError) { People::Merge.call!(keep: @keep, source: @keep) }
  end
end
