# frozen_string_literal: true

# Pure unit test for StaleCheck — branch resolution + the stale status decision,
# with the two git facts injected (no repo, no subprocess, no network). The
# full-process git behaviour is covered separately by the integration test in
# test/lib/task_cli_test.rb.
#
#   ruby -Itest test/lib/stale_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../lib/stale_check"

class StaleCheckTest < Minitest::Test
  def task(slug: "demo-task", stage: "building", branch: nil)
    devops = {}
    devops["branch"] = branch if branch
    { "slug" => slug, "stage" => stage, "metadata" => { "devops" => devops } }
  end

  # --- branch_for -------------------------------------------------------------

  def test_branch_for_defaults_to_feat_slug
    assert_equal "feat/demo-task", StaleCheck.branch_for(task)
  end

  def test_branch_for_prefers_an_explicit_devops_branch
    assert_equal "fix/out-of-band", StaleCheck.branch_for(task(branch: "fix/out-of-band"))
  end

  def test_branch_for_falls_back_when_devops_branch_is_blank
    assert_equal "feat/demo-task", StaleCheck.branch_for(task(branch: "  "))
  end

  # --- status -----------------------------------------------------------------

  # The headline drift: branch is on main, task hasn't shipped → STALE.
  def test_status_flags_an_on_main_branch_as_stale
    assert_equal :on_main, StaleCheck.status(task, branch_exists: true, on_main: true)
  end

  def test_status_treats_an_unmerged_branch_as_active
    assert_equal :not_merged, StaleCheck.status(task, branch_exists: true, on_main: false)
  end

  # A missing branch short-circuits BEFORE on_main, so a git error (on_main false)
  # never false-flags an absent branch.
  def test_status_skips_when_the_branch_does_not_exist
    assert_equal :no_branch, StaleCheck.status(task, branch_exists: false, on_main: false)
  end

  # Terminal stages short-circuit before any branch fact — even a real on-main
  # branch on a shipped task is expected, not stale.
  def test_status_is_terminal_for_shipped_and_archived
    %w[shipped archived].each do |stage|
      assert_equal :terminal,
                   StaleCheck.status(task(stage: stage), branch_exists: true, on_main: true),
                   "#{stage} must short-circuit to :terminal"
    end
  end
end
