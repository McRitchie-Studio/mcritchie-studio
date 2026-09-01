# frozen_string_literal: true

# bin/lib/desk_ledger_import.rb — the key that lets the stranded-row harvest be re-run.
#
# The harvest reads thirteen stashes across thirteen bases plus the primary's uncommitted
# tree; a job with fourteen inputs is re-run, and `DeskRecord.file!` cannot absorb the
# second run because it resolves an existing record through the OPEN episode for the desk
# path and every stranded row is a RESOLVED teardown. So identity has to come from the row
# itself, and these assert the two directions that identity can fail in — collapsing two
# real teardowns into one, or splitting one teardown into two.
require "minitest/autorun"
require_relative "../../bin/lib/desk_ledger_import"

class DeskLedgerImportTest < Minitest::Test
  # Real rows, verbatim from stash@{0} and stash@{2} — the recycled `_ship` path that makes
  # the path-vs-text distinction load-bearing.
  SHIP_0821 = "| `/Users/alex/projects/mcritchie-studio/.worktrees/_ship` | worktree | " \
              "Hidden worktree; branch `release` is clean and HEAD 96f30d99 is contained in " \
              "origin/accepted. | Removed with `bin/agent-worktree remove mcritchie-studio _ship " \
              "--yes` during approved lifecycle cleanup. | removed 2026-08-21 |"
  SHIP_0729 = "| `/Users/alex/projects/mcritchie-studio/.worktrees/_ship` | worktree | " \
              "Hidden worktree; branch `release` is clean and HEAD 9a8dc1a6 is contained in " \
              "origin/accepted. | Removed with `bin/agent-worktree remove mcritchie-studio _ship " \
              "--yes` during approved lifecycle cleanup. | removed 2026-07-29 |"

  # ---- [unit] the key must not COLLAPSE distinct teardowns -------------------------

  # THE PROPERTY THE WHOLE HARVEST RESTS ON. `_ship` is torn down every release cycle at
  # the same path. In the live harvested set that path carries five distinct teardowns
  # under mcritchie-studio and three under turf-monster, so a path-keyed import would
  # destroy six teardown records — the loss of 2026-08-21 that bin/ledger-guard exists to
  # refuse. Same path, same type, same safe-delete condition; only the date and HEAD move.
  def test_same_desk_path_torn_down_twice_keys_apart
    refute_equal DeskLedgerImport.import_key(SHIP_0821),
                 DeskLedgerImport.import_key(SHIP_0729),
                 "two teardowns of a recycled path are two episodes; keying them together " \
                 "silently destroys the earlier one"
  end

  # ---- [unit] the key must not SPLIT one teardown ----------------------------------

  # The same row recovered from two different stashes must land ONCE. The stashes were
  # taken at different times against different bases, so the same row reaches the harvest
  # re-wrapped; collapsing internal whitespace is what makes that one episode. No cell is
  # dropped, so no semantic field is being ignored to get there.
  def test_same_row_rewrapped_keys_together
    rewrapped = SHIP_0821.gsub("Hidden worktree;", "Hidden   worktree;\n").gsub(" | worktree | ", "  |  worktree  |  ")
    assert_equal DeskLedgerImport.import_key(SHIP_0821),
                 DeskLedgerImport.import_key(rewrapped.delete("\n"))
  end

  # A change in ANY cell is a different row. Guards the collapse above from being widened
  # into a normalization that starts ignoring content.
  def test_a_changed_cell_changes_the_key
    %w[_ship worktree 96f30d99 approved 2026-08-21].each do |token|
      altered = SHIP_0821.sub(token, "#{token}X")
      refute_equal DeskLedgerImport.import_key(SHIP_0821), DeskLedgerImport.import_key(altered),
                   "changing #{token.inspect} must change the key"
    end
  end

  # The digest joins cells with a separator, so a cell boundary is part of the identity.
  # These two rows CONCATENATE to the same string — "xy" in one cell, versus "x" and "y"
  # in two — so a digest taken over the joined text with no separator would call them one
  # episode. An earlier draft of this test picked a pair that did not actually collide and
  # passed against the unseparated implementation; this pair kills it.
  def test_cell_boundaries_cannot_be_forged
    a = "| `/a` | worktree | xy |  | removed 2026-08-21 |"
    b = "| `/a` | worktree | x | y | removed 2026-08-21 |"

    assert_equal DeskLedgerImport.cells(a).join, DeskLedgerImport.cells(b).join,
                 "the pair must actually collide without a separator, or this test proves nothing"
    refute_equal DeskLedgerImport.import_key(a), DeskLedgerImport.import_key(b)
  end

  # ---- [unit] what counts as a row, and as a DESK row ------------------------------

  def test_header_and_separator_are_not_rows
    text = <<~MD
      | Path | Type | Why it is a candidate | Safe-delete condition | Status |
      |------|------|-----------------------|-----------------------|--------|
      #{SHIP_0821}
    MD
    assert_equal [SHIP_0821], DeskLedgerImport.rows_from(text)
  end

  # The ledger also carries HAND-WRITTEN rows about files and docs. They are not desk
  # episodes and importing them would invent a desk that never existed, so the harvest
  # leaves them in the markdown where they belong.
  def test_non_worktree_rows_are_not_desk_rows
    memory = "| `/Users/alex/.claude/agents/*.md` | local memory | Character files are Claude-specific. | " \
             "Promoted into McRitchie Studio docs. | reference only |"
    assert DeskLedgerImport.desk_row?(SHIP_0821)
    refute DeskLedgerImport.desk_row?(memory)
  end

  # An OPEN desk row (`pending approval`) is not a completed teardown. Importing one as a
  # resolved episode would fabricate a removal date for a desk nobody tore down.
  def test_open_desk_rows_are_not_importable
    pending = SHIP_0821.sub("removed 2026-08-21", "pending approval")
    refute DeskLedgerImport.desk_row?(pending)
  end

  # ---- [unit] the column mapping ---------------------------------------------------

  def test_attributes_lift_only_delimited_fields
    attrs = DeskLedgerImport.attributes_for(SHIP_0821, source: "stash@{0}", file: DeskLedgerImport::LEDGER)

    assert_equal "/Users/alex/projects/mcritchie-studio/.worktrees/_ship", attrs[:worktree_path]
    assert_equal Date.new(2026, 8, 21), attrs[:resolved_on]
    assert_equal "mcritchie-studio", attrs[:app_slug]
    assert_equal "_ship", attrs[:desk_slug]
    assert_equal "release", attrs[:branch]
    assert_equal "96f30d99", attrs[:head]
    # The row survives verbatim, so a record can always be audited back to the stash it
    # came from and nothing is lost to a regex that guessed at prose.
    assert_equal SHIP_0821, attrs[:payload]["ledger_row"]
    assert_equal "stash@{0}", attrs[:payload]["recovered_from"]
  end

  # A row whose prose does not carry a branch or HEAD must import with those blank rather
  # than with a fragment of the sentence around them.
  def test_missing_optional_fields_are_nil_not_garbage
    sparse = "| `/Users/alex/projects/rolio/.worktrees/x` | worktree | Cleared by operator. | " \
             "Removed during cleanup. | removed 2026-07-14 |"
    attrs = DeskLedgerImport.attributes_for(sparse)

    assert_nil attrs[:branch]
    assert_nil attrs[:head]
    assert_equal "rolio", attrs[:app_slug]
    assert_equal Date.new(2026, 7, 14), attrs[:resolved_on]
  end
end
