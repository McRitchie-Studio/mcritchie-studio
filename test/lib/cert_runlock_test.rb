# frozen_string_literal: true

# THE RUNLOCK MUST BE INVISIBLE TO `git status`.
#
# The runlock's job is to SURVIVE a SIGKILLed cert — it is the only record of who the
# orphan is, so a cert that dies without running a handler MUST leave it behind. That
# makes it a durable file the cert creates in the repo. Put it in the working tree (it
# was `tmp/cert-run.json`) and it is an UNTRACKED FILE in any repo that does not happen
# to ignore `tmp/` — and `git check-ignore` says studio-engine and turf-vault do not.
#
# The cert also REFUSES a dirty tree (bin/lib/cert_tree_guard.rb, PR #546), reading
# dirtiness with `git status --porcelain`, which sees untracked-not-ignored files. Put
# those two together in studio-engine or turf-vault and the guard rebuilds the very
# deadlock it exists to end:
#
#   1. a SIGKILLed cert leaves the runlock                    — BY DESIGN
#   2. the next cert sees `?? tmp/` and aborts "tree is DIRTY"
#   3. THE ORPHAN PREFLIGHT NEVER RUNS — the orphan is never reaped, the lock is never
#      cleared, every retry hits the same wall, and the cert tells the agent to
#      `git add -A && git commit`: to COMMIT A RUNLOCK.
#
# Merge order does not save it (the two guard blocks are disjoint hunks; git merges them
# silently with the dirty guard on top), and "the sweep will order them" is a convention,
# not an invariant.
#
# So this file asserts the PROPERTY, not the spelling. It does NOT check "the lock is in
# .git" — that is an implementation detail, and a test that asserts it would still pass
# if `git status` grew a reason to see the file. It checks the thing that actually has to
# be true, through the exact predicate the dirty guard uses: AFTER WRITING THE RUNLOCK,
# `git status --porcelain` IS EMPTY — in a repo that ignores tmp/ AND in one that does
# not. Any lock location that satisfies that is correct; any that does not is the bug.
#
# Run directly:
#   ruby -Itest test/lib/cert_runlock_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "shellwords"
require "rbconfig"
require_relative "../../bin/lib/cert_orphan_guard"

