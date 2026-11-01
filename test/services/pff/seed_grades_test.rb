require "test_helper"
require "tmpdir"

# [unit] The repo ships no PFF data, so seed 29 running on no files is the normal
# case. A skip exits 0, so stderr is the seed's only way to say what is missing.
class Pff::SeedGradesTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/29_pff_grades.rb").to_s

  setup { @dir = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@dir) }

  test "an empty directory imports nothing and warns on stderr, naming the loss and the recovery" do
    count = nil
    out, err = capture_io do
      assert_no_difference("PffStat.count") { count = seed_grades(@dir).call }
    end

    assert_equal 0, count
    assert_match(/no CSVs in db\/seeds\/data\/pff/, err)
    assert_match(/flat 50\.0 placeholder/, err)
    assert_match(/pff:import_dir/, err)
    assert_empty out, "the warning belongs on stderr: nothing reads a seed's stdout"
  end

  test "a directory that does not exist warns the same way" do
    _out, err = capture_io { assert_equal 0, seed_grades(File.join(@dir, "gone")).call }

    assert_match(/imported nothing/, err)
  end

  test "the warning survives $VERBOSE nil, which silences Kernel#warn" do
    was = $VERBOSE
    $VERBOSE = nil
    _out, err = capture_io { seed_grades(@dir).call }
    assert_match(/imported nothing/, err)
  ensure
    $VERBOSE = was
  end

  test "a partial set imports what is there and names what is absent" do
    write_passing_csv

    count = nil
    _out, err = capture_io { count = seed_grades(@dir).call }

    assert_equal 1, count
    assert PffStat.exists?(athlete_slug: "josh-allen-athlete", stat_type: "passing_summary")
    assert_match(/10 of 11 stat files absent/, err)
    assert_match(/rushing_summary/, err)
    refute_match(/passing_summary/, err)
  end

  test "a full set stays quiet on stderr" do
    Pff::ImportCsv::POSITION_FILTER.each_key { |type| write_passing_csv(type) }

    _out, err = capture_io { seed_grades(@dir).call }

    assert_empty err
  end

  # The seed file itself. glob is stubbed so an operator's gitignored export on this
  # machine cannot change the answer; the tree guard is pff_data_not_in_repo_test.rb.
  test "seed 29 with no files loads, imports nothing and warns" do
    _out, err = capture_io do
      Dir.stub(:glob, []) do
        assert_no_difference("PffStat.count") { load SEED }
      end
    end

    assert_match(/imported nothing/, err)
  end

  test "warn_unless_imported is quiet with rows and speaks without them" do
    _out, err = capture_io { assert Pff::SeedGrades.warn_unless_imported("2025-nfl", consequence: "x") }
    assert_empty err, "the fixtures hold 2025-nfl rows"

    PffStat.where(season_slug: "2025-nfl").delete_all
    _out, err = capture_io { refute Pff::SeedGrades.warn_unless_imported("2025-nfl", consequence: "scores are hollow") }
    assert_match(/2025-nfl has no imported PFF stats: scores are hollow/, err)
  end

  # A missing file is an operator's typo, not a skip.
  test "the importer raises on a file that is not there" do
    assert_raises(Errno::ENOENT) do
      Pff::ImportCsv.new(csv_path: File.join(@dir, "passing_summary.csv"), season_slug: "2025-nfl").call
    end
    assert_raises(Errno::ENOENT) do
      Pff::ImportStarters.new(csv_path: File.join(@dir, "starters.csv"), season_slug: "2025-nfl").call
    end
  end

  private

  def seed_grades(dir) = Pff::SeedGrades.new(season_slug: "2025-nfl", dir: dir)

  # Synthetic row. No PFF value lives in this repo, tests included.
  def write_passing_csv(type = "passing_summary")
    File.write(File.join(@dir, "#{type}.csv"), <<~CSV)
      player,player_id,position,team_name,player_game_count,grades_pass
      Josh Allen,99001,QB,BUF,17,70.0
    CSV
  end
end
