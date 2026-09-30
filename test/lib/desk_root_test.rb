# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/desk_root"

# The managed desk root rule both sides of the desk ledger read (bin/agent-worktree and
# DeskRecord.sync!). Pure Ruby, so no Rails boot.
class DeskRootTest < Minitest::Test
  def test_unit_the_two_managed_roots_of_a_repo
    assert_equal ["/p/turf-monster/.worktrees", "/p/turf-monster.worktrees"], DeskRoot.roots_for("/p/turf-monster")
  end

  def test_unit_a_desk_in_either_managed_root_is_managed
    assert DeskRoot.managed_path?("/p/mcritchie-studio/.worktrees/some-task")
    assert DeskRoot.managed_path?("/p/studio-engine.worktrees/some-task")
  end

  def test_unit_scratch_and_tool_worktrees_are_not_managed
    refute DeskRoot.managed_path?("/private/tmp/claude-501/x/scratchpad/wt-review")
    refute DeskRoot.managed_path?("/p/mcritchie-studio/.claude/worktrees/agent-1")
    refute DeskRoot.managed_path?("/p/mcritchie-studio/.worktrees"), "the root itself is not a desk"
    refute DeskRoot.managed_path?("")
    refute DeskRoot.managed_path?(nil)
  end
end
