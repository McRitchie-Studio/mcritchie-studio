require "test_helper"

# [integration] The namesake collision, across the importer's whole boundary:
# a CSV in, Person + Athlete rows out.
#
# THE DEFECT THIS EXISTS FOR: two active NFL players can share a name (seven
# pairs in the 2026 league). The importer used to find a Person by name, adopt
# whatever Athlete hung off them, and update it — so the second arrival
# OVERWROTE the first. The row counted as an update, the import reported
# success, and a player was simply gone.
class Nflverse::SeedPlayersCollisionTest < ActiveSupport::TestCase
  HEADER = "gsis_id,espn_id,pff_id,otc_id,pfr_id,first_name,common_first_name,last_name," \
           "position,latest_team,status,last_season,height,weight,headshot".freeze

  def csv(*rows)
    ([HEADER] + rows).join("\n")
  end

  def jefferson(gsis:, espn:, position:, team:)
    "#{gsis},#{espn},,,,Justin,Justin,Jefferson,#{position},#{team},ACT,2026,72,195,"
  end

  def run_import(body)
    Nflverse::SeedPlayers.new(csv_body: body, upload_headshots: false, status_filter: "ACT").call
  end

  setup do
    Athlete.delete_all
    Person.where(last_name: "Jefferson").delete_all
  end

  # The headline case, named in the migration: a Vikings receiver and a Browns
  # linebacker who share a name.
  test "two namesakes both survive the import" do
    run_import(csv(
      jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN"),
      jefferson(gsis: "00-0039075", espn: "4430737", position: "LB", team: "CLE")
    ))

    people = Person.where(first_name: "Justin", last_name: "Jefferson")
    assert_equal 2, people.count, "one namesake was overwritten by the other"
    assert_equal 2, Athlete.where(person_slug: people.map(&:slug)).count
  end

  test "the namesake carries a disambiguated slug and the first keeps the clean one" do
    run_import(csv(
      jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN"),
      jefferson(gsis: "00-0039075", espn: "4430737", position: "LB", team: "CLE")
    ))

    slugs = Person.where(first_name: "Justin", last_name: "Jefferson").map(&:slug).sort
    assert_includes slugs, "justin-jefferson"
    assert(slugs.any? { |s| s.start_with?("justin-jefferson-") && s != "justin-jefferson" },
           "expected a disambiguated slug, got #{slugs.inspect}")
  end

  # Derived from the league ID, not a counter — so the URL cannot depend on
  # which order the CSV happened to list them in.
  test "the disambiguated slug is stable across row order" do
    a = jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN")
    b = jefferson(gsis: "00-0039075", espn: "4430737", position: "LB", team: "CLE")

    run_import(csv(a, b))
    forward = Person.where(first_name: "Justin", last_name: "Jefferson").map(&:slug).sort

    Athlete.delete_all
    Person.where(last_name: "Jefferson").delete_all

    run_import(csv(b, a))
    reversed = Person.where(first_name: "Justin", last_name: "Jefferson").map(&:slug).sort

    assert_equal forward, reversed
  end

  # The identifier every downstream importer is supposed to match on.
  test "league identifiers are populated" do
    run_import(csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN")))

    athlete = Person.find_by(slug: "justin-jefferson").athlete_profile
    assert_equal "00-0036322", athlete.gsis_id
    assert_equal "4262921", athlete.espn_id
  end

  # An unidentified row for this name is ADOPTED, not twinned — otherwise every
  # hand-entered or seeded record would sprout a duplicate on first import.
  test "an athlete with no league id is adopted rather than twinned" do
    person = Person.create!(first_name: "Justin", last_name: "Jefferson", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football")

    assert_no_difference -> { Person.where(last_name: "Jefferson").count } do
      run_import(csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN")))
    end
    assert_equal "00-0036322", person.reload.athlete_profile.gsis_id
  end

  # IDEMPOTENCY, and it is what makes delta sync possible: Rails only bumps
  # updated_at on a real change, so a re-import of unchanged rows must leave
  # every timestamp alone. If it did not, every delta would return everything.
  test "re-importing unchanged rows does not bump updated_at" do
    body = csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN"))
    run_import(body)

    athlete = Person.find_by(slug: "justin-jefferson").athlete_profile
    before = athlete.reload.updated_at

    travel 1.hour do
      run_import(body)
    end

    assert_equal before.to_i, athlete.reload.updated_at.to_i,
                 "an unchanged row was rewritten — every delta would now return every player"
  end

  test "a real change does bump updated_at" do
    run_import(csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN")))
    athlete = Person.find_by(slug: "justin-jefferson").athlete_profile
    before = athlete.reload.updated_at

    travel 1.hour do
      run_import(csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "CLE")))
    end

    assert_operator athlete.reload.updated_at, :>, before
  end
end
