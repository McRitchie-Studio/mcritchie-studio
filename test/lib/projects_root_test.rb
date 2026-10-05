# frozen_string_literal: true

# Tests for bin/lib/projects_root.rb — the projects-root default shared by
# bin/task, bin/qa-intake, bin/qa-server, bin/agent-worktree, bin/pr-review and
# bin/lib/agent_api.rb. Only the DEFAULT is shared; the PROJECTS_DIR vs
# CLAUDE_PROJECTS_DIR env seams stay per-caller by design.
#   ruby -Itest test/lib/projects_root_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require File.expand_path("../../bin/lib/projects_root", __dir__)

class ProjectsRootTest < Minitest::Test
  def test_unit_primary_checkout_resolves_to_the_repo_parent
    assert_equal "/Users/x/projects",
                 ProjectsRoot.default_projects_dir("/Users/x/projects/mcritchie-studio")
  end

  def test_unit_worktree_climbs_out_to_the_primary_parent
    assert_equal "/Users/x/projects",
                 ProjectsRoot.default_projects_dir("/Users/x/projects/mcritchie-studio/.worktrees/my-task"),
                 "a worktree run shares the primary's .agents/ state"
  end

  def test_unit_fixed_path_tooling_climbs_out_to_the_projects_dir
    Dir.mktmpdir do |projects|
      tree = File.join(projects, ".agents", "tooling", "0123abc")
      FileUtils.mkdir_p(tree)
      File.write(File.join(tree, ".complete"), "0123abc\n")
      assert_equal projects, ProjectsRoot.default_projects_dir(tree),
                   "the installed fast-lane tooling shares the same .agents/ state as the hub"
    end
  end

  def test_unit_a_dir_named_tooling_without_the_install_marker_is_an_ordinary_repo
    Dir.mktmpdir do |projects|
      repo = File.join(projects, "tooling", "some-repo")
      FileUtils.mkdir_p(repo)
      assert_equal File.join(projects, "tooling"), ProjectsRoot.default_projects_dir(repo)
    end
  end

  def test_unit_repo_root_anchors_at_this_repo
    assert_equal File.expand_path("../..", __dir__), ProjectsRoot::REPO_ROOT
  end

  # ── for_script: the root a bin/ script resolves, through the fixed-path link ──
  #
  # A hook command names `<projects>/.agents/bin/<script>`, a symlink into
  # tooling/<sha>/bin. Ruby's __dir__ realpaths, so a Ruby script already climbs
  # from the tooling tree; a shell script's `dirname "${BASH_SOURCE[0]}"` is the
  # LINK path, and `..` from it is `<projects>/.agents` — the right answer only by
  # accident of a logical `pwd`. for_script resolves the link first.

  def test_unit_for_script_climbs_from_the_tooling_tree_through_the_link
    with_tooling_install do |projects, tree|
      assert_equal projects, ProjectsRoot.for_script(File.join(projects, ".agents", "bin", "codex-session-title")),
                   "a script reached through the .agents/bin link climbs from its real tooling tree"
      assert_equal projects, ProjectsRoot.for_script(File.join(tree, "bin", "codex-session-title")),
                   "the same script reached at its SHA-pinned path resolves the same root"
    end
  end

  def test_unit_for_script_from_a_worktree_and_a_primary
    Dir.mktmpdir do |dir|
      projects = File.realpath(dir)
      primary = File.join(projects, "mcritchie-studio")
      desk = File.join(primary, ".worktrees", "my-task")
      [primary, desk].each { |root| FileUtils.mkdir_p(File.join(root, "bin")) }
      [primary, desk].each do |root|
        script = File.join(root, "bin", "install-agent-docs")
        File.write(script, "")
        assert_equal projects, ProjectsRoot.for_script(script)
      end
    end
  end

  def test_unit_cli_prints_for_script_for_a_shell_caller
    with_tooling_install do |projects, tree|
      cli = File.join(tree, "bin", "lib", "projects_root.rb")
      out = IO.popen(["ruby", cli, File.join(projects, ".agents", "bin", "codex-session-title")], &:read)
      assert_equal projects, out.strip,
                   "a shell script cannot require this file, so it runs it: `ruby bin/lib/projects_root.rb \"$0\"`"
    end
  end

  # ── hub_checkout / git_checkout: a git tree for a stack with no .git ─────────

  def test_unit_hub_checkout_is_the_hub_sibling_of_the_projects_root
    with_tooling_install do |projects, tree|
      assert_equal File.join(projects, "mcritchie-studio"), ProjectsRoot.hub_checkout(tree)
    end
    assert_equal "/Users/x/projects/mcritchie-studio",
                 ProjectsRoot.hub_checkout("/Users/x/projects/mcritchie-studio/.worktrees/my-task")
  end

  def test_unit_git_checkout_is_the_tree_itself_when_it_is_a_checkout
    Dir.mktmpdir do |projects|
      primary = File.join(projects, "mcritchie-studio")
      FileUtils.mkdir_p(File.join(primary, ".git"))
      assert_equal primary, ProjectsRoot.git_checkout(primary)

      desk = File.join(primary, ".worktrees", "my-task")
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".git"), "gitdir: #{primary}/.git/worktrees/my-task\n")
      assert_equal desk, ProjectsRoot.git_checkout(desk), "a worktree's .git is a FILE, and it is still a checkout"
    end
  end

  def test_unit_git_checkout_falls_back_to_the_hub_from_the_tooling_tree
    with_tooling_install do |projects, tree|
      assert_equal File.join(projects, "mcritchie-studio"), ProjectsRoot.git_checkout(tree),
                   "the installed tooling tree has no .git, so git runs in the hub primary beside the projects root"
    end
  end

  private

  # <projects>/.agents/tooling/<sha>/ stamped `.complete`, with <projects>/.agents/bin
  # linked onto its bin/ exactly as bin/install-agent-docs leaves it. Yields the
  # realpath'd projects dir, since for_script answers through File.realpath.
  def with_tooling_install
    Dir.mktmpdir do |dir|
      projects = File.realpath(dir)
      tree = File.join(projects, ".agents", "tooling", "0123abc")
      FileUtils.mkdir_p(File.join(tree, "bin", "lib"))
      File.write(File.join(tree, ".complete"), "0123abc\n")
      FileUtils.cp(File.expand_path("../../bin/lib/projects_root.rb", __dir__), File.join(tree, "bin", "lib"))
      File.write(File.join(tree, "bin", "codex-session-title"), "")
      File.symlink("tooling/0123abc/bin", File.join(projects, ".agents", "bin"))
      yield projects, tree
    end
  end
end
