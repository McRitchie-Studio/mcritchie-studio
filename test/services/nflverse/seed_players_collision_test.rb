require "test_helper"

# [integration] The namesake collision, across the importer's whole boundary:
# a CSV in, Person + Athlete rows out.
#
# THE DEFECT THIS EXISTS FOR: two active NFL players can share a name (six measured in the
# 2026 league on 2026-09-21). The importer used to find a Person by name, adopt
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

  # GSIS is only one of six identity keys. These two people still have distinct
  # ESPN IDs, so a blank GSIS must not turn the name match into permission to
  # overwrite the first Athlete.
  test "two namesakes with blank gsis and distinct secondary ids both survive" do
    run_import(csv(
      jefferson(gsis: "", espn: "4262921", position: "WR", team: "MIN"),
      jefferson(gsis: "", espn: "4430737", position: "LB", team: "CLE")
    ))

    people = Person.where(first_name: "Justin", last_name: "Jefferson")
    athletes = Athlete.where(person_slug: people.map(&:slug))

    assert_equal 2, people.count, "the name match silently merged two people"
    assert_equal 2, athletes.count, "one namesake athlete was overwritten"
    assert_equal %w[4262921 4430737], athletes.order(:espn_id).pluck(:espn_id)
  end

  # There is no stable slug suffix when the incoming namesake has no identity
  # key at all. That bad row must be visible in the counters, but it must not
  # abort the post-deploy import or damage the identified athlete.
  test "an unidentifiable namesake is skipped without aborting the import" do
    stats = nil

    assert_nothing_raised do
      stats = run_import(csv(
        jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN"),
        jefferson(gsis: "", espn: "", position: "LB", team: "CLE")
      ))
    end

    assert_equal 1, Athlete.count
    assert_equal "00-0036322", Athlete.first.gsis_id
    assert_equal 1, stats[:namesake_collisions_skipped]
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

  # --- the trap that got past every gate ---------------------------------
  #
  # `post_deploy_cmd` ran this importer WITHOUT `upload_headshots:`, taking the
  # constructor default of true — which raises when AWS_ACCESS_KEY_ID is blank.
  # mcritchie-studio-qa carries no AWS keys, `bin/release` runs post_deploy_cmd
  # against QA with --exit-code, and a non-zero exit aborts the WHOLE batch QA
  # release. No test covered the true path (every other test passes false), and
  # dor-check's post-deploy gate only rejects a bare db:seed.

  test "the headshot-caching default REFUSES without AWS credentials" do
    original = ENV["AWS_ACCESS_KEY_ID"]
    ENV["AWS_ACCESS_KEY_ID"] = nil

    error = assert_raises RuntimeError do
      Nflverse::SeedPlayers.new(csv_body: csv, status_filter: "ACT")
    end
    assert_match(/AWS_ACCESS_KEY_ID/, error.message)
  ensure
    ENV["AWS_ACCESS_KEY_ID"] = original
  end

  test "opting out of headshot caching runs with no AWS credentials at all" do
    original = ENV["AWS_ACCESS_KEY_ID"]
    ENV["AWS_ACCESS_KEY_ID"] = nil

    assert_nothing_raised do
      run_import(csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN")))
    end
  ensure
    ENV["AWS_ACCESS_KEY_ID"] = original
  end

  # --- the import run record ---------------------------------------------

  test "an import records a run so a reader can tell unchecked from unchanged" do
    assert_difference -> { ImportRun.for_source("nflverse_players").count }, 1 do
      run_import(csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN")))
    end

    run = ImportRun.last_success_for("nflverse_players")
    assert_equal "ok", run.status
    assert run.finished_at.present?
    assert_operator run.rows_seen, :>, 0
  end

  test "a failed import is recorded failed, not left running forever" do
    assert_raises StandardError do
      ImportRun.track("nflverse_players") { raise "boom" }
    end

    assert_equal "failed", ImportRun.for_source("nflverse_players").order(:id).last.status
  end

  # Ruby's sort_by is not stable, so rows with no league ID need the index
  # tiebreak or they shuffle between runs — the exact non-determinism `ordered`
  # exists to remove.
  test "rows without a league id keep a deterministic order" do
    importer = Nflverse::SeedPlayers.new(csv_body: csv, upload_headshots: false)
    rows = 200.times.map { |i| { "gsis_id" => "", "marker" => i } }

    first  = importer.send(:ordered, rows).map { |r| r["marker"] }
    second = importer.send(:ordered, rows).map { |r| r["marker"] }

    assert_equal first, second
    assert_equal (0...200).to_a, first
  end
end
