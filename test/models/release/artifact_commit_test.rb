require "test_helper"

# Pure decision for committing a generated retro/ledger doc to `release`. No git
# here — same IO-free contract as ShipSequence; bin/release owns the shell.
class Release::ArtifactCommitTest < ActiveSupport::TestCase
  A = Release::ArtifactCommit
  DOC = "docs/agents/audits/retro-rel-20260626-299b25.md".freeze
  LEDGER = "docs/agents/maintenance/delete-later.md".freeze

  test "safe to commit when the new retro doc is the only dirty path" do
    assert A.safe_to_commit?("?? #{DOC}\n", DOC)
    assert_equal [], A.other_dirty_paths("?? #{DOC}\n", DOC)
  end

  test "safe to commit when the ledger is the only (tracked) modification" do
    assert A.safe_to_commit?(" M #{LEDGER}\n", LEDGER)
  end

  test "safe to commit when the tree is otherwise clean" do
    assert A.safe_to_commit?("", DOC)
    assert A.safe_to_commit?("?? #{DOC}", DOC) # trailing-newline-free porcelain
  end

  test "NOT safe when any other file is dirty — leave it for the preflight" do
    porcelain = "?? #{DOC}\n M app/models/pokemon.rb\n"
    assert_not A.safe_to_commit?(porcelain, DOC)
    assert_equal ["app/models/pokemon.rb"], A.other_dirty_paths(porcelain, DOC)
  end

  test "other_dirty_paths takes the NEW path of a rename and excludes the doc" do
    porcelain = "R  app/old.rb -> app/new.rb\n?? #{DOC}\n"
    assert_equal ["app/new.rb"], A.other_dirty_paths(porcelain, DOC)
  end
end
