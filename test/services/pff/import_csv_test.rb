require "test_helper"
require "csv"
require "tmpdir"

class Pff::ImportCsvTest < ActiveSupport::TestCase
  setup do
    @season = seasons(:nfl_2025)
    @tmpdir = Dir.mktmpdir
  end

  teardown do
    FileUtils.remove_entry(@tmpdir)
  end

  test "detects stat_type from filename" do
    file = write_csv("passing_summary (2).csv", player_csv_headers, [player_csv_row])
    service = Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl")
    assert_equal "passing_summary", service.stat_type
  end

  test "detects stat_type from filename without copy number" do
    file = write_csv("defense_summary.csv", player_csv_headers, [player_csv_row])
    service = Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl")
    assert_equal "defense_summary", service.stat_type
  end

  test "allows explicit stat_type override" do
    file = write_csv("data.csv", player_csv_headers, [player_csv_row])
    service = Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl", stat_type: "passing_summary")
    assert_equal "passing_summary", service.stat_type
  end

  test "imports player-level CSV and creates PffStat" do
    # Use time_in_pocket to avoid collision with allen_passing fixture
    file = write_csv("time_in_pocket.csv", player_csv_headers, [player_csv_row])

    assert_difference "PffStat.count", 1 do
      Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    end

    stat = PffStat.find_by(athlete_slug: "josh-allen-athlete", stat_type: "time_in_pocket")
    assert_equal "time_in_pocket", stat.stat_type
    assert_equal "2025-nfl", stat.season_slug
    assert_equal 17, stat.games_played
    assert_equal 11765, stat.pff_player_id
    assert_equal 92.1, stat.data["grades_pass"]
  end

  test "coerces numeric strings to int/float in JSONB" do
    file = write_csv("passing_depth.csv", player_csv_headers, [player_csv_row])
    Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call

    stat = PffStat.find_by(athlete_slug: "josh-allen-athlete", stat_type: "passing_depth")
    assert_equal 17, stat.data["player_game_count"]     # integer
    assert_equal 92.1, stat.data["grades_pass"]          # float
    assert_equal "Josh Allen", stat.data["player"]       # string
  end

  test "stamps pff_id on athlete" do
    file = write_csv("passing_summary.csv", player_csv_headers, [player_csv_row])
    Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call

    athlete = athletes(:allen_athlete).reload
    assert_equal 11765, athlete.pff_id
  end

  test "is idempotent — re-import updates existing record" do
    file = write_csv("passing_summary.csv", player_csv_headers, [player_csv_row])

    Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    assert_equal 1, PffStat.where(stat_type: "passing_summary", athlete_slug: "josh-allen-athlete").count

    # Re-import — should update, not duplicate
    stats = Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    assert_equal 1, PffStat.where(stat_type: "passing_summary", athlete_slug: "josh-allen-athlete").count
    assert_equal 1, stats[:updated]
  end

  test "creates person and athlete for unknown player" do
    row = ["New Player", "99999", "QB", "BUF", "17", "85.5"]
    file = write_csv("passing_summary.csv", player_csv_headers, [row])

    assert_difference ["Person.count", "Athlete.count"], 1 do
      Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    end

    person = Person.find_by(slug: "new-player")
    assert_equal "New", person.first_name
    assert_equal "Player", person.last_name
    assert person.athlete?
  end

  test "backfills AthleteGrade for passing_summary" do
    file = write_csv("passing_summary.csv",
      %w[player player_id position team_name player_game_count grades_pass grades_offense],
      [["Josh Allen", "11765", "QB", "BUF", "17", "92.0", "91.2"]]
    )
    Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call

    grade = AthleteGrade.find_by(athlete_slug: "josh-allen-athlete", season_slug: "2025-nfl")
    assert_equal 92.0, grade.pass_grade_pff
    assert_equal 91.2, grade.offense_grade_pff
    assert_equal 91.2, grade.overall_grade_pff  # QB = offense side
  end

  test "backfills defense_grade_pff and sets overall for defense player" do
    # Create a defensive player
    person = Person.find_or_create_by!(slug: "calais-campbell") do |p|
      p.first_name = "Calais"
      p.last_name = "Campbell"
      p.athlete = true
    end
    Athlete.find_or_create_by!(person_slug: person.slug) do |a|
      a.sport = "football"
      a.position = "DT"
    end

    file = write_csv("defense_summary.csv",
      %w[player player_id position team_name player_game_count grades_defense grades_coverage_defense grades_pass_rush_defense grades_run_defense],
      [["Calais Campbell", "99364", "DI", "MIA", "17", "82.3", "63.5", "66.2", "85.9"]]
    )
    Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call

    grade = AthleteGrade.find_by(athlete_slug: "calais-campbell-athlete", season_slug: "2025-nfl")
    assert_equal 82.3, grade.defense_grade_pff
    assert_equal 63.5, grade.coverage_grade_pff
    assert_equal 66.2, grade.pass_rush_grade_pff
    assert_equal 85.9, grade.rush_defense_grade_pff
    assert_equal 82.3, grade.overall_grade_pff  # DI = defense side
  end

  test "imports team-level CSV to PffTeamStat" do
    file = write_csv("line_pass_blocking_efficiency.csv",
      %w[team_name franchise_id player_game_count attempts pbe pressures_allowed sacks_allowed],
      [["MIA", "17", "17", "580", "85.2", "160", "30"]]
    )

    assert_difference "PffTeamStat.count", 1 do
      Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    end

    stat = PffTeamStat.find_by(team_slug: "miami-dolphins", stat_type: "line_pass_blocking_efficiency")
    assert_equal "miami-dolphins", stat.team_slug
    assert_equal "line_pass_blocking_efficiency", stat.stat_type
    assert_equal 85.2, stat.data["pbe"]
  end

  test "skips rows with blank player name" do
    file = write_csv("passing_summary.csv", player_csv_headers, [["", "99999", "QB", "BUF", "17", "85.5"]])

    assert_no_difference "PffStat.count" do
      Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    end
  end

  test "skips rows with unknown team for team-level import" do
    file = write_csv("line_pass_blocking_efficiency.csv",
      %w[team_name franchise_id pbe],
      [["UNKNOWN_TEAM", "999", "50.0"]]
    )

    stats = Pff::ImportCsv.new(csv_path: file, season_slug: "2025-nfl").call
    assert_equal 1, stats[:skipped]
  end

  test "raises when season not found" do
    file = write_csv("passing_summary.csv", player_csv_headers, [player_csv_row])
    assert_raises RuntimeError, "Season not found" do
      Pff::ImportCsv.new(csv_path: file, season_slug: "9999-nfl").call
    end
  end

  private

  def player_csv_headers
    %w[player player_id position team_name player_game_count grades_pass]
  end

  def player_csv_row
    ["Josh Allen", "11765", "QB", "BUF", "17", "92.1"]
  end

  def write_csv(filename, headers, rows)
    path = File.join(@tmpdir, filename)
    CSV.open(path, "w") do |csv|
      csv << headers
      rows.each { |r| csv << r }
    end
    path
  end
end
