# frozen_string_literal: true

# Tests for bin/lib/repo_root.rb — the CODE-root resolver both merge gates
# (bin/full-suite-check, bin/dor-check) default to, so a task in a SATELLITE
# worktree certifies the satellite, not the hub the gate script lives in.
#   ruby -Itest test/lib/repo_root_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"

load File.expand_path("../../bin/lib/repo_root.rb", __dir__)

class RepoRootTest < Minitest::Test
  # A throwaway git repo with one commit, yielded as its toplevel path.
  def with_git_repo
    Dir.mktmpdir do |dir|
      real = File.realpath(dir) # macOS /var → /private/var, matching show-toplevel
      system("git", "-C", real, "init", "-q", out: File::NULL, err: File::NULL)
      system("git", "-C", real, "config", "user.email", "t@t.co")
      system("git", "-C", real, "config", "user.name", "T")
      # Disarm git's BACKGROUND maintenance in the throwaway repo. `git commit`
      # triggers `gc --auto`, which can create and delete
      # `.git/objects/maintenance.lock` asynchronously — and Dir.mktmpdir's block
      # form deletes this tree the moment the block ends. FileUtils then walks a
      # file that git removes underneath it and raises
      #   Errno::ENOENT @ apply2files - <tmp>/.git/objects/maintenance.lock
      # out of `with_git_repo` itself, so the failure is attributed to whichever
      # test happened to be running. It reddened three separate CI runs on
      # 2026-08-19/20 — once inside a Rails shard, once in a consumer lane where
      # it blocked a gem publish — always as "1 errors" among thousands of green
      # runs. Nothing about the code under test is involved.
      system("git", "-C", real, "config", "gc.auto", "0")
      system("git", "-C", real, "config", "maintenance.auto", "false")
      File.write(File.join(real, "a.txt"), "x")
      system("git", "-C", real, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", real, "commit", "-qm", "init", out: File::NULL, err: File::NULL)
      yield real
    end
  end

  # ── [unit] the fixture's OWN contract ──────────────────────────────────────
  #
  # The two `git config` lines above are a FIX, and until this test they were only a
  # comment. Delete them and nothing goes red — the flake simply comes back: `git commit`
  # resumes triggering `gc --auto`, which creates and removes
  # `.git/objects/maintenance.lock` while Dir.mktmpdir's cleanup walks the tree, and
  # Errno::ENOENT surfaces out of whichever test happened to be running. It reddened three
  # CI runs on 2026-08-19/20, one of them a `rails` shard on ACCEPTED — which is the branch
  # Ci::BranchGate reads, so a flake in a test fixture stalled a release.
  #
  # A race that fires once in thousands of runs cannot be caught by re-running the suite,
  # so the guard is on the PRECONDITION instead: does a repo this fixture builds actually
  # have git's background maintenance disarmed? That asserts the EFFECT rather than the
  # spelling — rewrite the config calls however you like and this still passes; remove
  # them and it fails immediately, on every run, locally.
  def test_unit_the_throwaway_repo_disarms_gits_background_maintenance
    with_git_repo do |repo|
      %w[gc.auto maintenance.auto].each do |key|
        value = IO.popen(["git", "-C", repo, "config", "--get", key], err: File::NULL, &:read).strip

        refute_empty value,
                     "with_git_repo leaves #{key} unset, so `git commit` can start background " \
                     "maintenance that races Dir.mktmpdir's cleanup. That is the ENOENT " \
                     "@ apply2files flake — restore the `git config` calls in the fixture."
        refute_includes %w[true 1], value,
                        "with_git_repo sets #{key}=#{value}, which leaves background maintenance " \
                        "ARMED. It must be disabled (0 / false)."
      end
    end
  end

  # ── [unit] git_toplevel ────────────────────────────────────────────────────

  def test_unit_git_toplevel_returns_the_worktree_root_for_a_subdir
    with_git_repo do |repo|
      sub = File.join(repo, "app", "models")
      FileUtils.mkdir_p(sub)
      assert_equal repo, RepoRoot.git_toplevel(sub), "resolves to the toplevel from a nested dir"
    end
  end

  def test_unit_git_toplevel_is_nil_outside_a_git_tree
    Dir.mktmpdir { |dir| assert_nil RepoRoot.git_toplevel(dir) }
  end

  def test_unit_git_toplevel_is_nil_for_a_missing_dir
    assert_nil RepoRoot.git_toplevel("/nonexistent-#{rand(10_000)}")
  end

  # ── [unit] code_root precedence ────────────────────────────────────────────

  def test_unit_explicit_override_always_wins
    with_git_repo do |repo|
      Dir.mktmpdir do |other|
        assert_equal File.expand_path(other), RepoRoot.code_root(other, "/fallback", repo),
                     "an explicit override beats the cwd git toplevel"
      end
    end
  end

  def test_unit_defaults_to_the_cwd_git_toplevel
    with_git_repo do |repo|
      sub = File.join(repo, "app")
      FileUtils.mkdir_p(sub)
      # No override → the CODE root follows the worktree the agent runs from, NOT
      # the fallback (the gate script's own repo). This is the satellite fix.
      assert_equal repo, RepoRoot.code_root(nil, "/hub-fallback", sub),
                   "with no override the gate roots at the cwd worktree, not the hub"
    end
  end

  def test_unit_falls_back_when_cwd_is_not_a_git_tree
    Dir.mktmpdir do |non_git|
      assert_equal "/hub-fallback", RepoRoot.code_root(nil, "/hub-fallback", non_git),
                   "outside a git tree the gate falls back to its own repo"
    end
  end

  def test_unit_blank_override_is_ignored
    with_git_repo do |repo|
      assert_equal repo, RepoRoot.code_root("   ", "/fallback", repo),
                   "a blank/whitespace override is treated as absent"
    end
  end
end
