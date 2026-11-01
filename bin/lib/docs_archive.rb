# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

# DocsArchive — retire frozen snapshots out of the LIVE doc tree, on the archive
# beat.
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
# A DESTINATION THAT ALREADY EXISTS IS NEVER PLANNED. `plan` leaves a doc whose
# archive path is taken (a commit that added an archive copy while leaving the
# live copy tracked does it) in place and reports it, so `git mv` is never asked
# for a move it would refuse with "fatal: destination exists".
#
# ANY OTHER FAILED MOVE STILL ABORTS THE WHOLE ROLL — IT IS NOT SKIPPED.
# apply_moves! neither rescues nor continues: DocsArchive::CommandFailed propagates
# out of bin/archive-docs and the run dies on the spot, with the moves already made
# in that loop left STAGED. Nothing is lost, and the fix is to clear the colliding
# destination, not to re-run and hope.
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

  DATE_IN_NAME = /\d{4}-\d{2}-\d{2}/
  RETRO_NAME   = /\Aretro-rel-/

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
      to = archive_path_for(path)
      # A destination that already exists is LEFT IN PLACE, never moved onto:
      # `git mv` would refuse it and abort the whole roll. The duplicate is
      # reported every roll until someone keeps one copy.
      pinned = File.exist?(File.join(repo, to)) ? ["#{to} (already in the archive)"] : referrers(repo, path, lookup)
      if pinned.empty?
        moves << { from: path, to: to }
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

  # ---- reporting a FAILED sweep ---------------------------------------------

  # THE FAILURE CONTRACT, sibling to the summary contract above.
  #
  # bin/archive-docs exits non-zero for unrelated reasons: an argument CliArgGuard does
  # not account for, or any crash inside the sweep itself (a `git mv` onto an existing
  # destination did it on 2026-09-01). So the report names WHAT FAILED, the command, its
  # exit status and its stderr, and claims nothing it did not measure.
  #
  # PURE — strings in, string out, no git and no I/O — so it is unit-testable directly.
  # See test/lib/docs_archive_failure_report_test.rb for the unit tier and
  # test/lib/release_archive_docs_diagnosis_test.rb for the caller driving it across a
  # real process boundary.

  # How much of a failing sweep's stderr to quote. A Ruby backtrace runs long and its
  # FIRST line carries the message that names the cause, so quoting the head is what
  # makes the report legible. The tail is NAMED as elided, never dropped in silence.
  STDERR_QUOTE_LINES = 12

  NO_STDERR = "(none — the sweep failed without writing anything to stderr)"

  DEFAULT_CONSEQUENCE = "Nothing was committed."

  # Label column: every label aligns to it so continuation lines hang under the text
  # rather than under the label.
  LABEL_WIDTH = 16

  def failure_report(command:, exit_label:, stderr:, consequence: DEFAULT_CONSEQUENCE)
    [
      "docs archive FAILED — the sweep itself failed.",
      "",
      labelled("command", command),
      labelled("exit status", exit_label),
      "",
      "  the sweep said (stderr):",
      quoted_stderr(stderr),
      "",
      "  #{consequence} Fix the cause above, then re-run `bin/release archive`."
    ].join("\n")
  end

  def labelled(label, text)
    body = text.to_s.split("\n")
    pad = " " * LABEL_WIDTH
    [format("  %-13s %s", "#{label}:", body.first)]
      .concat(body.drop(1).map { |line| "#{pad}#{line}" })
      .join("\n")
  end

  def quoted_stderr(stderr, limit: STDERR_QUOTE_LINES)
    lines = stderr.to_s.lines.map(&:chomp).reject { |line| line.strip.empty? }
    return "    #{NO_STDERR}" if lines.empty?

    quoted = lines.first(limit).map { |line| "    #{line}" }
    if lines.size > limit
      quoted << "    … (#{lines.size - limit} more line(s) — re-run the command above to see them)"
    end
    quoted.join("\n")
  end
end
