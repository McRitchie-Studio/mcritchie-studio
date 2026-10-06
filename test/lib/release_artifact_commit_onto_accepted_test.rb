# frozen_string_literal: true

# [integration] Does the archive/retro artifact commit land on origin/accepted when
# the hub primary's LOCAL `accepted` is stale, and when a review merge moves
# origin/accepted between the fetch and the push?
#
# THE DEFECT (harden-artifact-commit-onto-accepted, filed from the PR 1916 review).
# commit_artifact_to_accepted used to `git checkout accepted` in the primary,
# `merge --ff-only origin/accepted`, commit, push, and `ensure` back to `main`. On the
# hub primary that day, local `accepted` sat 3,284 commits behind origin and its
# delete-later.md differed from main's, so two things went wrong:
#
#   1. The checkout itself refuses ("your local changes would be overwritten") when
#      the doc being committed differs between main and the stale local branch. The
#      doc never reaches accepted.
#   2. A push refused because a review merge landed meanwhile left the commit on the
#      LOCAL `accepted`, and the ensure checked out main, so the doc left the working
#      tree. The step still said "left uncommitted", and every later run failed its
#      `merge --ff-only` until someone reset the branch.
#
# THE FIX builds the commit from origin/accepted directly, in a throwaway index, and
# pushes it by SHA. No local branch is read or written, and HEAD never moves. A
# refused push re-fetches and rebuilds once on the new tip; a second refusal leaves
# the doc exactly where it was, in the primary's working tree, and says so.
#
# A FILE OF ITS OWN: the release CLI files are frozen append hotspots under
# config/test_health.yml. The fixture is a bare origin plus a clone in a tmpdir, and
# the child runs under OutboundSeams.

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseArtifactCommitOntoAcceptedTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  LEDGER = "docs/delete-later.md"

  # The 3,284-behind shape: local `accepted` sits at the seed, where the ledger reads
  # differently from main's, and the archive beat has rewritten the ledger on main.
  def test_stale_local_accepted_with_a_differing_ledger_still_commits
    with_fixture do |repo, dir|
      stale = rev(repo, "refs/heads/accepted")
      write(repo, LEDGER, "ledger after archive\n")

      out = run_commit(repo, dir)

      assert_includes out, "committed #{LEDGER} to accepted", "a stale local accepted must not block the commit\n\n#{out}"
      assert_equal "ledger after archive\n", show(repo, "origin/accepted", LEDGER), "the new ledger is on origin/accepted"
      assert_equal rev(repo, "origin/main"), rev(repo, "origin/accepted^"), "built on origin/accepted's tip"
      assert_equal stale, rev(repo, "refs/heads/accepted"), "the stale local branch is neither read nor written"
      assert_equal 0, head_moves(repo), "HEAD never leaves main"
      assert_empty porcelain(repo), "the committed doc leaves the working tree, as the checkout flip used to leave it"
    end
  end

  # A review merge lands on origin/accepted between the fetch and the first push.
  # The pre-push hook plays the reviewer once; the retry rebuilds on the new tip.
  # The local branch is CURRENT here, so the old checkout dance got as far as the push
  # and stranded its commit on local `accepted`; this pins the strand, not the staleness.
  def test_a_concurrent_review_merge_is_absorbed_by_one_retry
    with_fixture(stale: false) do |repo, dir|
      local = rev(repo, "refs/heads/accepted")
      rival = install_rival_hook(repo, dir, always: false)
      write(repo, LEDGER, "ledger after archive\n")

      out = run_commit(repo, dir)

      assert_includes out, "committed #{LEDGER} to accepted", "one refused push is retried onto the new tip\n\n#{out}"
      assert_equal rev(rival, "HEAD"), rev(repo, "origin/accepted^"), "the artifact sits on the review merge"
      assert_equal "reviewed work\n", show(repo, "origin/accepted", "review.rb"), "the review merge survives"
      assert_equal "ledger after archive\n", show(repo, "origin/accepted", LEDGER)
      assert_equal local, rev(repo, "refs/heads/accepted"), "no commit is stranded on the local branch"
      assert_empty porcelain(repo)
    end
  end

  # accepted keeps moving: both pushes are refused. The doc must stay where an
  # operator can find it, in the working tree, and the step must say exactly that.
  def test_a_second_refusal_leaves_the_doc_in_the_working_tree_and_says_so
    with_fixture(stale: false) do |repo, dir|
      local = rev(repo, "refs/heads/accepted")
      install_rival_hook(repo, dir, always: true)
      write(repo, LEDGER, "ledger after archive\n")

      out = run_commit(repo, dir)

      assert_includes out, "left #{LEDGER} uncommitted in the sibling primary's working tree", out
      assert_includes out, "no local branch was written", "the message names where the doc is NOT, too\n\n#{out}"
      refute_includes out, "committed #{LEDGER}"
      assert_equal "ledger after archive\n", File.read(File.join(repo, LEDGER)), "the doc is still on disk"
      assert_equal local, rev(repo, "refs/heads/accepted"), "no commit is stranded on the local branch"
      refute_equal "ledger after archive\n", show(repo, "origin/accepted", LEDGER), "nothing landed on accepted"
      assert_equal 0, head_moves(repo)
    end
  end

  # Zero artifacts: the ledger regenerated to the same bytes. No fetch, no commit,
  # no push, no flip, and the step says so.
  def test_zero_artifacts_touch_nothing
    with_fixture do |repo, dir|
      before = %w[refs/heads/accepted origin/accepted].map { |ref| rev(repo, ref) }

      out = run_commit(repo, dir)

      assert_includes out, "unchanged — nothing to commit", out
      assert_equal before, %w[refs/heads/accepted origin/accepted].map { |ref| rev(repo, ref) }
      assert_equal 0, head_moves(repo)
      assert_empty porcelain(repo)
    end
  end

  # [control] the git readers this file asserts through RAISE on a ref that does not
  # resolve, rather than handing back rev-parse's echo of the ref name.
  def test_control_rev_raises_on_an_unresolvable_ref
    with_fixture do |repo, _dir|
      error = assert_raises(RuntimeError) { rev(repo, "refs/heads/no-such-branch") }
      assert_includes error.message, "no-such-branch"
      assert_includes error.message, repo
    end
  end

  private

  # origin/main == origin/accepted carry the ledger at "ledger on main". A stale local
  # `accepted` is left at the seed, where the ledger reads "ancient ledger".
  def with_fixture(stale: true)
    Dir.mktmpdir("release-artifact-onto-accepted") do |dir|
      origin = File.join(dir, "origin.git")
      repo = File.join(dir, "repo")
      system("git", "init", "--bare", "-q", origin, out: File::NULL, err: File::NULL) || flunk("git init --bare failed")
      clone(origin, repo)
      git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
      write(repo, LEDGER, "ancient ledger\n")
      git(repo, "add", "--all")
      git(repo, "commit", "-qm", "seed")
      git(repo, "branch", "accepted")
      write(repo, LEDGER, "ledger on main\n")
      git(repo, "commit", "-qam", "roll the ledger")
      git(repo, "push", "-q", "origin", "main", "main:accepted")
      git(repo, "branch", "-f", "accepted", "main") unless stale
      yield repo, dir
    end
  end

  def clone(origin, repo)
    system("git", "clone", "-q", origin, repo, out: File::NULL, err: File::NULL) || flunk("git clone failed")
    git(repo, "config", "user.email", "t@t.t")
    git(repo, "config", "user.name", "t")
    git(repo, "config", "commit.gpgsign", "false")
  end

  # A pre-push hook that lands a "review merge" on origin/accepted from a second
  # clone, just before the code under test pushes: once, or before every push.
  def install_rival_hook(repo, dir, always:)
    rival = File.join(dir, "rival")
    clone(File.join(dir, "origin.git"), rival)
    git(rival, "checkout", "-q", "-B", "accepted", "origin/accepted")
    marker = File.join(dir, "rival-pushed")
    hook = File.join(repo, ".git", "hooks", "pre-push")
    File.write(hook, <<~SH)
      #!/bin/sh
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
      #{always ? '' : "[ -f '#{marker}' ] && exit 0"}
      touch '#{marker}'
      cd '#{rival}' || exit 1
      printf 'reviewed work\\n' > review.rb
      echo "$$" >> review.log
      git add review.rb review.log && git commit -qm 'review merge' && git push -q origin HEAD:accepted
      exit 0
    SH
    File.chmod(0o755, hook)
    rival
  end

  def run_commit(repo, dir)
    setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) + %(def repo_path(_repo) = #{repo.inspect})
    path = File.join(repo, LEDGER)
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; ) +
             %{commit_artifact_to_accepted("sibling", #{path.inspect}, "ledger: fixture"); puts("DONE")}
    out, err, status = Open3.capture3(OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => dir), "ruby", "-e", script)
    assert_predicate status, :success?, "the artifact commit must not crash: #{err}"
    assert_includes out, "DONE", "the artifact commit stays NON-FATAL"
    out
  end

  # Checkouts since the fixture was built (the fixture itself makes none after clone).
  def head_moves(repo)
    out, = Open3.capture2("git", "-C", repo, "reflog", "--format=%gs", "HEAD")
    out.lines.count { |line| line.start_with?("checkout: moving") }
  end

  def write(repo, rel, text)
    FileUtils.mkdir_p(File.join(repo, File.dirname(rel)))
    File.write(File.join(repo, rel), text)
  end

  # Every read RAISES on a non-zero exit, naming the command, the directory and the
  # code: `git rev-parse` prints the ref name itself for a missing ref and exits 128,
  # so a dropped status would hand an assertion a plausible wrong string.
  def rev(repo, ref)
    out, err, status = Open3.capture3("git", "-C", repo, "rev-parse", "--verify", ref)
    raise "git rev-parse #{ref.inspect} failed in #{repo} (exit #{status.exitstatus}): #{err.strip}" unless status.success?

    out.strip
  end

  def show(repo, ref, rel) = capture(repo, "show", "#{ref}:#{rel}")
  def porcelain(repo) = capture(repo, "status", "--porcelain").strip

  def capture(repo, *args)
    out, err, status = Open3.capture3("git", "-C", repo, *args)
    raise "git #{args.join(' ')} failed in #{repo} (exit #{status.exitstatus}): #{err.strip}" unless status.success?

    out
  end

  def git(repo, *args)
    system("git", "-C", repo, *args, out: File::NULL, err: File::NULL) || flunk("git #{args.join(' ')} failed")
  end
end
