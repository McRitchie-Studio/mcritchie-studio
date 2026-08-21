# frozen_string_literal: true

require "open3"
require_relative "docs_archive"

# LedgerGuard — the delete-later ledger's MOVE-NEVER-DELETE invariant, enforced.
#
# `docs/agents/maintenance/delete-later.md` and its archive
# `docs/agents/archive/maintenance/delete-later-archive.md` are one record in two files.
# A row may travel between them on the archive beat; it may never leave both. On
# 2026-08-21 three rows did, and nobody noticed until a reviewer ran `comm` by hand.
#
# WHY THIS IS NOT A FIX TO THE WRITER. The rows were destroyed by an in-place overwrite
# in bin/agent-worktree, whose `ledger_path` is anchored to HUB_DIR — so a teardown
# driven from ANY worktree mutates the HUB's ledger using whatever copy of the script
# THAT DESK carries. When this was measured, 12 of 18 hub desks were still carrying the
# pre-269e2db4 writer. Teaching the writer the rule a second time protects nothing,
# because the offending writer is, by definition, the one that has not been updated.
#
# So the invariant is checked where the change becomes DURABLE — against git history,
# from whatever checkout is doing the committing or the CI run. That check is stale-proof
# in the only way that matters: it does not run in the writer's process, it runs on the
# writer's OUTPUT.
#
# WHAT COUNTS AS HISTORY. A row is RESOLVED when its Status cell carries a date
# ("removed 2026-08-20"), and resolved rows are immutable history. An UNDATED status
# ("pending approval", "reference only") is an open item that the next teardown closes in
# place — a state transition inside one episode, not a deletion. That is exactly
# DocsArchive's own rule (row_date), reused rather than restated: the two ledgers drifted
# apart in the first place because only one of them had the definition.
#
# WHAT AN EPISODE IS. Identity is (path, status cell) — the desk and the teardown that
# resolved it — counted as a MULTISET, so two teardowns of one path on one day are two
# episodes and destroying one of them is caught. Identity deliberately excludes the
# "why" and "condition" prose: rewording a cell in a docs sweep has not destroyed a
# teardown, and a guard that went red over prose would be a false-positive machine
# aimed at the people maintaining the docs. Changing the DATE is never tolerated —
# that is a different teardown standing in the first one's row, which is the bug.
module LedgerGuard
  LEDGER  = DocsArchive::LEDGER
  ARCHIVE = DocsArchive::LEDGER_ARCHIVE

  # A resolved row that the head tree cannot account for. `line` is the full row text as
  # it stands at the base, so recovery is a paste rather than an archaeology session.
  Episode = Struct.new(:path, :status, :line, :missing, keyword_init: true)

  # Raised when the baseline cannot be read. NEVER swallowed into a pass: the whole
  # instrument is a comparison against history outside the working tree, so "I could not
  # look" has to be red.
  class UnreadableBase < StandardError; end

  module_function

  # ---- reading rows -------------------------------------------------------

  def resolved_row?(line)
    DocsArchive.data_row?(line) && !DocsArchive.row_date(line).nil?
  end

  # The cells of a markdown table row, outer pipes dropped.
  def cells(line)
    line.strip.sub(/\A\|/, "").sub(/\|\z/, "").split("|")
  end

  # The Path cell, unwrapped from its backticks. Rows are written `| \`/path\` | … |`.
  def row_path(line)
    cells(line).first.to_s.strip.gsub(/\A`|`\z/, "")
  end

  def row_status(line)
    cells(line).last.to_s.strip
  end

  # Every resolved row in one file's content.
  def episodes(content)
    content.to_s.lines.select { |line| resolved_row?(line) }.map do |line|
      Episode.new(path: row_path(line), status: row_status(line), line: line.strip, missing: 1)
    end
  end

  # ---- the invariant ------------------------------------------------------

  # Resolved episodes across a set of file contents, counted.
  def census(contents)
    Array(contents).flat_map { |content| episodes(content) }
                   .each_with_object(Hash.new(0)) { |episode, tally| tally[key(episode)] += 1 }
  end

  def key(episode) = [episode.path, episode.status]

  # Episodes present in `base` that `head` cannot account for.
  #
  # `base` and `head` are each a LIST of file contents — the ledger and its archive — and
  # the comparison is over their UNION. Reading one file alone would call every archive
  # roll a catastrophe, since a roll shrinks the ledger by exactly the rows it moves.
  def lost(base:, head:)
    head_tally = census(head)
    sample = Array(base).flat_map { |content| episodes(content) }
                        .each_with_object({}) { |episode, seen| seen[key(episode)] ||= episode.line }

    census(base).filter_map do |(path, status), count|
      short = count - head_tally[[path, status]]
      next if short <= 0

      Episode.new(path: path, status: status, line: sample[[path, status]], missing: short)
    end
  end

  # ---- against git --------------------------------------------------------

  # The newest commit `ref` and HEAD share, or nil when the ref does not resolve.
  #
  # THE MERGE BASE, NOT THE REF ITSELF, is what makes this safe to point at any branch. A
  # sibling branch that is merely AHEAD carries rows this tree has never seen, and
  # demanding them here would paint a healthy checkout red — the false refusal that gets
  # a gate switched off. A merge base is always an ancestor of HEAD, so every row in it is
  # genuinely this tree's own history.
  def merge_base(repo, ref)
    return nil unless git(repo, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")

    git(repo, "merge-base", "HEAD", ref)&.strip
  end

  # A file's content at a commit, or "" when the path does not exist there — a ledger that
  # had not been created yet is empty history, not an error.
  #
  # "DOES NOT EXIST" AND "COULD NOT BE READ" ARE DIFFERENT ANSWERS, and this used to give
  # both of them as "". `git` returns nil on failure, so the old `.to_s` turned EVERY failed
  # `git show` into empty content — and empty base content means "history had no rows",
  # which is a PASS. A resolvable base whose blob could not be read therefore certified the
  # tree GREEN. The CLI's unreadable-base defence covers the REF; nothing covered the BLOB.
  #
  # The split is decided by asking the TREE, which is a different object from the blob:
  # `git ls-tree` succeeds and prints nothing when the tree is readable and simply has no
  # such path (genuinely absent → ""), and fails when the tree itself cannot be read. If the
  # tree lists the path but `show` could not produce it, the blob is unreadable — and that
  # is UnreadableBase, never a pass, for the same reason an unresolvable ref is.
  def show(repo, ref, rel_path)
    content = git(repo, "show", "#{ref}:#{rel_path}")
    return content if content
    return "" if absent_at?(repo, ref, rel_path)

    raise UnreadableBase,
          "`#{ref}:#{rel_path}` is recorded at that commit but its content could not be read " \
          "in #{repo}. This is RED on purpose — an unreadable baseline certifies nothing. " \
          "Try `git fetch origin` (or `git fsck` if the object store is damaged)."
  end

  # True when `ref`'s tree is READABLE and holds no such path — empty history, not a failure.
  # False both when the path IS there (so a failed `show` means an unreadable blob) and when
  # the tree could not be read at all.
  def absent_at?(repo, ref, rel_path)
    listing = git(repo, "ls-tree", "--name-only", ref, "--", rel_path)
    !listing.nil? && listing.strip.empty?
  end

  def read(repo, rel_path)
    path = File.join(repo, rel_path)
    File.file?(path) ? File.read(path) : ""
  end

  # The invariant, measured against one base ref. `head:` names a commit to inspect
  # instead of the working tree — the working tree is the default because that is what a
  # pre-commit check and a CI checkout both need to judge.
  def lost_against_ref(repo, ref, head: nil)
    base_sha = merge_base(repo, ref)
    raise UnreadableBase, "`#{ref}` does not resolve in #{repo} — run `git fetch origin`" unless base_sha

    base = [show(repo, base_sha, LEDGER), show(repo, base_sha, ARCHIVE)]
    tip = if head
            [show(repo, head, LEDGER), show(repo, head, ARCHIVE)]
          else
            [read(repo, LEDGER), read(repo, ARCHIVE)]
          end

    lost(base: base, head: tip)
  end

  # ---- reporting ----------------------------------------------------------

  # The message every caller prints. It names the destroyed episodes and the one command
  # that gets them back, because a guard that only says "no" gets worked around.
  def report(losses, base_label:)
    lines = losses.map { |episode| "  #{episode.line}#{episode.missing > 1 ? " (x#{episode.missing})" : ''}" }
    <<~MSG
      delete-later ledger: #{losses.sum(&:missing)} resolved row(s) DESTROYED against #{base_label}.

      Rows are MOVED to #{ARCHIVE}, never deleted. Each row below is recorded at the base
      and is now in NEITHER file:

      #{lines.join("\n")}

      Recover them: git show #{base_label}:#{LEDGER}
      The usual cause is a teardown driven from a desk carrying a stale bin/agent-worktree,
      which overwrites a dated row in place. Do not resolve this by editing the guard.
    MSG
  end

  # ---- plumbing -----------------------------------------------------------

  # nil on failure rather than raising: "this ref does not resolve" and "this path is not
  # in that commit" are both answers this module acts on, not exceptions.
  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    status.success? ? out : nil
  end
end
