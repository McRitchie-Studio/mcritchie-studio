# frozen_string_literal: true

# Unit tests for bin/lib/cert_root_guard.rb — the task-root guard both G1 cert
# runners (bin/fast-check, bin/full-suite-check) consult before certifying an
# IMPLICITLY-resolved root. A root is the task's tree when its checked-out
# branch is the task's branch (board devops.branch, else the feat/<slug>
# convention) or it is the task's .worktrees/<worktree_slug> dir; anything else
# refuses — the 2026-07-12 fail-GREEN certified the hub primary's main for an
# unrelated task. The shelled end-to-end refusals live in
# test/lib/fast_check_test.rb and test/lib/full_suite_check_test.rb.
#   ruby -Itest test/lib/cert_root_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "json"

require_relative "../../bin/lib/cert_root_guard"

class CertRootGuardTest < Minitest::Test
  # A throwaway git repo with one commit, optionally checked out to `branch`,
  # yielded as its realpath'd toplevel.
  def with_git_repo(branch: nil, dir: nil)
    holder = dir || Dir.mktmpdir
    FileUtils.mkdir_p(holder)
    real = File.realpath(holder)
    system("git", "-C", real, "init", "-q", out: File::NULL, err: File::NULL)
    system("git", "-C", real, "config", "user.email", "t@t.co")
    system("git", "-C", real, "config", "user.name", "T")
    File.write(File.join(real, "a.txt"), "x")
    system("git", "-C", real, "add", "-A", out: File::NULL, err: File::NULL)
    system("git", "-C", real, "commit", "-qm", "init", out: File::NULL, err: File::NULL)
    system("git", "-C", real, "checkout", "-qb", branch, out: File::NULL, err: File::NULL) if branch
    yield real
  ensure
    FileUtils.remove_entry(holder) if dir.nil? && holder && File.exist?(holder)
  end

  # A task_bin stub: `show <slug> --json` prints `json`; with json: nil it exits
  # 1 instead — the "board unreachable" case (guard falls back to conventions).
  def write_task_stub(json)
    dir = Dir.mktmpdir
    stub = File.join(dir, "task-stub")
    body = json ? "puts #{JSON.generate(json).dump}" : "exit 1"
    File.write(stub, "#!#{RbConfig.ruby}\n#{body}\n")
    FileUtils.chmod("+x", stub)
    stub
  end

  def devops_json(devops)
    { "metadata" => { "devops" => devops } }
  end

  # ── [unit] acceptance: branch match, worktree dir, blank slug ───────────────

  def test_blank_slug_never_refuses
    assert_nil CertRootGuard.refusal(task_bin: "/nonexistent", slug: nil, root: "/anywhere")
    assert_nil CertRootGuard.refusal(task_bin: "/nonexistent", slug: "  ", root: "/anywhere")
  end

  def test_conventional_feat_branch_is_accepted_when_the_board_is_unreachable
    stub = write_task_stub(nil) # board read fails → feat/<slug> convention
    with_git_repo(branch: "feat/task-x") do |repo|
      assert_nil CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo)
    end
  end

  def test_board_branch_is_authoritative_over_the_convention
    stub = write_task_stub(devops_json("branch" => "fix/custom-branch"))
    with_git_repo(branch: "fix/custom-branch") do |repo|
      assert_nil CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo),
                 "a board-recorded non-feat branch is the task's tree"
    end
    with_git_repo(branch: "feat/task-x") do |repo|
      refute_nil CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo),
                 "when the board names the branch, the convention no longer vouches"
    end
  end

  def test_the_tasks_worktree_dir_is_accepted_regardless_of_branch_state
    # Covers detached-HEAD / mid-rebase states INSIDE the right worktree: the
    # .worktrees/<worktree_slug> path itself identifies the task's tree.
    Dir.mktmpdir do |parent|
      wt = File.join(parent, ".worktrees", "task-x")
      with_git_repo(dir: wt) do |repo| # default branch ≠ feat/task-x
        assert_nil CertRootGuard.refusal(task_bin: write_task_stub(nil), slug: "task-x", root: repo)
      end
    end
  end

  # ── [unit] refusal: wrong root, message contents ─────────────────────────────

  def test_wrong_branch_refuses_with_the_expected_branch_named
    stub = write_task_stub(nil)
    with_git_repo do |repo| # default branch (main/master) ≠ feat/task-x
      message = CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo)
      refute_nil message, "the hub-primary-on-main case must refuse even offline"
      assert_includes message, "not task-x's tree"
      assert_includes message, "feat/task-x"
      assert_includes message, repo
    end
  end

  def test_refusal_names_the_boards_worktree_slug_when_it_differs
    stub = write_task_stub(devops_json("branch" => "feat/task-x", "worktree_slug" => "custom-worktree"))
    with_git_repo do |repo|
      message = CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo)
      assert_includes message, ".worktrees/custom-worktree"
    end
  end

  # ── [unit] helpers ───────────────────────────────────────────────────────────

  def test_current_branch_reads_the_checkout_and_nil_outside_git
    with_git_repo(branch: "feat/task-x") do |repo|
      assert_equal "feat/task-x", CertRootGuard.current_branch(repo)
    end
    Dir.mktmpdir { |dir| assert_nil CertRootGuard.current_branch(dir) }
  end

  def test_task_devops_is_empty_on_unreachable_board_or_bad_json
    assert_equal({}, CertRootGuard.task_devops(write_task_stub(nil), "task-x"))
    garbled = Dir.mktmpdir
    stub = File.join(garbled, "task-stub")
    File.write(stub, "#!#{RbConfig.ruby}\nputs 'not json'\n")
    FileUtils.chmod("+x", stub)
    assert_equal({}, CertRootGuard.task_devops(stub, "task-x"))
  end
end