class CertRunlockTest < Minitest::Test
  GUARD = File.expand_path("../../bin/lib/cert_orphan_guard", __dir__)

  # The two shapes of repo in this ecosystem, named so a failure says WHICH one broke.
  IGNORES_TMP = "log/*\n/tmp/\n"  # mcritchie-studio, turf-monster, rolio, solana-studio
  KEEPS_TMP   = "log/*\npkg/\n"   # studio-engine, turf-vault — where the deadlock lived

  def with_repo(gitignore)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".gitignore"), gitignore)
      File.write(File.join(dir, "README.md"), "fixture\n")
      %w[init config\ user.email\ t@example.com config\ user.name\ t add\ -A].each do |args|
        assert system("git", "-C", dir, *args.split, out: File::NULL, err: File::NULL), "git #{args}"
      end
      assert system("git", "-C", dir, "commit", "-qm", "init", out: File::NULL, err: File::NULL)
      assert_empty porcelain(dir), "the fixture must start CLEAN or it proves nothing"
      yield dir
    end
  end

  # The dirty-tree guard's own read (bin/lib/cert_tree_guard.rb): staged + unstaged +
  # untracked-not-ignored. This is the predicate the runlock must be invisible to, so it
  # is the predicate the test uses — not a stand-in for it.
  def porcelain(dir)
    `git -C #{dir.shellescape} status --porcelain`.strip
  end

  # --- [unit] THE INVARIANT ---------------------------------------------------------

  def assert_runlock_invisible_to_git(dir, repo)
    CertOrphanGuard.write_lock(dir, cert_pid: 4321, pgid: 4300,
                               cert_started_at: "Tue Jul 14 11:05:12 2026",
                               pgid_started_at: "Tue Jul 14 11:05:12 2026", lane: "spine")
    lock = CertOrphanGuard.lock_path(dir)

    assert File.exist?(lock), "the runlock must actually be WRITTEN (#{repo}) — a lock that " \
                              "does not survive is not a detection mechanism"
    assert_empty porcelain(dir),
                 "THE DEADLOCK IS BACK (#{repo}): the runlock is visible to `git status --porcelain`, " \
                 "so the dirty-tree guard will abort the next cert on the guard's OWN artefact and the " \
                 "orphan preflight will never run. The lock must live where git cannot see it."
    refute File.exist?(File.join(dir, "tmp", "cert-run.json")),
           "the runlock must not be back inside the tracked tree (#{repo})"
  end

  def test_the_runlock_is_invisible_to_git_status_where_tmp_is_ignored
    with_repo(IGNORES_TMP) { |dir| assert_runlock_invisible_to_git(dir, "a repo that ignores tmp/") }
  end

  # THE REGRESSION. This is the repo shape that deadlocked: studio-engine and turf-vault
  # do not ignore tmp/, so a lock at tmp/cert-run.json shows up as `?? tmp/`.
  def test_the_runlock_is_invisible_to_git_status_where_tmp_is_not_ignored
    with_repo(KEEPS_TMP) { |dir| assert_runlock_invisible_to_git(dir, "a repo that does NOT ignore tmp/") }
  end

  # The property must not depend on the repo's .gitignore AT ALL — that is the whole point
  # of making it structural. A repo that ignores NOTHING is the strongest form of the case.
  def test_the_runlock_is_invisible_even_with_an_empty_gitignore
    with_repo("") { |dir| assert_runlock_invisible_to_git(dir, "a repo with an EMPTY .gitignore") }
  end

  # --- [unit] the lock still WORKS where it now lives ---------------------------------

  def test_the_lock_round_trips_where_the_guard_writes_it
    with_repo(KEEPS_TMP) do |dir|
      CertOrphanGuard.write_lock(dir, cert_pid: 4321, pgid: 4300,
                                 pgid_started_at: "Tue Jul 14 11:05:12 2026", lane: "spine")
      lock = CertOrphanGuard.read_lock(dir)

      assert_equal 4321, lock["cert_pid"], "the guard must READ the lock it WRITES"
      assert_equal 4300, lock["pgid"]
      assert_equal "Tue Jul 14 11:05:12 2026", lock["pgid_started_at"], "identity survives the round trip"

      CertOrphanGuard.clear_lock(dir)
      assert_nil CertOrphanGuard.read_lock(dir), "clear_lock must clear the lock it wrote"
    end
  end

  # --- [integration] the WORKTREE case: a lock PER DESK, still invisible ---------------
  #
  # `git rev-parse --absolute-git-dir` answers `<main>/.git/worktrees/<name>` inside a
  # worktree, so each desk keeps its OWN lock exactly as it did when the lock lived in
  # the desk's own tmp/. Verified, not assumed — a shared lock across worktrees would
  # have one desk's cert refusing (or reaping!) another desk's suite.

  def test_each_worktree_gets_its_own_lock_and_git_still_cannot_see_it
    with_repo(KEEPS_TMP) do |main|
      desk = File.join(Dir.mktmpdir, "desk-a")
      assert system("git", "-C", main, "worktree", "add", "-q", "-b", "feat/desk-a", desk,
                    out: File::NULL, err: File::NULL), "could not create the worktree"

      CertOrphanGuard.write_lock(main, cert_pid: 111, pgid: 100, pgid_started_at: "x")
      CertOrphanGuard.write_lock(desk, cert_pid: 222, pgid: 200, pgid_started_at: "y")

      refute_equal CertOrphanGuard.lock_path(main), CertOrphanGuard.lock_path(desk),
                   "a worktree must not SHARE the main checkout's runlock — one desk's cert would " \
                   "then refuse, or reap, another desk's suite"
      assert_equal 111, CertOrphanGuard.read_lock(main)["cert_pid"], "the main checkout keeps its own lock"
      assert_equal 222, CertOrphanGuard.read_lock(desk)["cert_pid"], "the desk keeps its own lock"
      assert_includes CertOrphanGuard.lock_path(desk), File.join(".git", "worktrees"),
                      "a worktree's lock belongs to its per-worktree git dir"

      assert_empty porcelain(desk), "the runlock must be invisible to `git status` INSIDE a worktree too"
      assert_empty porcelain(main), "…and it must not dirty the main checkout either"
    end
  end

  # --- [integration] it still survives a SIGKILL — the whole detection mechanism -------
  #
  # A SIGKILLed cert runs NO handler: it cannot clean up, and it must not. The lock it
  # leaves behind is the only evidence naming the orphan it stranded. If moving the lock
  # had made it disappear with the process (a tmpfs, a pid dir), the guard would have
  # nothing to read and the orphan would be undetectable — the fix would have deleted the
  # feature. So: kill -9 a real process that wrote a real lock, and prove the lock is
  # still there, still readable, still graded, and STILL invisible to git.

  def test_a_sigkilled_cert_leaves_a_readable_runlock_that_git_still_cannot_see
    with_repo(KEEPS_TMP) do |dir|
      # The readiness marker lives OUTSIDE the repo: this test asserts the tree is clean,
      # so a fixture file dropped in the tree would be dirt of the test's own making and
      # would fail the assertion for the wrong reason. (It did, first run — the test is
      # strict enough to catch its own author.)
      ready = File.join(Dir.mktmpdir, "ready")
      script = <<~RUBY
        require #{GUARD.inspect}
        CertOrphanGuard.write_lock(#{dir.inspect}, cert_pid: Process.pid, pgid: Process.getpgrp,
                                   pgid_started_at: "Tue Jul 14 11:05:12 2026", lane: "spine")
        File.write(#{ready.inspect}, "1")
        sleep 60
      RUBY
      cert = Process.spawn(RbConfig.ruby, "-e", script, out: File::NULL, err: File::NULL)
      deadline = Time.now + 10
      sleep 0.05 until File.exist?(ready) || Time.now > deadline
      assert File.exist?(ready), "the fixture cert never wrote its lock"

      Process.kill("KILL", cert) # the harness timeout, at its most brutal: no handler runs
      Process.waitpid(cert)

      lock = CertOrphanGuard.read_lock(dir)
      refute_nil lock, "a SIGKILLed cert MUST leave its runlock — it is the only record of the orphan"
      assert_equal cert, lock["cert_pid"], "the surviving lock still names the dead cert"
      assert_empty porcelain(dir),
                   "the lock a SIGKILLed cert leaves behind is precisely the one the dirty-tree guard " \
                   "would have tripped on — it must be invisible to `git status`"

      # And it is still GRADED: the cert is dead and its group is gone, so this is a stale
      # lock — cleared, never treated as a live claim.
      verdict, = CertOrphanGuard.decide(lock: lock, table: [])
      assert_equal :stale, verdict, "a dead cert's lock must grade :stale, not block the next cert"
    end
  end

  # --- [unit] a root that is not a git repo at all ------------------------------------
  #
  # The unit fixtures (and a tarball checkout) are not repos. There is no `git status`
  # there to be dirt to, so the tmp/ fallback is safe — but it must still round-trip.
  def test_a_non_git_root_falls_back_to_the_tree_and_still_round_trips
    Dir.mktmpdir do |dir|
      CertOrphanGuard.write_lock(dir, cert_pid: 7, pgid: 8, pgid_started_at: "z")

      assert_equal File.join(dir, "tmp", "cert-run.json"), CertOrphanGuard.lock_path(dir),
                   "with no repo there is no git dir to hide in — fall back to the tree"
      assert_equal 7, CertOrphanGuard.read_lock(dir)["cert_pid"]
    end
  end
end
