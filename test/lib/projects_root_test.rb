# frozen_string_literal: true

# Tests for bin/lib/projects_root.rb — the projects-root default shared by
# bin/task, bin/qa-intake, bin/qa-server, bin/agent-worktree, bin/pr-review and
# bin/lib/agent_api.rb. Only the DEFAULT is shared; the PROJECTS_DIR vs
# CLAUDE_PROJECTS_DIR env seams stay per-caller by design.
#   ruby -Itest test/lib/projects_root_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

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

  def test_unit_repo_root_anchors_at_this_repo
    assert_equal File.expand_path("../..", __dir__), ProjectsRoot::REPO_ROOT
  end
end
