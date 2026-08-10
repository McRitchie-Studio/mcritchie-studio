# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

# DocsArchive — retire frozen snapshots out of the LIVE doc tree, on the archive
# beat, and roll over the delete-later ledger.
#
# Audits from May, release retros from June, a closeout from the 14th: all true
# when written, all frozen on purpose, all sitting in the same folders as the
# living instructions. Every doc sweep and terminology pass wades through them.
#
# NEVER DELETES. Every retirement is a `git mv` into docs/agents/archive/,
# mirroring the source subdirectory. History survives either way, but a move
# keeps a stale inbound link resolvable by search instead of turning it into a
# dead end — and mirroring the subdirectory keeps sibling cross-links (the
# prelaunch cluster links to itself by bare filename) resolving after the move.
#
# A file QUALIFIES when BOTH hold:
#   1. its name carries a date (YYYY-MM-DD or retro-rel-*) OR it lives in
#      docs/agents/audits/; AND
#   2. nothing in the live tree references it — checked at RUN TIME, per file.
#
# Both halves matter, and both are load-bearing against real data in this repo:
#   * Rule 1 alone would sweep live handoffs — the undated kickoff/parking-lot
#     docs in maintenance/ are current instructions.
#   * Rule 2 alone would sweep nothing, because these snapshots cross-reference
#     each other: prelaunch-audit-2026-05-24-{carl,jasper,steffon} are referenced
#     ONLY by prelaunch-audit-2026-05-24-synthesis, itself a candidate. So a
#     reference FROM ANOTHER CANDIDATE does not count as a live reference — after
#     the sweep that referrer is not in the live tree either. A reference from
#     anything that STAYS (a module doc, config/satellites.yml, bin/dor-check)
#     pins the file where it is, and it is named in the report instead.
module DocsArchive
  ARCHIVE_DIR = "docs/agents/archive"
  DOCS_ROOT   = "docs"
  AUDITS_DIR  = "docs/agents/audits"
  LEDGER      = "docs/agents/maintenance/delete-later.md"
  LEDGER_ARCHIVE = "#{ARCHIVE_DIR}/maintenance/delete-later-archive.md"

  DATE_IN_NAME = /\d{4}-\d{2}-\d{2}/
  RETRO_NAME   = /\Aretro-rel-/
  DATE_ANY     = /(\d{4}-\d{2}-\d{2})/

  module_function

  # ---- rule 1 -------------------------------------------------------------

  def frozen_shape?(rel_path)
    return false unless rel_path.end_with?(".md")
    return false if rel_path.start_with?("#{ARCHIVE_DIR}/")
    return true  if rel_path.start_with?("#{AUDITS_DIR}/")

    base = File.basename(rel_path)
    base.match?(DATE_IN_NAME) || base.match?(RETRO_NAME)
  end

  # Every tracked doc matching rule 1. Tracked-only (git ls-files) on purpose:
  # an untracked scratch file is not ours to move, and `git mv` would fail on it.
  def candidates(repo)
    git(repo, "ls-files", "--", DOCS_ROOT)
      .lines.map(&:chomp).reject(&:empty?)
      .select { |path| frozen_shape?(path) }
      .sort
  end

  # ---- rule 2 -------------------------------------------------------------

  # Who, in the tree that will STILL be live after this sweep, mentions this
  # file? Matches on basename: markdown links, doc tables, and code comments all
  # cite these by filename, and a basename match is the broad (fail-safe) end of
  # that — it over-reports a reference rather than orphaning a live citation.
  def referrers(repo, rel_path, candidate_set)
    base = File.basename(rel_path)
    git(repo, "grep", "--name-only", "--fixed-strings", base)
      .lines.map(&:chomp).reject(&:empty?)
      .reject { |hit| hit == rel_path }
      .reject { |hit| hit.start_with?("#{ARCHIVE_DIR}/") }
      .reject { |hit| candidate_set.include?(hit) }
      .sort
  rescue CommandFailed
    [] # git grep exits 1 on "no matches" — that is the answer, not an error.
  end

  # Where a retired file lands: the same subdirectory, under the archive root, so
  # co-archived siblings keep resolving each other's relative links.
  def archive_path_for(rel_path)
    File.join(ARCHIVE_DIR, rel_path.sub(%r{\Adocs/agents/}, "").sub(%r{\Adocs/}, ""))
  end

  # The plan: what moves, and what is pinned by a live citation.
  def plan(repo)
    set = candidates(repo)
    lookup = set.to_h { |path| [path, true] }

    moves = []
    skipped = []
    set.each do |path|
      pinned = referrers(repo, path, lookup)
      if pinned.empty?
        moves << { from: path, to: archive_path_for(path) }
      else
        skipped << { path: path, referrers: pinned }
      end
    end

    { moves: moves, skipped: skipped }
  end

  # ---- applying -----------------------------------------------------------

  def apply_moves!(repo, moves)
    moves.each do |move|
      target = File.join(repo, move[:to])
      FileUtils.mkdir_p(File.dirname(target))
      git(repo, "mv", move[:from], move[:to])
    end
    moves.size
  end

  # ---- the delete-later ledger --------------------------------------------

  # PURE. Split the ledger into what stays live and what rolls over.
  #
  # A row rolls over when its Status cell carries a date STRICTLY OLDER than the
  # cutoff. Everything else stays, and that deliberately includes every row with
  # NO date — "pending approval" and "reference only" are UNRESOLVED items, not
  # history, and rolling those into an archive would hide live work.
  def split_ledger(content, cutoff)
    kept = []
    rolled = []
    content.lines.each do |line|
      unless data_row?(line)
        kept << line
        next
      end

      date = row_date(line)
      if date && cutoff && date < cutoff
        rolled << line
      else
        kept << line
      end
    end
    { kept: kept.join, rolled: rolled }
  end

  # A table data row (not the header, not the |---|---| separator).
  def data_row?(line)
    line.start_with?("|") && !line.match?(/\A\|[\s-]+\|/) && !line.start_with?("| Path ")
  end

  # The date out of the row's LAST cell (Status). Note the trailing pipe: a row
  # reads "… | removed 2026-06-13 |\n", so a naive split("|").last is the
  # newline, never the status — which reads as "no date" and silently rolls
  # nothing. Strip the row and drop the closing pipe before taking the last cell.
  def row_date(line)
    line.strip.sub(/\|\z/, "").split("|").last.to_s[DATE_ANY, 1]
  end

  # Default cutoff when no release boundary is supplied: the newest date in the
  # ledger. "Older than one release cycle" expressed with local data only —
  # everything before the most recent run rolls, the most recent run stays. It is
  # idempotent by construction: after a rollover the newest date is the only one
  # left, so a re-run finds nothing older.
  def newest_ledger_date(content)
    content.lines.select { |l| data_row?(l) }.filter_map { |l| row_date(l) }.max
  end

  LEDGER_ARCHIVE_HEADER = <<~MD
    # Delete Later Ledger — Archive

    Rolled-over rows from `docs/agents/maintenance/delete-later.md`, retired on the
    `archive-shipped` beat once their release cycle closed. Historical record only:
    every row here was already resolved. Live and unresolved entries stay in the
    ledger itself.

    | Path | Type | Why it is a candidate | Safe-delete condition | Status |
    |------|------|-----------------------|-----------------------|--------|
  MD

  def roll_ledger!(repo, cutoff: nil, apply:)
    path = File.join(repo, LEDGER)
    return { rolled: 0, cutoff: cutoff } unless File.file?(path)

    content = File.read(path)
    cutoff ||= newest_ledger_date(content)
    split = split_ledger(content, cutoff)
    return { rolled: 0, cutoff: cutoff } if split[:rolled].empty?

    if apply
      archive = File.join(repo, LEDGER_ARCHIVE)
      FileUtils.mkdir_p(File.dirname(archive))
      File.write(archive, LEDGER_ARCHIVE_HEADER) unless File.file?(archive)
      File.write(archive, split[:rolled].join, mode: "a")
      File.write(path, split[:kept])

      # STAGE BOTH SIDES. The doc retirements stage themselves (git mv does), but
      # these two are plain file writes, and leaving them unstaged is data loss
      # rather than untidiness: bin/release archive commits delete-later.md by
      # path, so a committed-but-trimmed ledger beside an UNTRACKED archive file
      # drops the rolled rows on the floor. Caught by the idempotency test, which
      # asserted a clean tree after a sweep-and-commit.
      git(repo, "add", "--", LEDGER, LEDGER_ARCHIVE)
    end

    { rolled: split[:rolled].size, cutoff: cutoff }
  end

  # ---- plumbing -----------------------------------------------------------

  class CommandFailed < StandardError; end

  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    raise CommandFailed, "git #{args.join(' ')}: #{out}" unless status.success?

    out
  end

  SUMMARY_TAG = "archive-docs-summary:"

  def summary_line(payload)
    "#{SUMMARY_TAG} #{JSON.generate(payload)}"
  end

  def parse_summary(output)
    line = output.to_s.lines.reverse.find { |l| l.include?(SUMMARY_TAG) }
    return nil unless line

    JSON.parse(line.split(SUMMARY_TAG, 2).last.strip, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end
