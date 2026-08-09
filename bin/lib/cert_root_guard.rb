# frozen_string_literal: true

require "json"
require_relative "projects_root"

# CertRootGuard — is this resolved CODE root the task's tree, and if not, what now?
#
# The G1 gates root at the cwd's git toplevel (RepoRoot.code_root), so a run from
# the WRONG checkout — e.g. the hub primary on main — roots at whatever tree it
# stands in. Because a cert's fingerprint is a git TREE hash, a foreign root is
# never harmlessly wrong; it is wrong in a direction, and the direction depends on
# whether the caller WRITES evidence or READS it. So the guard answers one question
# — "is `root` the task's tree?" — and the caller picks the remedy.
#
# A root is accepted as the task's tree when EITHER:
#   - its checked-out branch is the task's branch (board metadata.devops.branch,
#     falling back to the feat/<slug> convention — the same resolution
#     bin/task stale uses), OR
#   - it is the task's worktree directory (…/.worktrees/<worktree_slug>), which
#     covers detached-HEAD states (mid-rebase) inside the right worktree.
#
# THE TWO REMEDIES
#
#   * A cert WRITER — bin/fast-check, bin/full-suite-check — REFUSES (#refusal).
#     It STAMPS "[…@<fp>]" evidence about the tree it stands in, so from the wrong
#     checkout it green-certified code the task never touched: a fail-GREEN, hit
#     live 2026-07-12, caught only downstream by bin/dor-check's staleness. And it
#     must not silently chdir into the task worktree instead — that could green-cert
#     a STALE worktree while the operator's real edits sat untested in the checkout
#     they ran from, trading one fail-GREEN for another. Fail closed, say where to
#     run.
#
#   * The READER — bin/dor-check — RE-ROOTS (#assess → :resolved_root). It writes
#     no evidence, so re-rooting cannot forge a cert; it can only make the gate
#     grade the RIGHT tree instead of a foreign one. Refusing to read is the
#     costlier failure: because the fingerprint is content-addressed, a cert taken
#     in the task's worktree can NEVER match a primary checkout's tree, so
#     dor-check from the primary reported "STALE (certified for older code)" for
#     certs that were perfectly fresh — 6 of 6 tasks on 2026-07-14, including ones
#     certified green 90 seconds earlier. An agent that hits an unexplainable STALE
#     stops working, so the false STALE stranded finished tasks in `building`.
#     The re-root is LOUD by contract: the hazard of resolving is doing it
#     SILENTLY, which leaves the tool and the operator believing different things
#     about which code was judged.
#
#     The reader roots its DIFF here too, not just its fingerprint — and that half
#     fails in the opposite, worse direction. A foreign fingerprint can only read
#     STALE (a false REFUSAL, loud). A foreign DIFF reads as a real diff: run the
#     review gate-zero from a primary checkout carrying one unrelated dirty .md and
#     the gate observes a doc-only change, grants the `kind: chore` exemption, and
#     waves through a multi-file code PR. Same wrong tree, but a false PASS in the
#     gate whose whole job is refusing under-tested work (observed 2026-08-08,
#     task dor-check-review-rooting).
#
# The guard applies only to the IMPLICIT root (cwd-resolved). An EXPLICIT override
# (FULL_SUITE_ROOT / FAST_CHECK_ROOT / DOR_CHECK_DIFF_ROOT) bypasses it at the call
# site: the caller declared that root deliberately (the CI/test seam).
#
# Board reads are best-effort: an unreachable board falls back to the naming
# conventions, so the hub-primary-on-main case still refuses offline. A caller that
# already holds the task passes `devops:` and skips the board read entirely.
module CertRootGuard
  module_function

  # nil when `root` is `slug`'s tree (the cert may proceed); else the refusal
  # message. A blank slug (standalone --print / hook runs) never refuses —
  # there is no task to root at. The cert WRITERS' entry point.
  def refusal(task_bin:, slug:, root:, devops: nil, projects_dir: nil)
    assess(task_bin: task_bin, slug: slug, root: root, devops: devops, projects_dir: projects_dir)
      &.fetch(:message)
  end

  # The full assessment of `root` against the task. nil when `root` IS the task's
  # tree — the caller proceeds, unchanged. Otherwise a Hash the caller chooses a
  # remedy from (see THE TWO REMEDIES above):
  #
  #   :message         — the refusal text (what #refusal returns).
  #   :resolved_root   — the task's tree ON DISK (…/<app>/.worktrees/<worktree_slug>),
  #                      or nil when no such worktree exists here. The RESOLVE half:
  #                      a READER re-roots at this instead of refusing.
  #   :candidate_roots — EVERY such tree on disk, because a MULTI-REPO task has one
  #                      per repo and :resolved_root is then a PICK, not a fact. A
  #                      caller that cannot afford a wrong guess (bin/dor-check's
  #                      diff) checks this before trusting the pick.
  #   :expected_branch — the branch that IS the task's tree (board, else feat/<slug>).
  #   :actual_branch   — what `root` has checked out ("HEAD" when detached, nil when
  #                      `root` isn't a git tree at all).
  #   :worktree_slug   — the task's worktree slug.
  #
  # `devops` short-circuits the board read for a caller that already holds the task;
  # `projects_dir` overrides where the worktree glob looks (the test seam);
  # `prefer_repo` breaks a multi-repo tie (see #worktree_hint).
  def assess(task_bin:, slug:, root:, devops: nil, projects_dir: nil, prefer_repo: nil)
    return nil if slug.to_s.strip.empty?

    devops ||= task_devops(task_bin, slug)
    expected_branch = first_present(devops["branch"], "feat/#{slug}")
    worktree_slug = first_present(devops["worktree_slug"], slug)
    actual_branch = current_branch(root)
    return nil if actual_branch == expected_branch
    return nil if worktree_dir?(root, worktree_slug)

    {
      message: refusal_message(slug, root, actual_branch, expected_branch, worktree_slug, projects_dir),
      resolved_root: worktree_hint(worktree_slug, projects_dir, prefer_repo: prefer_repo),
      candidate_roots: worktree_candidates(worktree_slug, projects_dir),
      expected_branch: expected_branch,
      actual_branch: actual_branch,
      worktree_slug: worktree_slug
    }
  end

  # The cert writers' refusal text: where you ARE, where the task's tree IS, and the
  # concrete `cd` that fixes it when the worktree is on disk.
  def refusal_message(slug, root, actual_branch, expected_branch, worktree_slug, projects_dir = nil)
    message = "this run roots at #{root} (branch #{actual_branch || 'unknown'}), " \
              "which is not #{slug}'s tree — refusing to certify it.\n" \
              "Expected branch #{expected_branch} or the task worktree .worktrees/#{worktree_slug}."
    hint = worktree_hint(worktree_slug, projects_dir)
    message += "\nRun the cert from the task worktree: cd #{hint}" if hint
    message
  end

  # The branch checked out at `dir`, or nil. Errors and empty output read as
  # nil; a detached HEAD reads as "HEAD", which never matches a task branch.
  def current_branch(dir)
    out = IO.popen(["git", "-C", dir.to_s, "rev-parse", "--abbrev-ref", "HEAD"],
                   err: File::NULL, &:read).to_s.strip
    out.empty? ? nil : out
  rescue StandardError
    nil
  end

  # The task's devops metadata via `<task_bin> show <slug> --json`; {} on any
  # failure so the caller falls back to the naming conventions.
  def task_devops(task_bin, slug)
    out = IO.popen([task_bin, "show", slug, "--json"], err: File::NULL, &:read)
    return {} unless $?.success?

    JSON.parse(out).dig("metadata", "devops") || {}
  rescue StandardError
    {}
  end

  # True when `dir` IS a `.worktrees/<worktree_slug>` checkout.
  def worktree_dir?(dir, worktree_slug)
    File.basename(dir.to_s) == worktree_slug &&
      File.basename(File.dirname(dir.to_s)) == ".worktrees"
  end

  # EVERY …/<app>/.worktrees/<worktree_slug> on disk under the projects root, sorted.
  # The glob spans every app because a SATELLITE task (turf-monster, rolio) runs the
  # hub's gate scripts — its worktree lives under the satellite, not the hub.
  #
  # It returns the whole SET, not the first hit, because a MULTI-REPO task
  # legitimately has one worktree per repo under the SAME slug — live on this machine
  # today, e.g. `repair-moms-app-ci` exists under both moms-app and studio-engine. The
  # glob is alphabetical, so a first-hit pick silently answers "which repo is this
  # task's tree?" with "whichever sorts first", which is how a gate ends up grading
  # moms-app's tree for a studio-engine PR. `projects_dir` overrides the search root
  # (the test seam). Best-effort: [] on any failure.
  def worktree_candidates(worktree_slug, projects_dir = nil)
    base = projects_dir.to_s.strip.empty? ? ProjectsRoot.default_projects_dir : projects_dir.to_s
    Dir.glob(File.join(base, "*", ".worktrees", worktree_slug)).select { |path| File.directory?(path) }.sort
  rescue StandardError
    []
  end

  # The app a worktree belongs to: …/<app>/.worktrees/<slug> → "<app>".
  def app_of(worktree_path)
    File.basename(File.expand_path("../..", worktree_path.to_s))
  end

  # The task's tree ON DISK. Doubles as the refusal's `cd` hint and the reader's
  # :resolved_root. `prefer_repo` — the app the work under gate belongs to, e.g. the
  # repo named by the task's PR URL — breaks a multi-repo tie; with no preference (or
  # no match) this falls back to the first candidate, and the caller decides from
  # :candidate_roots whether that guess is safe to act on. nil when nothing matches.
  def worktree_hint(worktree_slug, projects_dir = nil, prefer_repo: nil)
    candidates = worktree_candidates(worktree_slug, projects_dir)
    wanted = prefer_repo.to_s.strip
    preferred = wanted.empty? ? nil : candidates.find { |path| app_of(path) == wanted }
    preferred || candidates.first
  end

  # The first argument whose string form isn't blank (nil when all are).
  def first_present(*values)
    values.find { |v| !v.to_s.strip.empty? }
  end
end
