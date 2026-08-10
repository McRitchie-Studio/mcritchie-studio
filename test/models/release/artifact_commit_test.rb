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

  # The archive beat's docs sweep retires a BATCH of frozen snapshots (git mv)
  # and rewrites the ledger — one logical change across N paths. Naming only the
  # ledger would read the retirements as unrelated work, refuse the commit, and
  # strand a dozen staged renames as dirt on the primary checkout.
  test "safe to commit when EVERY expected path of a batch retirement is named" do
    porcelain = "R  docs/agents/audits/a-2026-05-01.md -> docs/agents/archive/audits/a-2026-05-01.md\n" \
                "R  docs/agents/audits/b-2026-05-02.md -> docs/agents/archive/audits/b-2026-05-02.md\n" \
                " M #{LEDGER}\n"
    expected = [
      "docs/agents/archive/audits/a-2026-05-01.md",
      "docs/agents/archive/audits/b-2026-05-02.md",
      LEDGER
    ]

    assert A.safe_to_commit?(porcelain, expected)
    assert_empty A.other_dirty_paths(porcelain, expected)
  end

  test "a batch retirement is NOT safe when one of its paths goes unnamed" do
    porcelain = "R  docs/agents/audits/a-2026-05-01.md -> docs/agents/archive/audits/a-2026-05-01.md\n" \
                " M #{LEDGER}\n"

    assert_not A.safe_to_commit?(porcelain, LEDGER),
               "naming only the ledger must refuse, not silently commit a partial batch"
    assert_equal ["docs/agents/archive/audits/a-2026-05-01.md"], A.other_dirty_paths(porcelain, LEDGER)
  end

  test "unrelated dirt still refuses even when the whole batch is named" do
    porcelain = "R  docs/agents/audits/a-2026-05-01.md -> docs/agents/archive/audits/a-2026-05-01.md\n" \
                " M app/models/pokemon.rb\n"

    assert_not A.safe_to_commit?(porcelain, ["docs/agents/archive/audits/a-2026-05-01.md", LEDGER])
  end
end
