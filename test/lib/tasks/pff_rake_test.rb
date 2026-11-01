require "test_helper"
require "rake"
require "tmpdir"

# [unit] lib/tasks/pff.rake with the files absent: the refusal reaches stderr and
# exits non-zero, and pff:build_rosters no longer reports "Done" over zero rows.
class PffRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pff:import")
    Rake::Task.tasks.each { |t| t.reenable if t.name.start_with?("pff:", "nfl:") }
    @was = ENV.to_h.slice("FILE", "DIR", "SEASON")
  end

  teardown do
    %w[FILE DIR SEASON].each { |k| @was.key?(k) ? ENV[k] = @was[k] : ENV.delete(k) }
  end

  test "pff:import names a missing file on stderr and exits non-zero" do
    ENV["FILE"] = "/no/such/passing_summary.csv"
    assert_match(/File not found: \/no\/such/, refused("pff:import"))
  end

  test "pff:import_starters names a missing file on stderr and exits non-zero" do
    ENV["FILE"] = "/no/such/starters.csv"
    assert_match(/File not found: \/no\/such/, refused("pff:import_starters"))
  end

  test "pff:import_dir refuses a missing directory and an empty one" do
    ENV["DIR"] = "/no/such/dir"
    assert_match(/Directory not found/, refused("pff:import_dir"))

    Rake::Task["pff:import_dir"].reenable
    Dir.mktmpdir do |dir|
      ENV["DIR"] = dir
      assert_match(/No PFF CSV files found/, refused("pff:import_dir"))
    end
  end

  test "pff:build_rosters refuses a season with no imported stats" do
    PffStat.where(season_slug: "2025-nfl").delete_all
    ENV["SEASON"] = "2025-nfl"
    skip "fixtures hold no offseason slate" unless seasons(:nfl_2025).slates.exists?(sequence: 0)

    assert_match(/no imported PFF stats/, refused("pff:build_rosters"))
  end

  # The all-zero refusal cannot see this world: prospects still score.
  test "nfl:rankings_compute warns on stderr when the grade season has no imported stats" do
    ENV["SEASON"] = "2025-nfl"
    _out, err = capture_io { Rake::Task["nfl:rankings_compute"].invoke }
    assert_no_match(/no imported PFF stats/, err)

    PffStat.where(season_slug: "2025-nfl").delete_all
    Rake::Task["nfl:rankings_compute"].reenable
    _out, err = capture_io { Rake::Task["nfl:rankings_compute"].invoke }
    assert_match(/2025-nfl has no imported PFF stats: these TeamRanking scores rest on draft-tier/, err)
  end

  test "nfl:assign_grades warns on stderr when the season has no imported stats" do
    PffStat.where(season_slug: "2025-nfl").delete_all
    ENV["SEASON"] = "2025-nfl"
    _out, err = capture_io { Rake::Task["nfl:assign_grades"].invoke }
    assert_match(/2025-nfl has no imported PFF stats: these pass\/run letter grades/, err)
  end

  private

  def refused(name)
    err = nil
    capture_io do
      error = assert_raises(SystemExit) { Rake::Task[name].invoke }
      assert_not error.success?, "#{name} must exit non-zero"
    end.then { |_out, stderr| err = stderr }
    err
  end
end
