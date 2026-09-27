# frozen_string_literal: true

require "test_helper"
require_relative "../support/agent_worktree_fixture"

# The REAL binary against a staged hub: a worktree git registered OUTSIDE `.worktrees/`.
#
# `doctor` used to report such a worktree as an "untracked git worktree … review then
# remove", and `snapshot` left it off the registry, so the Desks panel never saw it —
# measured 2026-09-26, 13 desks hid that way (task desk-audit-sees-every-desk). It is a
# desk of its repo now: the snapshot lists it, labelled with the repo, and doctor stops
# advising its removal. The pure enumeration is unit-tested in
# test/lib/agent_worktree_desk_discovery_test.rb.
class AgentWorktreeDeskDiscoveryCommandTest < ActiveSupport::TestCase
  include AgentWorktreeFixture

  test "[integration] an out-of-tree worktree is a snapshot desk of its repo, not a doctor orphan" do
    stray = File.join(@projects_dir, "stray-worktree")
    git!(@hub_dir, "worktree", "add", stray, "-b", "stray/orphan")

    doctor, err, status = agent_worktree("doctor", "mcritchie-studio", env: command_env)
    assert status.success?, err
    assert_no_match(/untracked git worktree/, doctor, "a registered worktree is a desk, not an orphan to remove")

    snapshot, err, status = agent_worktree("snapshot", "mcritchie-studio", env: command_env)
    assert status.success?, err
    desks = JSON.parse(snapshot).fetch("worktrees")
    desk = desks.find { |entry| entry["worktree"] == File.realpath(stray) }

    refute_nil desk, "the snapshot must list the out-of-tree desk; it listed #{desks.map { |d| d["worktree"] }.inspect}"
    assert_equal "mcritchie-studio/stray-worktree", desk["label"], "labelled with its REAL repo"
    assert_equal "stray/orphan", desk["branch"]
    assert_nil desk["app_port"], "a desk outside the managed tree has no stack env, and no port"
    assert_equal 1, desks.count { |entry| File.realpath(entry["worktree"]) == File.realpath(@worktree_dir) },
                 "the managed desk git also lists is enumerated ONCE — the ledger keys on the path"
  end
end
