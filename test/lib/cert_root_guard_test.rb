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

  # ── [unit] assess: the RESOLVE half (bin/dor-check's remedy) ─────────────────
  # The cert writers refuse a foreign root; the READER re-roots at it. #assess is
  # what tells it where — and it must never claim a worktree that isn't there.

  def test_assess_returns_nil_when_the_root_is_the_tasks_tree
    stub = write_task_stub(nil)
    with_git_repo(branch: "feat/task-x") do |repo|
      assert_nil CertRootGuard.assess(task_bin: stub, slug: "task-x", root: repo),
                 "nil is the whole contract for 'this IS the task's tree — proceed'"
    end
  end

  def test_assess_resolves_the_tasks_worktree_when_it_is_on_disk
    # The production case: the agent stands in the PRIMARY, the task's code lives in
    # <app>/.worktrees/<slug>. assess must hand the reader that path to re-root at.
    with_projects_dir do |projects, worktree|
      with_git_repo do |primary| # NOT the task's branch — the wrong-root case
        found = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                     root: primary, projects_dir: projects)
        refute_nil found, "a primary checkout is not the task's tree"
        assert_equal worktree, found[:resolved_root]
        assert_equal "feat/task-x", found[:expected_branch]
        assert_equal "task-x", found[:worktree_slug]
        refute_nil found[:message], "the refusal text is still available to the cert writers"
      end
    end
  end

  def test_assess_resolved_root_is_nil_when_no_worktree_exists
    # No worktree on disk → the reader gets nil and must NOT re-root; it falls back
    # to the branch tree, or refuses. Inventing a path here would be the fail-GREEN.
    Dir.mktmpdir do |empty_projects|
      with_git_repo do |primary|
        found = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                     root: primary, projects_dir: empty_projects)
        refute_nil found
        assert_nil found[:resolved_root]
      end
    end
  end

  def test_assess_reports_the_branch_the_caller_is_actually_standing_on
    stub = write_task_stub(nil)
    with_git_repo(branch: "release") do |repo|
      found = CertRootGuard.assess(task_bin: stub, slug: "task-x", root: repo)
      assert_equal "release", found[:actual_branch], "the loud re-root banner names where you WERE"
    end
  end

  def test_assess_accepts_a_prefetched_devops_without_reading_the_board
    # dor-check already holds the task when it consults the guard. Passing devops:
    # must skip the board read entirely — a stub that would BLOW UP if executed
    # proves it never runs.
    exploding = "/nonexistent/task-bin-that-must-never-run"
    with_git_repo(branch: "fix/custom") do |repo|
      assert_nil CertRootGuard.assess(task_bin: exploding, slug: "task-x", root: repo,
                                      devops: { "branch" => "fix/custom" }),
                 "the prefetched branch is authoritative and the board is never called"
    end
  end

  def test_refusal_still_returns_the_message_string
    # Backwards compatibility: bin/fast-check and bin/full-suite-check call #refusal
    # and abort on a truthy String. #assess must not have changed that contract.
    stub = write_task_stub(nil)
    with_git_repo(branch: "feat/task-x") do |repo|
      assert_nil CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo)
    end
    with_git_repo do |repo|
      message = CertRootGuard.refusal(task_bin: stub, slug: "task-x", root: repo)
      assert_kind_of String, message
      assert_includes message, "refusing to certify it"
    end
  end

  # ── [unit] helpers ───────────────────────────────────────────────────────────

  # A temp projects root holding <app>/.worktrees/task-x as a real git repo on the
  # task's branch — the layout worktree_hint globs for. Yields [projects, worktree].
  def with_projects_dir
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      worktree = File.join(projects, "myapp", ".worktrees", "task-x")
      with_git_repo(branch: "feat/task-x", dir: worktree) do |real|
        yield projects, real
      end
    end
  end

  def test_worktree_hint_finds_any_apps_worktree_and_nil_otherwise
    # The glob spans every app because a SATELLITE task's worktree lives under the
    # satellite, not under the hub whose gate scripts are running.
    with_projects_dir do |projects, worktree|
      assert_equal worktree, CertRootGuard.worktree_hint("task-x", projects)
      assert_nil CertRootGuard.worktree_hint("task-never-created", projects)
    end
  end


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
