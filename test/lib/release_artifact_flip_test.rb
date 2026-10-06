# frozen_string_literal: true

# [integration] Does the artifact commit FLIP the shared primary checkout? Never,
# since harden-artifact-commit-onto-accepted; this file first pinned the no-work case.
#
# THE DEFECT. `Release::ArtifactCommit.safe_to_commit?` was
# `other_dirty_paths(...).empty?`, which a CLEAN tree satisfies vacuously — while
# the comment directly above it always claimed the stronger conjunction, "the
# expected doc(s) are the ONLY things dirty". So `commit_artifact_to_accepted` ran
# its `checkout <branch>` → `git commit` (silently a no-op with nothing staged) →
# `ensure { checkout main }` dance on every run with nothing to commit. Measured
# on the hub primary 2026-09-10: 191 flip pairs and ZERO `commit:` entries across
# 400 reflog records, median dwell on the target branch 1s. The target is `accepted`.
#
# WHY A FLIP COSTS ANYTHING. The primary is SHARED. `git checkout` unlinks each
# file and writes it afresh, so every tracked file is briefly absent — measured
# ~0.4-0.7s per checkout, about 68% of the operation — and desk-side commands and
# git's own credential helper read that tree while it happens.
#
# WHY THIS IS A FILE OF ITS OWN. The release CLI files are frozen APPEND hotspots,
# and `TestHealthRatchetTest` refuses a PR that grows one. Named for its concern
# instead.
#
# NOTHING HERE TOUCHES a real repo: the fixture is a bare origin plus a clone in
# a tmpdir, and the child runs under OutboundSeams so a forgotten stub resolves
# `gh`/`heroku`/`op` to a sealed no-op rather than the real binary.

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseArtifactFlipTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # How many times HEAD has MOVED, read from the reflog.
  #
  # WHY NOT `rev-parse --abbrev-ref HEAD`. The dance restores `main` in an
  # `ensure`, so the end state is `main` whether it flipped or not. An end-state
  # assertion cannot tell "never left" from "left and came back", and that is the
  # entire distinction under test. The reflog remembers.
  def head_moves(repo)
    out, = Open3.capture2("git", "-C", repo, "reflog", "--format=%gs")
    out.lines.count { |line| line.start_with?("checkout: moving") }
  end

  # THE CASE THIS EXISTS FOR: the generated doc regenerated to the same bytes, so
  # the tree is clean. Not merely ABSENT — the guard must key off "nothing to
  # commit", not off the file being missing.
  def test_a_clean_tree_is_not_flipped
    with_fixture do |repo, dir|
      doc = File.join(repo, "retro.md")
      File.write(doc, "retro fixture")
      git(repo, "add", "retro.md")
      git(repo, "commit", "-qm", "seed the artifact")
      File.write(doc, "retro fixture") # regenerated, byte-identical

      status, = Open3.capture2("git", "-C", repo, "status", "--porcelain")
      assert_empty status.strip, "setup: the tree must be CLEAN for this to be the case under test"
      before = head_moves(repo)

      out = run_dance(repo, dir, doc)

      assert_equal before, head_moves(repo),
                   "the dance flipped HEAD with nothing to commit — that is the 191-flips-a-day defect, and " \
                   "each flip blinds every command reading this shared checkout for ~0.4-0.7s"
      assert_includes out, "nothing to commit",
                       "the skip must SAY so: every other arm of this method reports, and a silent one leaves " \
                       "an operator unable to tell the dance from a crash"
      refute_includes out, "other changes present",
                      "a clean tree has no other changes — reporting it as one sends the operator hunting for dirt"
      assert_includes out, "DONE", "the skip stays NON-FATAL: archive/retro ride on"
    end
  end

  # THE OTHER HALF, and without it the test above is satisfied by a method that
  # does nothing at all. An UNTRACKED artifact is a FIRST RUN: it must still commit
  # and push, or the doc is stranded forever. Since harden-artifact-commit-onto-accepted
  # it does so WITHOUT a flip: the commit is built from origin/accepted in a throwaway
  # index and pushed by SHA, so HEAD never moves even when there is work to do.
  def test_a_dirty_artifact_commits_without_flipping
    with_fixture do |repo, dir|
      doc = File.join(repo, "retro.md")
      File.write(doc, "retro fixture") # untracked — the first-run case
      before = head_moves(repo)

      out = run_dance(repo, dir, doc)

      assert_equal before, head_moves(repo), "the commit is built from origin/accepted; HEAD never moves"
      assert_includes out, "committed retro.md to accepted"
      count, = Open3.capture2("git", "-C", repo, "rev-list", "--count", "origin/accepted")
      assert_equal "2", count.strip, "the artifact commit is pushed onto origin/accepted"
      refute_path_exists doc, "the committed doc leaves main's working tree, as the old flip back to main left it"
    end
  end

  # An unrelated dirty path must still REFUSE, with the original wording — the
  # pre-existing behaviour this change must not disturb.
  def test_unrelated_dirt_still_refuses_without_committing
    with_fixture do |repo, dir|
      doc = File.join(repo, "retro.md")
      File.write(doc, "retro fixture")
      File.write(File.join(repo, "README"), "someone else's work in progress")

      out = run_dance(repo, dir, doc)

      assert_includes out, "other changes present", "unrelated dirt must still refuse, and say why"
      refute_includes out, "committed retro.md", "…never sweeping up unrelated work"
      count, = Open3.capture2("git", "-C", repo, "rev-list", "--count", "origin/accepted")
      assert_equal "1", count.strip, "nothing lands on accepted when the tree carries unrelated dirt"
    end
  end

  private

  # A bare origin plus a clone carrying `main` and `accepted`, and nothing else —
  # this dance needs no Rails app, no database.yml and no bin/rails.
  def with_fixture
    Dir.mktmpdir("release-artifact-flip") do |dir|
      origin = File.join(dir, "origin.git")
      repo = File.join(dir, "repo")
      system("git", "init", "--bare", "-q", origin, out: File::NULL, err: File::NULL) ||
        flunk("git init --bare failed")
      system("git", "clone", "-q", origin, repo, out: File::NULL, err: File::NULL) || flunk("git clone failed")

      git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
      # Identity IN the repo config: the code under test runs a bare `git commit`,
      # which has no identity on a CI runner. gpgsign off so a signing global
      # cannot break it.
      git(repo, "config", "user.email", "t@t.t")
      git(repo, "config", "user.name", "t")
      git(repo, "config", "commit.gpgsign", "false")
      File.write(File.join(repo, "README"), "flip fixture")
      git(repo, "add", "README")
      git(repo, "commit", "-qm", "seed")
      git(repo, "push", "-q", "origin", "main")
      git(repo, "branch", "accepted")
      git(repo, "push", "-q", "origin", "accepted")

      yield repo, dir
    end
  end

  # Load bin/release.rb in a child and call the dance directly, exactly as the
  # release CLI tests drive it.
  def run_dance(repo, dir, doc)
    setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
            %(def repo_path(_repo) = #{repo.inspect})
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; ) +
             %{commit_artifact_to_accepted("sibling", #{doc.inspect}, "retro: fixture"); puts("DONE")}
    env = OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => dir)
    out, err, status = Open3.capture3(env, "ruby", "-e", script)
    assert_predicate status, :success?, "the dance must not crash the child: #{err}"
    out
  end

  def git(repo, *args)
    system("git", "-C", repo, *args, out: File::NULL, err: File::NULL) || flunk("git #{args.join(' ')} failed")
  end
end
