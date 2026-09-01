# frozen_string_literal: true

require "digest"
require "date"

# DeskLedgerImport — harvest desk rows stranded in the markdown ledger, and key them so
# the import can be run twice.
#
# THE DEFECT THAT STRANDED THEM. `bin/agent-worktree` appended its teardown row to
# docs/agents/maintenance/delete-later.md resolved against HUB_DIR. Cleanups run from the
# PRIMARY checkout, which sits on `main` — a branch nobody may commit to. So every sweep
# wrote an audit row it could never save, and stashed it "to restore later". Between
# 2026-06-27 and 2026-08-31 that happened thirteen times and not one stash was ever
# restored. `ledger-writes-to-primary` closed the defect by sending new records to the
# board; this module recovers the ones already lost to it.
#
# READ-ONLY, ALWAYS. The rows are recovered from `git show stash@{N}:<file>` and from the
# primary's uncommitted working tree. Nothing is applied, dropped, or checked out — which
# also means the harvest does not have to wait on a primary that is dirty, and cannot lose
# a stash that turns out to carry feature code alongside its ledger row. `git stash apply`
# is not an option in any case: the sources sit on thirteen DIFFERENT bases, each expecting
# a different file tail, so applying them in sequence self-conflicts.
#
# WHY THE WHOLE FILE, NOT THE DIFF. Each stash is read as the ledger it CONTAINED, and
# every row in it is compared against the baseline. Harvesting a stash's `+` lines instead
# would miss a row that some later sweep deleted from the file before the stash was taken,
# and would double-count a row that merely moved between the ledger and its archive on an
# `archive-shipped` roll — stash@{1} is exactly such a roll, 155 insertions against 29
# deletions spanning both files.
module DeskLedgerImport
  LEDGER  = "docs/agents/maintenance/delete-later.md"
  ARCHIVE = "docs/agents/archive/maintenance/delete-later-archive.md"
  FILES = [LEDGER, ARCHIVE].freeze

  # The cell separator used to build the digest. A unit separator (U+241F) cannot occur in
  # a markdown table cell, so no arrangement of cell text can forge another row's key.
  CELL_JOIN = "␟"

  # Only `worktree` rows are desk episodes. The ledger also carries hand-written rows for
  # files and docs ("local memory", "reference only") — those belong in the markdown file
  # and are NOT desk records; importing them would invent a desk that never existed.
  DESK_TYPE = "worktree"

  RESOLVED = /\bremoved\s+(\d{4}-\d{2}-\d{2})\b/

  module_function

  # A ledger row is a markdown table row of five cells. The header and the `|---|`
  # separator are not rows.
  def table_row?(line)
    return false unless line.start_with?("|")
    return false if line =~ /\A\|\s*:?-{2,}/
    return false if line =~ /\A\|\s*Path\s*\|/i

    line.count("|") >= 5
  end

  def cells(row)
    row.sub(/\A\|/, "").sub(/\|\s*\z/, "").split("|").map(&:strip)
  end

  def rows_from(text)
    text.to_s.lines.map(&:chomp).select { |line| table_row?(line) }
  end

  # THE IDEMPOTENCY KEY. A digest of the row's five cells, each with internal whitespace
  # collapsed, joined by a separator that cannot appear inside one.
  #
  # It is the row text and NOTHING ELSE. Two teardowns of a recycled desk path differ in
  # their date, HEAD, and rationale, so they key apart and both survive; the identical row
  # recovered from two different stashes keys together and lands once. Whitespace is
  # collapsed only so a row that was re-wrapped between two stashes does not read as two
  # episodes — no cell is dropped, so no semantic field is being ignored.
  def import_key(row)
    Digest::SHA256.hexdigest(cells(row).map { |cell| cell.gsub(/\s+/, " ") }.join(CELL_JOIN))
  end

  def desk_row?(row)
    parts = cells(row)
    parts[1].to_s.casecmp?(DESK_TYPE) && parts[4].to_s.match?(RESOLVED)
  end

  def unbacktick(value) = value.to_s.gsub("`", "").strip

  # Map one ledger row onto DeskRecord columns.
  #
  # Only fields the row DELIMITS are lifted out of its prose: the branch and HEAD are
  # written inside backticks and a fixed `HEAD <sha>` phrase by the sweep that wrote them.
  # Everything else stays whole in `reason`, and the row itself is kept verbatim in the
  # payload — so nothing is lost to a regex that guessed, and the record can always be
  # audited back to the stash it came from.
  def attributes_for(row, source: nil, file: nil)
    parts = cells(row)
    path = unbacktick(parts[0])
    app, desk = path.match(%r{/projects/([^/]+)/\.worktrees/([^/]+)\z})&.captures

    {
      import_key: import_key(row),
      worktree_path: path,
      resolved_on: Date.parse(parts[4][RESOLVED, 1]),
      app_slug: app,
      desk_slug: desk,
      label: (app && desk) ? "#{app}/#{desk}" : path,
      reason: parts[2],
      safe_delete_condition: parts[3],
      branch: parts[2][/branch `([^`]+)`/, 1],
      head: parts[2][/\bHEAD ([0-9a-f]{7,40})\b/, 1],
      payload: {
        "ledger_row" => row,
        "ledger_file" => file,
        "recovered_from" => source,
        "status_cell" => parts[4]
      }.compact
    }
  end
end
