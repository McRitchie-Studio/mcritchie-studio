# frozen_string_literal: true

# ProjectsRoot — the projects-root default the bin/ stack repeats: the repo's
# parent directory, EXCEPT when the repo is an isolated worktree under
# <primary>/.worktrees/ — then climb out to the primary's parent, so a worktree
# run still shares the primary's .agents/ state (registry, markers, token cache).
# The same holds for the FIXED-PATH TOOLING install (bin/install-agent-docs):
# its tooling/<sha>/ tree (marked `.complete`) climbs out to <projects>.
#
# Only the DEFAULT lives here. The ENV seam stays at each caller — bin/qa-intake,
# bin/agent-worktree and bin/qa-server honor PROJECTS_DIR while bin/task and the
# narration stack honor CLAUDE_PROJECTS_DIR — and must not be unified.
#
# A shell script cannot require this file, so it RUNS it instead:
#
#   PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$(ruby "$BIN_DIR/lib/projects_root.rb" "${BASH_SOURCE[0]}")}"
#
# which prints `for_script` for the script's own path. That is the one resolver for
# the three layouts, so a bash copy of the climb cannot drift from the Ruby one.
module ProjectsRoot
  # The repo this bin/ stack ships in (bin/lib/ → two levels up). A worktree
  # ships its own bin/, so this resolves to the worktree root there.
  REPO_ROOT = File.expand_path("../..", __dir__)

  # The hub's directory name beside the projects root.
  HUB_REPO = "mcritchie-studio"

  module_function

  def default_projects_dir(repo_root = REPO_ROOT)
    candidate = File.dirname(repo_root)
    if File.basename(candidate) == ".worktrees"
      File.expand_path("../..", candidate)
    elsif File.basename(candidate) == "tooling" && File.file?(File.join(repo_root, ".complete"))
      # The installed tooling tree: <projects>/<state>/tooling/<sha>/, stamped
      # `.complete` by bin/install-agent-docs. Two levels up is <projects>.
      File.expand_path("../..", candidate)
    else
      candidate
    end
  end

  # The projects root for the bin/ script at `path`, resolved as Ruby's __dir__
  # resolves it: through symlinks first. A hook names `<projects>/.agents/bin/<script>`,
  # a link into tooling/<sha>/bin, and only the real tree carries the `.complete`
  # marker the climb above reads.
  def for_script(path)
    default_projects_dir(File.expand_path("..", File.dirname(File.realpath(path))))
  end

  # The hub primary checkout beside the projects root.
  def hub_checkout(repo_root = REPO_ROOT)
    File.join(default_projects_dir(repo_root), HUB_REPO)
  end

  # A git work tree sharing the hub's origin refs, for the bin/ stack at `repo_root`:
  # the tree itself when it is a checkout (a primary's .git is a directory, a
  # worktree's is a file), else the hub primary, because the installed tooling tree
  # has no .git and `git -C` there answers nothing.
  def git_checkout(repo_root = REPO_ROOT)
    File.exist?(File.join(repo_root, ".git")) ? repo_root : hub_checkout(repo_root)
  end
end

if __FILE__ == $PROGRAM_NAME
  puts(ARGV.empty? ? ProjectsRoot.default_projects_dir : ProjectsRoot.for_script(ARGV.fetch(0)))
end
