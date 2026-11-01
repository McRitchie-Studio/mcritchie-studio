require "test_helper"
require "open3"

# [unit] Alex McRitchie's ruling of 2026-11-01: PFF's files do not live in this public
# repo. The seed directory's old workflow was "drop new CSVs in and reseed", so the
# path stays ignored and this fails if a file is force-added.
class PffDataNotInRepoTest < ActiveSupport::TestCase
  test "nothing is tracked under the PFF data paths" do
    tracked, status = Open3.capture2("git", "ls-files", "db/seeds/data/pff", "lib/pff", chdir: Rails.root.to_s)

    assert status.success?, "git ls-files could not read the tree"
    assert_empty tracked
  end

  test "a file dropped in the seed directory is ignored" do
    _, status = Open3.capture2("git", "check-ignore", "-q", "db/seeds/data/pff/passing_summary.csv", chdir: Rails.root.to_s)

    assert status.success?, "db/seeds/data/pff/ must stay in .gitignore"
  end
end
