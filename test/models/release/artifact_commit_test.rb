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

  test "a trailing-newline-free porcelain still parses" do
    assert A.safe_to_commit?("?? #{DOC}", DOC)
  end

  # ── the whole decision, as a table ──────────────────────────────────────────
  #
  # THE PIN THIS REPLACES. Until 2026-09-13 this file asserted
  # `assert A.safe_to_commit?("", DOC)` under the name "safe to commit when the
  # tree is otherwise clean" — and that pin is what made the defect permanent.
  # `safe_to_commit?` was `other_dirty_paths(...).empty?`, which a CLEAN tree
  # satisfies vacuously, while the comment above it always claimed the stronger
  # conjunction ("the expected doc(s) are the ONLY things dirty"). So the caller
  # flipped the SHARED primary checkout — `checkout release`, a `git commit` that
  # silently did nothing, `ensure { checkout main }` — on every run with nothing
  # to commit: 191 measured flip pairs on 2026-09-10 with ZERO commits behind
  # them. The code moved to meet the comment; this table is the comment made
  # executable.
  {
    "clean tree — nothing to do, and no reason to flip a shared checkout" =>
      { porcelain: "", safe: false, nothing: true },
    "expected doc modified" =>
      { porcelain: " M #{DOC}\n", safe: true, nothing: false },
    "expected doc UNTRACKED — a first run must still commit, not no-op" =>
      { porcelain: "?? #{DOC}\n", safe: true, nothing: false },
    "expected doc staged" =>
      { porcelain: "A  #{DOC}\n", safe: true, nothing: false },
    "only OTHER paths dirty — refuse, and there is nothing of ours anyway" =>
      { porcelain: " M app/models/pokemon.rb\n", safe: false, nothing: true },
    "expected AND other dirty — the original refusal, unchanged" =>
      { porcelain: "?? #{DOC}\n M app/models/pokemon.rb\n", safe: false, nothing: false }
  }.each do |name, row|
    test "decision table: #{name}" do
      assert_equal row[:safe], A.safe_to_commit?(row[:porcelain], DOC),
                   "safe_to_commit? disagrees with the table for: #{name}"
      assert_equal row[:nothing], A.nothing_to_commit?(row[:porcelain], DOC),
                   "nothing_to_commit? disagrees with the table for: #{name}"
    end
  end

  # The two refusals are DIFFERENT and the caller reports them differently — one
  # is "no work", the other is "unrelated work present". Collapsing them would
  # have the archive beat tell an operator that a clean tree has other changes.
  test "a clean tree and a dirty-elsewhere tree refuse for different reasons" do
    assert A.nothing_to_commit?("", DOC)
    assert_empty A.other_dirty_paths("", DOC)

    assert A.nothing_to_commit?(" M app/models/pokemon.rb\n", DOC)
    assert_equal ["app/models/pokemon.rb"], A.other_dirty_paths(" M app/models/pokemon.rb\n", DOC)
  end

  test "a rename of an expected path counts as dirty by its NEW name" do
    porcelain = "R  docs/agents/audits/old.md -> #{DOC}\n"

    assert_equal [DOC], A.expected_dirty_paths(porcelain, DOC)
    assert A.safe_to_commit?(porcelain, DOC)
    refute A.nothing_to_commit?(porcelain, DOC)
  end

  test "a batch is dirty when ANY of its expected paths is" do
    porcelain = " M #{LEDGER}\n"
    expected = ["docs/agents/archive/audits/a-2026-05-01.md", LEDGER]

    assert_equal [LEDGER], A.expected_dirty_paths(porcelain, expected)
    assert A.safe_to_commit?(porcelain, expected),
           "a partially-dirty batch still has work to commit; only an ENTIRELY clean one does not"
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
