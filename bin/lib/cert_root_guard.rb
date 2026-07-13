# frozen_string_literal: true

require "json"
require_relative "projects_root"

# CertRootGuard — refuse a cert whose resolved CODE root is not the task's tree.
#
# The G1 cert runners (bin/fast-check, bin/full-suite-check) root at the cwd's
# git toplevel (RepoRoot.code_root), so a run from the WRONG checkout — e.g. the
# hub primary on main — used to certify whatever tree it stood in and record
# GREEN "[…@<fp>]" evidence for code the task never touched. A fail-GREEN gate:
# hit live 2026-07-12, caught only downstream by bin/dor-check's fingerprint
# staleness. The gate KNOWS the task slug, so before running any lane it
# verifies the root IS the task's tree and REFUSES otherwise. Refusal (not a
# silent chdir into the task worktree): a chdir could green-cert a STALE
# worktree while the operator's real edits sat untested in the checkout they
# ran from — trading one fail-GREEN for another. Fail closed, say where to run.
#
# A root is accepted as the task's tree when EITHER:
#   - its checked-out branch is the task's branch (board metadata.devops.branch,
#     falling back to the feat/<slug> convention — the same resolution
#     bin/task stale uses), OR
#   - it is the task's worktree directory (…/.worktrees/<worktree_slug>), which
#     covers detached-HEAD states (mid-rebase) inside the right worktree.
#
# The guard applies only to the IMPLICIT root (cwd-resolved). An EXPLICIT
# override (FULL_SUITE_ROOT / FAST_CHECK_ROOT) bypasses it at the call site:
# the caller declared that root deliberately (the CI/test seam), and dor-check's
# fingerprint match against origin/<branch> stays the backstop either way.
#
# Board reads are best-effort: an unreachable board falls back to the naming
# conventions, so the hub-primary-on-main case still refuses offline.
module CertRootGuard
  module_function

  # nil when `root` is `slug`'s tree (the cert may proceed); else the refusal
  # message. A blank slug (standalone --print / hook runs) never refuses —
  # there is no task to root at.
  def refusal(task_bin:, slug:, root:)
    return nil if slug.to_s.strip.empty?

    devops = task_devops(task_bin, slug)
    expected_branch = first_present(devops["branch"], "feat/#{slug}")
    worktree_slug = first_present(devops["worktree_slug"], slug)
    actual_branch = current_branch(root)
    return nil if actual_branch == expected_branch
    return nil if worktree_dir?(root, worktree_slug)

    message = "this run roots at #{root} (branch #{actual_branch || 'unknown'}), " \
              "which is not #{slug}'s tree — refusing to certify it.\n" \
              "Expected branch #{expected_branch} or the task worktree .worktrees/#{worktree_slug}."
    hint = worktree_hint(worktree_slug)
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

  # A concrete on-disk worktree path to point the refusal at, when one exists
  # under the projects root (any app's .worktrees/). Best-effort.
  def worktree_hint(worktree_slug)
    Dir.glob(File.join(ProjectsRoot.default_projects_dir, "*", ".worktrees", worktree_slug)).first
  rescue StandardError
    nil
  end

  # The first argument whose string form isn't blank (nil when all are).
  def first_present(*values)
    values.find { |v| !v.to_s.strip.empty? }
  end
end
