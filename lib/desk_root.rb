# frozen_string_literal: true

# DeskRoot — where a MANAGED desk lives, stated once for both sides of the desk ledger.
#
# `bin/agent-worktree` cuts every desk into `<repo>/.worktrees/<desk>` or, for the gem repos,
# `<repo>.worktrees/<desk>`. Anything else `git worktree list` shows (a reviewer's
# `carl-review-*-mutation`, a session scratchpad's `wt-*`, Claude Code's
# `<repo>/.claude/worktrees/*`) was cut by something that binds no task and tears it down
# with plain `git worktree remove`. The sweep LISTS those and never nominates them
# (bin/agent-worktree#managed_desk_hold), and since 2026-09-30 the board LISTS them and
# never opens a ledger episode for them (DeskRecord.sync!). Before that, each one became a
# `vanished` ghost on the Desks panel the moment its reviewer deleted it.
#
# TWO QUESTIONS, ONE RULE.
#
#   roots_for(repo)       — the CLI knows the repo, so it asks the strict question: is the
#                           desk's parent one of THIS repo's two roots? That verdict guards a
#                           DESTROY path (reclaim), so it must never read a stranger's tree
#                           as ours.
#   managed_path?(path)   — the board holds only a path (a record whose desk is gone has no
#                           registry row to ask). It asks the same rule with the repo left
#                           open: is the parent `<R>/.worktrees` or `<R>.worktrees` for SOME
#                           repo R? That is exactly "the parent's name ends in .worktrees".
#
# The looser form errs toward MANAGED, which on the ledger side is the loud direction: a
# managed desk that vanishes is REPORTED (DeskRecord.vanished), never auto-closed. Erring the
# other way would silence the defect detector, so the board never uses a looser test than this.
#
# Pure Ruby, no Rails: bin/agent-worktree requires it directly, the app autoloads it.
module DeskRoot
  MANAGED_DIR = ".worktrees"

  module_function

  # The two trees this tooling cuts desks into for `repo` (not canonicalized; the CLI
  # realpaths them itself).
  def roots_for(repo)
    [File.join(repo, MANAGED_DIR), "#{repo}#{MANAGED_DIR}"]
  end

  # True when `path` sits directly inside `<R>/.worktrees` or `<R>.worktrees` for some R.
  def managed_path?(path)
    text = path.to_s.strip
    return false if text.empty?

    File.basename(File.dirname(text)).end_with?(MANAGED_DIR)
  end
end
