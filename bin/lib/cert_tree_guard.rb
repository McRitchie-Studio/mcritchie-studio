# frozen_string_literal: true

# CertTreeGuard — refuse a cert taken over a tree that is not fully committed.
#
# Sibling of cert_root_guard.rb, and the same family: both refuse BEFORE any lane
# runs or any gate/checkpoint write, because both failure modes are fail-GREEN —
# they record evidence for code that is not the code under review.
#
# THE BUG. The cert fingerprint (full_suite_gate.rb#fingerprint) is a git TREE
# hash of `git add -A` + `write-tree` — the whole working state, tracked edits AND
# untracked-not-ignored files. That is deliberate: it makes the fingerprint stable
# across the commit boundary, so a cert taken just before `git commit` still
# validates at the merge gate. The cost of that stability is that a cert taken over
# an UNCOMMITTED tree is happily fingerprint-bound to code that never reaches the
# PR. The task is then certified GREEN over a tree nobody else can reproduce.
# Live on 2026-07-14: the dor-check-misses-rolio-ci worktree held 146 lines of
# finished, tested, uncommitted work that PR #537 never received; its cert had been
# taken over that tree. "Certify after the final commit" was a remembered house rule
# enforced by nothing. This enforces it.
#
# ── THE STALE-MTIME TRAP (read before you "optimize" the git read) ──────────────
#
# A guard that refuses a dirty tree MUST NOT refuse a CLEAN one. The classic way to
# get that wrong is the stat cache: git's index memoizes each file's mtime/ctime/
# size, and a file rewritten with IDENTICAL content (a `touch`, a rebase, a
# checkout, an editor's save-in-place) has a fresh mtime over unchanged bytes. Such
# an index is "stale", and the cheap dirty checks read it as MODIFIED:
#
#   git diff-index --quiet HEAD   → exit 1 (DIRTY) on a stale index — false positive
#   git diff --quiet              → same
#   git status --porcelain        → CLEAN (it re-hashes stat-mismatched entries)
#
# This is not theoretical: it took down the SHIP path (see bin/release.rb, where
# turf's `bin/deploy` does exactly `git diff-index --quiet HEAD` and refused a
# legitimate ship over stat-stale files; fixed there with the same refresh).
#
# So we do BOTH, and the order is load-bearing:
#
#   1. `git update-index -q --refresh` — re-stat the working tree and rewrite the
#      index's stat cache for entries whose CONTENT still matches. This is what
#      makes a stale index clean again, and it is the invariant we OWN.
#   2. `git status --porcelain` — the read. Chosen over diff-index for two reasons:
#      it reports exactly the set the fingerprint captures (staged + unstaged +
#      untracked-not-ignored, honouring .gitignore), and it NAMES the files, which
#      diff-index --quiet cannot.
#
# Note the honest version of the history: #361's guard used status --porcelain with
# no refresh, and status alone does not false-positive — so it would not have
# misfired. But that correctness was an ACCIDENT of one porcelain's internals, not
# an invariant anyone had written down. Swap the read for the "obvious" cheaper
# `git diff-index --quiet HEAD` and the false positive lands instantly, on the CERT
# path, where a false refusal blocks every handoff. Step 1 makes the guard correct
# for BOTH reads, so the next person to touch this cannot reintroduce it. It also
# leaves the index refreshed on disk for whatever runs next (git status can only
# write the refreshed index back when it may take the optional lock —
# GIT_OPTIONAL_LOCKS=0, a read-only .git, or a concurrent index.lock all suppress
# it; update-index takes a real lock and writes). test/lib/cert_tree_guard_test.rb
# asserts both directions, including that the index is left refreshed.
module CertTreeGuard
  module_function

  # How many offending paths to name before eliding the rest.
  MAX_LISTED = 10

  # nil when `root` is fully committed (the cert may proceed), else the refusal
  # message. An unreadable tree (not a git repo) also returns nil — "unverifiable"
  # is not "dirty", and the runner's nil-fingerprint refusal already covers it.
  def refusal(command:, root:)
    changes = working_tree_changes(root)
    return nil if changes.nil? || changes.empty?

    listed = changes.first(MAX_LISTED)
    elided = changes.size - listed.size

    message = +"working tree at #{root} is DIRTY " \
               "(#{changes.size} uncommitted change#{'s' unless changes.size == 1}) — refusing to certify.\n"
    listed.each { |line| message << "  #{line}\n" }
    message << "  … and #{elided} more\n" if elided.positive?
    message << "The cert fingerprint is a git TREE hash of the WORKING tree, so certifying now would " \
               "stamp GREEN evidence over code that is not on the PR — the thing certified would not be " \
               "the thing that ships.\n" \
               "Commit every edit first, THEN certify (the cert is the LAST build step):\n" \
               "  git add -A && git commit -m \"…\" && #{command} <task>"
    message
  end

  # The uncommitted-change list at `root` — `git status --porcelain` lines (staged,
  # unstaged, and untracked-not-ignored), exactly the set the fingerprint captures.
  # [] for a clean tree; nil when git cannot read the tree (no repo), which is
  # "unverifiable", NOT "clean" and NOT "dirty".
  #
  # The index is refreshed FIRST — see the trap above. Without it, this function is
  # only accidentally correct.
  def working_tree_changes(root)
    refresh_index(root)
    out = IO.popen(["git", "-C", root.to_s, "status", "--porcelain"], err: File::NULL, &:read)
    return nil unless $?.success?

    out.to_s.lines.map(&:strip).reject(&:empty?)
  rescue StandardError
    nil
  end

  # Re-stat the working tree and rewrite the index's stat cache for entries whose
  # content is unchanged, so a stat-stale index stops reading as modified.
  #
  # The exit status is DELIBERATELY ignored: `update-index --refresh` exits non-zero
  # when a file genuinely differs from the index — which is the very case we are
  # here to detect and report, not an error. Treating that as a failure would make
  # the guard blind to real dirt. `-q` suppresses the per-file "needs update" noise.
  # Best-effort: a missing/locked index simply leaves the read to git status.
  def refresh_index(root)
    system("git", "-C", root.to_s, "update-index", "-q", "--refresh",
           out: File::NULL, err: File::NULL)
  rescue StandardError
    nil
  end
end
