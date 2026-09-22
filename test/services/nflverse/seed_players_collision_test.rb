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

  # The identity map this importer is accountable for: which human owns which
  # slug. Returned sorted so two runs compare as a MAPPING, not a row order.
  def slug_to_espn
    Person.where(first_name: "Justin", last_name: "Jefferson")
          .map { |person| [person.slug, Athlete.find_by(person_slug: person.slug)&.espn_id] }
          .sort.to_h
  end

  def reset_jeffersons
    Athlete.delete_all
    Person.where(last_name: "Jefferson").delete_all
  end

  setup { reset_jeffersons }

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

    # The count alone CANNOT see a silent merge. Adopting the unidentifiable row
    # instead of skipping it also leaves one Athlete, also keeps the gsis
    # (attrs.compact drops the blank), and still increments the counter — while
    # the surviving row quietly becomes the OTHER human. Measured against that
    # mutant: position LB, team cleveland-browns, athletes_updated 2.
    assert_equal "WR", Athlete.first.position, "the skipped row overwrote the identified athlete"
    assert_equal "minnesota-vikings", Athlete.first.team_slug
    assert_equal 1, stats[:athletes_updated]
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

    reset_jeffersons
    run_import(csv(b, a))
    reversed = Person.where(first_name: "Justin", last_name: "Jefferson").map(&:slug).sort

    assert_equal forward, reversed
  end

  # THE MAPPING, not the count. Every count assertion above is INVARIANT UNDER
  # PERMUTATION: reversing these two rows still yields two people and two
  # athletes, so none of them can see this defect. What a feed reorder can
  # still change is WHICH human owns the clean slug — and in this schema the
  # slug IS the foreign key, so grades, stats and cached headshots follow it.
  # Assert the pairing.
  #
  # The rows are deliberately blank-GSIS: with a GSIS on both, `ordered` sorts
  # on it and the outcome was already stable. Blank on both, GSIS discriminates
  # nothing, and the secondary IDs are the only thing left that belongs to the
  # DATA rather than to the file.
  test "blank-gsis namesakes keep the same slug-to-id mapping in either feed order" do
    a = jefferson(gsis: "", espn: "4262921", position: "WR", team: "MIN")
    b = jefferson(gsis: "", espn: "4430737", position: "LB", team: "CLE")

    run_import(csv(a, b))
    forward = slug_to_espn

    reset_jeffersons
    run_import(csv(b, a))
    reversed = slug_to_espn

    assert_equal forward, reversed,
                 "reordering the feed handed the clean slug to the other human"
    assert_equal({ "justin-jefferson" => "4262921", "justin-jefferson-0737" => "4430737" },
                 forward, "the clean slug must follow the identifier, not the row index")
  end

  # The disambiguator is the last four digits of a league ID, so two namesakes
  # whose IDs end alike compute the SAME slug. It takes THREE to reach:
  # the first namesake keeps the clean slug and never computes a suffix, so
  # the collision is between the SECOND and THIRD. `Person.create!` then hits
  # index_people_on_slug and raises RecordNotUnique — uncaught, from inside a
  # post-deploy command, which aborts the whole ship. That is the same
  # deploy-aborting raise this task removed from `disambiguator_for`, left
  # live one call away on the adjacent path.
  test "namesakes sharing their last four id digits both survive without aborting" do
    rows = [
      jefferson(gsis: "", espn: "4264567", position: "WR", team: "MIN"),
      jefferson(gsis: "", espn: "4434567", position: "LB", team: "CLE"),
      jefferson(gsis: "", espn: "4994567", position: "TE", team: "BUF")
    ]
    expected = {
      "justin-jefferson" => "4264567",
      "justin-jefferson-4567" => "4434567",
      "justin-jefferson-4994567" => "4994567"
    }
    stats = nil

    assert_nothing_raised do
      stats = run_import(csv(*rows))
    end

    assert_equal 3, Person.where(first_name: "Justin", last_name: "Jefferson").count,
                 "a suffix collision cost us a human"
    assert_equal expected, slug_to_espn,
                 "the colliding namesake must widen its suffix, not take the taken slug"
    # `@stats` is a Hash.new(0), so an untouched counter reads 0, never nil.
    assert_equal 0, stats[:namesake_collisions_skipped],
                 "all three carry an identity key; none of them is unidentifiable"

    # And the widened suffix is data-derived too, so it cannot depend on how
    # the feed happened to list them.
    reset_jeffersons
    run_import(csv(*rows.reverse))
    assert_equal expected, slug_to_espn, "the widened suffix followed the row index"
  end

  # The rescue is a BACKSTOP, and the ladder above is good enough that no
  # honest CSV reaches it — which is exactly why it needs a test of its own.
  # An untested rescue is a rescue nobody has seen work.
  #
  # The one case the ladder cannot detect for itself is a suffix that is free
  # when it checks and taken when it inserts. Forcing the suffix reproduces
  # that shape against a REAL Person.create! and a REAL unique index, so what
  # is under test is the rescue, not a stubbed error.
  test "a slug collision the ladder cannot see is skipped, not raised" do
    Person.create!(first_name: "Justin", last_name: "Jefferson", athlete: true,
                   disambiguator: "9999")
    incumbent = Person.create!(first_name: "Justin", last_name: "Jefferson", athlete: true)
    Athlete.create!(person_slug: incumbent.slug, sport: "football", espn_id: "111")

    importer = Nflverse::SeedPlayers.new(csv_body: csv, upload_headshots: false)
    importer.define_singleton_method(:disambiguator_for) { |*| "9999" }

    row = CSV.parse(csv(jefferson(gsis: "", espn: "222", position: "LB", team: "CLE")),
                    headers: true).first

    assert_nothing_raised do
      assert_nil importer.ingest_row(row), "a row we cannot slug must be skipped, not ingested"
    end

    assert_equal 1, importer.stats[:namesake_collisions_skipped]
    assert_equal "111", incumbent.athlete_profile.reload.espn_id,
                 "the skipped namesake overwrote the identified athlete"
    assert_equal 2, Person.where(first_name: "Justin", last_name: "Jefferson").count,
                 "the skipped row left a partial Person behind"
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
