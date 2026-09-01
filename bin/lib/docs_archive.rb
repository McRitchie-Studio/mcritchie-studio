# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "set"

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
# ONE BAD MOVE ABORTS THE WHOLE ROLL — IT IS NOT SKIPPED. `git mv` fails with
# "fatal: destination exists" when the archive already holds that filename (a
# commit that added an archive copy while leaving the live copy tracked does it),
# and apply_moves! neither rescues nor continues: DocsArchive::CommandFailed
# propagates out of bin/archive-docs and the run dies on the spot. A reader of the
# paragraph above would reasonably expect the one bad file to be passed over and the
# rest to retire. It does not work that way, and the difference matters, because the
# run does not die cleanly:
#
#   * the moves ALREADY made in that loop stay STAGED, and
#   * the LEDGER ROLLOVER RAN FIRST (bin/archive-docs rolls before it sweeps, so a
#     retired row stops pinning the doc it named), so both ledger files are already
#     rewritten and staged too.
#
# So the tree is left mid-rollover: rows gone from delete-later.md, the same rows
# added to its archive. That is CONSERVED and correct — but it looks exactly like
# damage, which is how `bin/release archive` came to announce a ledger loss for a
# crash that lost nothing (2026-09-01, mid production deploy; see failure_report
# below). Nothing is lost here — but nothing is finished either, and the fix is to
# clear the colliding destination, not to re-run and hope.
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
  # `landed` is the set of rows already rotated on `accepted` (nil when that rung
  # could not be read). Such a row is left KEPT, untouched: rotating it here would
  # redo work that has already landed, and the working tree will inherit the real
  # rotation when it catches up to `accepted`.
  def split_ledger(content, cutoff, landed: nil)
    kept = []
    rolled = []
    already = []
    content.lines.each do |line|
      unless data_row?(line)
        kept << line
        next
      end

      date = row_date(line)
      if date && cutoff && date < cutoff
        if landed&.include?(line.strip)
          already << line
          kept << line
        else
          rolled << line
        end
      else
        kept << line
      end
    end
    { kept: kept.join, rolled: rolled, already: already }
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

  # THE LADDER RUNG THE WORK ACTUALLY LANDS ON.
  #
  # bin/archive-docs runs in the PRIMARY checkout, which is pinned to `main` —
  # and `main` LAGS `accepted` between releases. Reading only the working tree
  # therefore recomputed rotations that had ALREADY landed on `accepted`: three
  # occurrences (PR #856, #1011, #1015), each costing a human or agent a full
  # re-verification pass to prove the recomputed rotation was a duplicate, and
  # each leaving the primary dirty with it. That dirt has a second bite:
  # `bin/release archive` refuses to commit when other changes are present, so it
  # also blocks UNRELATED ledger commits.
  #
  # Prefer the remote rung; fall back to a local `accepted` when there is no
  # remote. A ref that cannot be resolved yields nil, and the caller then behaves
  # exactly as it always did — the check can only ever SUPPRESS a duplicate
  # rotation, never invent one.
  ACCEPTED_RUNGS = ["origin/accepted", "accepted"].freeze

  def ledger_archive_at_accepted(repo)
    ACCEPTED_RUNGS.each do |ref|
      out, status = Open3.capture2e("git", "-C", repo, "show", "#{ref}:#{LEDGER_ARCHIVE}")
      return [ref, out] if status.success?
    end
    [nil, nil]
  end

  # Data rows already present in the ledger archive on `accepted`, compared
  # VERBATIM. Verbatim on purpose: a full-row match is precisely the `grep -Fqx`
  # proof a reviewer ran by hand to establish the duplication on PR #1015, so the
  # tool now performs that proof itself instead of leaving it to the reader.
  def landed_ledger_rows(repo)
    ref, content = ledger_archive_at_accepted(repo)
    return [nil, nil] unless content

    [ref, content.lines.select { |l| data_row?(l) }.map(&:strip).to_set]
  end

  def roll_ledger!(repo, cutoff: nil, apply:)
    path = File.join(repo, LEDGER)
    return { rolled: 0, cutoff: cutoff, already_landed: 0, rung: nil } unless File.file?(path)

    content = File.read(path)
    cutoff ||= newest_ledger_date(content)
    rung, landed = landed_ledger_rows(repo)
    split = split_ledger(content, cutoff, landed: landed)
    result = { rolled: split[:rolled].size, cutoff: cutoff,
               already_landed: split[:already].size, rung: rung }
    return result if split[:rolled].empty?

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

    result
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
  # bin/archive-docs exits non-zero for at least four UNRELATED reasons: a genuine
  # ledger loss, an UNREADABLE baseline, an argument CliArgGuard does not account
  # for, and any crash inside the sweep itself — a `git mv` onto an existing
  # destination did it on 2026-09-01. Its caller (`bin/release archive`) caught all
  # four and reported exactly ONE of them: "the delete-later ledger has lost
  # resolved row(s)".
  #
  # THAT DIAGNOSIS WAS NEVER CHECKED. It fired for the `git mv` crash in the middle
  # of a production deploy, and the operator — reading DATA LOSS IN AN AUDIT TRAIL —
  # stopped and counted the rows by hand: delete-later.md 86 → 45 (−41), its archive
  # 524 → 565 (+41). Forty-one out, forty-one in, perfectly conserved. The ledger had
  # lost nothing. A wrong diagnosis in a deploy path is worse than no diagnosis: it
  # sends the reader hunting in the wrong place, at the worst possible moment, and an
  # operator who BELIEVES it may start "recovering" rows that were never lost.
  #
  # So this report separates the two questions the old message conflated:
  #
  #   * WHAT FAILED — the command, its exit status, its stderr. Reported ALWAYS,
  #     whatever the cause, because that is the answer to "what actually happened"
  #     and it is the one thing the old message never said.
  #   * WHETHER THE LEDGER LOST ROWS — a MEASUREMENT the caller supplies
  #     (LedgerGuard.lost_against_ref, against the same repo the sweep was pointed
  #     at), never an inference from the exit code. `ledger: nil` means the caller
  #     did not measure, and then the report claims NOTHING about the ledger rather
  #     than guessing.
  #
  # The three verdicts are three different sentences on purpose, and `:unreadable`
  # is neither of the other two: a comparison that could not run certifies nothing,
  # so it must not read as "intact" any more than as "lost".
  #
  # PURE — strings in, string out, no git and no I/O — so the discrimination is
  # unit-testable directly. See test/lib/docs_archive_failure_report_test.rb for the
  # unit tier and test/lib/release_archive_docs_diagnosis_test.rb for the caller
  # driving it across a real process boundary.
  #
  # DEPENDENCY DIRECTION: this module must NOT reach for LedgerGuard. LedgerGuard
  # requires THIS file (it reuses row_date/data_row? so the two ledgers cannot drift
  # apart again), so the arrow runs one way and the caller hands the verdict down.

  # How much of a failing sweep's stderr to quote. A Ruby backtrace runs long and its
  # FIRST line carries the message that names the cause, so quoting the head is what
  # makes the report legible. The tail is NAMED as elided, never dropped in silence.
  STDERR_QUOTE_LINES = 12

  NO_STDERR = "(none — the sweep failed without writing anything to stderr)"

  DEFAULT_CONSEQUENCE = "Nothing was committed."

  # Label column: "  ledger check: " is 16 characters, and every label aligns to it so
  # continuation lines hang under the text rather than under the label.
  LABEL_WIDTH = 16

  def failure_report(command:, exit_label:, stderr:, ledger: nil, consequence: DEFAULT_CONSEQUENCE)
    verdict = ledger && ledger[:verdict]
    [
      "docs archive FAILED — #{failure_lead(verdict)}",
      "",
      labelled("command", command),
      labelled("exit status", exit_label),
      labelled("ledger check", ledger_check_text(ledger)),
      "",
      "  the sweep said (stderr):",
      quoted_stderr(stderr),
      ledger_evidence(ledger),
      "  #{consequence} #{next_step(verdict)}"
    ].join("\n")
  end

  # The lead sentence. ONLY `:lost` — a measured loss — is allowed to raise the alarm.
  def failure_lead(verdict)
    return "and the delete-later ledger HAS lost resolved row(s)." if verdict == :lost

    "the sweep itself failed."
  end

  def ledger_check_text(ledger)
    case ledger && ledger[:verdict]
    when :intact
      "INTACT — every resolved row recorded at HEAD is still accounted for across\n" \
        "#{File.basename(LEDGER)} and its archive. This is NOT ledger loss, and\n" \
        "there is nothing to recover."
    when :lost
      "LOST — #{ledger[:missing]} resolved row(s) recorded at HEAD are now in NEITHER\n" \
        "#{File.basename(LEDGER)} nor its archive. Committing would make that\n" \
        "loss permanent on `release`."
    when :unreadable
      "UNKNOWN — the conservation check could not run, so whether any row was lost\n" \
        "is UNDETERMINED. Do not assume either way.\n" \
        "#{ledger[:detail]}"
    else
      "not measured — this run stopped before the ledger was inspected, so NO claim\n" \
        "is made about it either way."
    end
  end

  # The rows themselves, for a MEASURED loss only. Nothing else earns this block:
  # printing recovery instructions under a failure that lost nothing is precisely the
  # defect. Every other verdict contributes a blank separator line and no claim.
  def ledger_evidence(ledger)
    return "" unless ledger && ledger[:verdict] == :lost && ledger[:detail]

    "\n#{ledger[:detail].to_s.lines.map { |l| l.strip.empty? ? '' : "  #{l.chomp}" }.join("\n")}\n"
  end

  def next_step(verdict)
    return "Recover the row(s) above, then re-run `bin/release archive`." if verdict == :lost

    "Fix the cause above, then re-run `bin/release archive`."
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
