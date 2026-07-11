# frozen_string_literal: true

# ProjectsRoot — the projects-root default the bin/ stack repeats: the repo's
# parent directory, EXCEPT when the repo is an isolated worktree under
# <primary>/.worktrees/ — then climb out to the primary's parent, so a worktree
# run still shares the primary's .agents/ state (registry, markers, token cache).
#
# Only the DEFAULT lives here. The ENV seam stays at each caller — bin/qa-intake,
# bin/agent-worktree and bin/qa-server honor PROJECTS_DIR while bin/task and the
# narration stack honor CLAUDE_PROJECTS_DIR — and must not be unified.
module ProjectsRoot
  # The repo this bin/ stack ships in (bin/lib/ → two levels up). A worktree
  # ships its own bin/, so this resolves to the worktree root there.
  REPO_ROOT = File.expand_path("../..", __dir__)

  module_function

  def default_projects_dir(repo_root = REPO_ROOT)
    candidate = File.dirname(repo_root)
    if File.basename(candidate) == ".worktrees"
      File.expand_path("../..", candidate)
    else
      candidate
    end
  end
end
