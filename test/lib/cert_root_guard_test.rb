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

  # ── [unit] BOTH desk layouts ─────────────────────────────────────────────────
  # A desk is written two ways on this machine, and the guard used to know one:
  #
  #   <projects>/<repo>/.worktrees/<slug>   the MANAGED layout bin/agent-worktree builds
  #   <projects>/<repo>.worktrees/<slug>    the SIBLING tree the gem repos use
  #
  # The sibling tree exists because bin/agent-worktree manages only the registered
  # Rails apps, so studio-engine and solana-studio desks are cut with a plain
  # `git worktree add` and land beside the repo. Reading only the managed layout made
  # the guard refuse a REAL desk while reporting it was not on disk — a refusal that
  # is right about the verdict, wrong about the reason, and whose remedy line pointed
  # somewhere the desk was not. Reviewers answered it by exporting
  # DOR_CHECK_DIFF_ROOT on every engine review, which is a guard training people to
  # override it.

  # A desk in the SIBLING tree. Yields [projects, desk].
  def with_sibling_desk(app: "studio-engine", slug: "task-x", branch: "feat/task-x")
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      with_git_repo(branch: branch, dir: File.join(projects, "#{app}.worktrees", slug)) do |desk|
        yield projects, desk
      end
    end
  end

  def test_worktree_candidates_finds_a_desk_in_the_sibling_tree
    with_sibling_desk do |projects, desk|
      assert_equal [desk], CertRootGuard.worktree_candidates("task-x", projects),
                   "a desk in the sibling tree is ON DISK; the glob simply could not see it"
    end
  end

  def test_app_of_names_the_repo_for_a_sibling_tree_desk
    assert_equal "studio-engine", CertRootGuard.app_of("/p/studio-engine.worktrees/task-x")
    assert_equal "studio-engine", CertRootGuard.app_of("/p/studio-engine.worktrees/task-x/")
    # The pre-fix answer was "task-x". Not a miss — an unrecognised desk takes the
    # PRIMARY-checkout branch, whose answer is the last path segment — so it returned
    # the task SLUG as a repo name, confidently, to two callers that compare it.
    refute_equal "task-x", CertRootGuard.app_of("/p/studio-engine.worktrees/task-x")
    # The layouts it already knew must not have moved.
    assert_equal "turf-monster", CertRootGuard.app_of("/p/turf-monster/.worktrees/task-x")
    assert_equal "turf-monster", CertRootGuard.app_of("/p/turf-monster")
  end

  def test_the_writer_certifies_from_a_sibling_tree_desk_whatever_its_branch
    # The WRITER's physical vouch, sibling-tree twin of
    # test_the_tasks_worktree_dir_is_accepted_regardless_of_branch_state. Pre-fix a
    # builder mid-rebase in an engine desk was refused for the one reason that could
    # not be true: that they were not standing at the task's desk. They were in it.
    Dir.mktmpdir do |parent|
      desk = File.join(parent, "studio-engine.worktrees", "task-x")
      with_git_repo(dir: desk) do |real| # default branch, NOT feat/task-x
        assert_nil CertRootGuard.refusal(task_bin: write_task_stub(nil), slug: "task-x", root: real)
      end
    end
  end

  def test_assess_resolves_a_sibling_tree_desk_for_the_reader
    with_sibling_desk do |projects, desk|
      with_git_repo do |primary| # not the task's branch — the wrong-root case
        found = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                     root: primary, projects_dir: projects)
        refute_nil found, "a primary checkout is still not the task's tree"
        assert_equal desk, found[:resolved_root],
                     "the READER must re-root at the sibling desk, not report no desk at all"
      end
    end
  end

  # ── [unit] the two cases a second glob alone would get wrong ────────────────

  def test_a_slug_present_in_BOTH_layouts_is_ambiguous_and_resolves_to_nothing
    # THE DECISION. Both layouts feed one candidate list and neither outranks the
    # other, so two desks that each pass every axis leave the guard with no fact to
    # choose on — and it refuses instead of picking. Ranking (managed beats sibling)
    # would be the cheaper fix and the wrong one: bin/agent-worktree#worktree_dir
    # records hard-coding one layout "destroy[ing] the WRONG DESK the moment the same
    # desk name exists in both trees". A gate grading the wrong tree fails the same
    # way and looks exactly like a real verdict.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      managed = File.join(projects, "studio-engine", ".worktrees", "task-x")
      sibling = File.join(projects, "studio-engine.worktrees", "task-x")
      with_git_repo(branch: "feat/task-x", dir: managed) do |m|
        with_git_repo(branch: "feat/task-x", dir: sibling) do |s|
          assert_equal [m, s].sort, CertRootGuard.worktree_candidates("task-x", projects).sort,
                       "both layouts are candidates; the set is the fact, the pick would be a guess"
          with_git_repo do |primary|
            found = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                         root: primary, projects_dir: projects)
            assert_equal [m, s].sort, found[:eligible_roots].sort, "both pass every axis"
            assert_nil found[:resolved_root],
                       "two qualified desks and nothing to separate them: refuse, never rank"
            assert_includes found[:message], "nothing separates them"
            assert_includes found[:message], m, "the refusal must NAME both, so the reader can choose"
            assert_includes found[:message], s
          end
        end
      end
    end
  end

  def test_no_desk_in_either_layout_still_refuses_and_says_which_layouts_it_searched
    # FAIL CLOSED is the half a second glob must not cost. A desk found at NEITHER
    # path is still a refusal, and the text now says so positively instead of leaving
    # the reader to infer it from a missing line.
    Dir.mktmpdir do |empty|
      with_git_repo do |primary|
        found = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                     root: primary, projects_dir: empty)
        refute_nil found, "no desk anywhere is still not-the-task's-tree"
        assert_nil found[:resolved_root], "inventing a path here would be the fail-GREEN"
        assert_empty found[:candidate_roots]
        assert_includes found[:message], "No desk for task-x exists"
        assert_includes found[:message], empty, "name the root that was searched"
        assert_includes found[:message], "<repo>/.worktrees/task-x", "name the managed layout"
        assert_includes found[:message], "<repo>.worktrees/task-x", "name the sibling layout"
        refute_includes found[:message], "cd ", "there is nowhere to cd; do not invent a destination"
      end
    end
  end

  # ── [unit] the message tells the reader WHICH situation they are in ─────────

  def test_the_message_distinguishes_a_missing_desk_from_a_mis_rooted_run
    # The two need OPPOSITE actions — create a desk, versus go stand in the one you
    # already have — and pre-fix they rendered as the same text minus a `cd` line.
    # Silence was doing double duty, so the reviewer whose sibling desk WAS on disk
    # went looking for a missing directory and found it.
    missing = Dir.mktmpdir do |empty|
      with_git_repo do |primary|
        CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                             root: primary, projects_dir: empty)[:message]
      end
    end

    with_sibling_desk do |projects, desk|
      with_git_repo do |primary|
        mis_rooted = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                          root: primary, projects_dir: projects)[:message]
        assert_includes mis_rooted, "cd #{desk}", "a desk that exists gets a destination"
        refute_includes mis_rooted, "No desk for", "it must not claim a desk that is right there"
        assert_includes missing, "No desk for"
        refute_equal missing, mis_rooted, "a reader must be able to tell these two apart"
      end
    end
  end

  def test_a_desk_that_exists_but_never_carried_the_branch_names_the_axis_it_failed
    # The third situation: on disk, but not this task's tree. "Your desk is stale" and
    # "your desk is another repo's" need opposite fixes, so the refusal names the path
    # AND the axis rather than falling back to the no-desk-anywhere wording.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      stale = File.join(projects, "studio-engine.worktrees", "task-x")
      with_git_repo(branch: "release", dir: stale) do |real|
        with_git_repo do |primary|
          found = CertRootGuard.assess(task_bin: write_task_stub(nil), slug: "task-x",
                                       root: primary, projects_dir: projects)
          assert_equal [real], found[:candidate_roots], "it IS on disk — the guard must say so"
          assert_nil found[:resolved_root], "fail closed: a stale desk is not the task's tree"
          assert_includes found[:message], "IS on disk"
          assert_includes found[:message], "is on branch release, not feat/task-x"
          refute_includes found[:message], "No desk for", "it exists; do not report it missing"
        end
      end
    end
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
