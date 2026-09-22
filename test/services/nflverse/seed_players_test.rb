require "test_helper"

class Nflverse::SeedPlayersTest < ActiveSupport::TestCase
  HEADERS = %w[
    gsis_id display_name common_first_name first_name last_name short_name
    football_name suffix esb_id nfl_id pfr_id pff_id otc_id espn_id smart_id
    birth_date position_group position ngs_position_group ngs_position
    height weight headshot college_name college_conference jersey_number
    rookie_season last_season latest_team status ngs_status
    ngs_status_short_description years_of_experience pff_position pff_status
    draft_year draft_round draft_pick draft_team
  ].freeze

  def csv_for(rows)
    out = [HEADERS.join(",")]
    rows.each { |r| out << HEADERS.map { |h| r[h].to_s }.join(",") }
    out.join("\n")
  end

  # Use a fictional player so we don't collide with fixtures (Josh Allen et al.)
  def row(overrides = {})
    {
      "gsis_id" => "00-9999991", "first_name" => "Test", "last_name" => "Quarterback",
      "common_first_name" => "Test", "display_name" => "Test Quarterback",
      "position" => "QB", "latest_team" => "BUF", "status" => "ACT",
      "last_season" => "2025", "espn_id" => "9999991", "pff_id" => "999991",
      "otc_id" => "99991", "pfr_id" => "TestQu01", "nfl_id" => "99999991-9999",
      "height" => "77", "weight" => "237"
    }.merge(overrides)
  end

  test "ingests an active player and creates Person + Athlete with all cross-ref IDs" do
    csv_body = csv_for([row])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert person, "Person should be created"

    athlete = person.athlete_profile
    assert athlete, "Athlete should be created"
    assert_equal "00-9999991", athlete.gsis_id
    assert_equal 999991, athlete.pff_id
    assert_equal "99991", athlete.otc_id
    assert_equal "9999991", athlete.espn_id
    assert_equal "TestQu01", athlete.pfr_id
    assert_equal "QB", athlete.position
    assert_equal "buffalo-bills", athlete.team_slug
    assert_equal 77, athlete.height_inches
    assert_equal 237, athlete.weight_lbs
    assert_equal "https://a.espncdn.com/i/headshots/nfl/players/full/9999991.png",
                 athlete.espn_headshot_url
  end

  test "skips inactive (status mismatch) when status_filter is set" do
    csv_body = csv_for([row("status" => "RET", "last_season" => "2025")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false, status_filter: "ACT")
    service.call

    assert_nil Person.find_by(slug: "test-quarterback")
    assert_equal 1, service.stats[:skipped_inactive]
  end

  test "ingests rows of any status when no status_filter (default)" do
    # UFA / RES / PUP players (e.g., late-signing veterans like Hunt/Harris)
    # used to be filtered out by the status=ACT default. Now they pass.
    csv_body = csv_for([row("status" => "UFA", "last_season" => "2026")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert person, "Person should be ingested even with status=UFA"
  end

  test "skips players whose last_season is below MIN_SEASON" do
    csv_body = csv_for([row("last_season" => "2010")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false, min_season: 2024)
    service.call

    assert_nil Person.find_by(slug: "test-quarterback")
    assert_equal 1, service.stats[:skipped_old]
  end

  test "uses gsis_id to find existing Athlete (resilient to name typos)" do
    person = Person.create!(first_name: "Tester", last_name: "Quarterback", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", gsis_id: "00-9999991")

    csv_body = csv_for([row])  # CSV says "Test Quarterback", DB has "Tester Quarterback"
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    athlete.reload
    assert_equal "buffalo-bills", athlete.team_slug
    assert_equal "9999991", athlete.espn_id
  end

  test "ID hierarchy wins over name match (split-record scenario)" do
    # Reproduces the Will Anderson Jr. failure: PFF imported the canonical
    # "Will Anderson Jr." → person+athlete with pff_id=999. Spotrac stripped
    # the suffix → separate "Will Anderson" person+athlete (no IDs). nflverse
    # row last_name="Anderson" name-matches the Spotrac one and tries to
    # write pff_id=999 → unique-constraint collision under the old code.
    canonical_person = Person.create!(first_name: "Will", last_name: "Anderson Jr.", athlete: true)
    canonical_athlete = Athlete.create!(person_slug: canonical_person.slug, sport: "football", pff_id: 999991)

    duplicate_person = Person.create!(first_name: "Will", last_name: "Anderson", athlete: true)
    Athlete.create!(person_slug: duplicate_person.slug, sport: "football")

    # nflverse row uses bare last_name "Anderson" but pff_id matches the canonical
    csv_body = csv_for([row("first_name" => "Will", "common_first_name" => "Will", "last_name" => "Anderson",
                              "gsis_id" => "00-9999992", "pff_id" => "999991", "espn_id" => "ww-1", "otc_id" => "wo-1")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    # Canonical record (matched by pff_id) gets the new IDs
    canonical_athlete.reload
    assert_equal "00-9999992", canonical_athlete.gsis_id
    assert_equal "ww-1", canonical_athlete.espn_id

    # Duplicate athlete left untouched — no failure logged
    assert_equal 0, service.stats[:athletes_failed]
    assert_equal 1, service.stats[:athletes_updated]
  end

  test "a conflicting secondary identity refuses name-based adoption" do
    service = Nflverse::SeedPlayers.new(csv_body: csv_for([]), upload_headshots: false)
    existing = Athlete.new(espn_id: "111", pff_id: 222)

    matching = { gsis_id: nil, espn_id: "111", pff_id: nil, otc_id: nil, pfr_id: nil,
                 nflverse_id: nil }
    conflicting = matching.merge(espn_id: "333")

    assert service.send(:adoptable_name_match?, existing, matching)
    assert_not service.send(:adoptable_name_match?, existing, conflicting)
    assert service.send(:adoptable_name_match?, Athlete.new, conflicting),
           "an unidentified hand-entered athlete should still be adopted"
  end

  test "prefers pff_position over generic position (3-4 OLB → EDGE)" do
    # nflverse generic position = "OLB" → NFLVERSE_MAP collapses to "LB",
    # but pff_position = "ED" disambiguates as edge rusher (T.J. Watt case)
    csv_body = csv_for([row("position" => "OLB", "pff_position" => "ED")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert_equal "EDGE", person.athlete_profile.position
  end

  test "falls back to nflverse position when pff_position is blank" do
    csv_body = csv_for([row("position" => "DE", "pff_position" => "")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert_equal "EDGE", person.athlete_profile.position
  end

  test "normalizes position via :nflverse source map" do
    csv_body = csv_for([row("position" => "T", "latest_team" => "BUF")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert_equal "OT", person.athlete_profile.position
  end

  test "leaves team_slug nil for unknown latest_team abbreviation" do
    csv_body = csv_for([row("latest_team" => "XXX")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert_nil person.athlete_profile.team_slug
  end

  test "ingest_row returns nil when first or last name is blank" do
    service = Nflverse::SeedPlayers.new(csv_body: HEADERS.join(","), upload_headshots: false)
    result = service.ingest_row(CSV::Row.new(HEADERS, ["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""]))
    assert_nil result
    assert_equal 1, service.stats[:skipped_no_name]
  end

  test "headshot_url is omitted when espn_id missing" do
    csv_body = csv_for([row("espn_id" => "")])
    service = Nflverse::SeedPlayers.new(csv_body: csv_body, upload_headshots: false)
    service.call

    person = Person.find_by(slug: "test-quarterback")
    assert_nil person.athlete_profile.espn_headshot_url
  end
end
