# frozen_string_literal: true

# [unit] ReviewTreeGuard — the two "is the tree this review grades the tree that will
# merge?" questions. Run directly:
#   ruby -Itest test/lib/review_tree_guard_test.rb
#
# Driven against REAL temp git repositories, never a stubbed shell. The whole subject
# here is what git refs actually say after a push nobody fetched, and a mock of `git`
# would be a mock of the exact thing under test — it would certify the guard green
# while proving nothing about the seam. Building a two-repo clone is a few lines and
# reproduces the real condition: a desk whose remote-tracking ref is behind the remote.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/review_tree_guard"

class ReviewTreeGuardTest < Minitest::Test
  # A REMOTE plus a CLONE of it, which is the shape every seam here lives in: the
  # clone is the builder's desk, the remote is where the reviewer's zap lands. The
  # clone does NOT fetch unless a test asks it to — that is the condition, not an
  # oversight, and bin/dor-check never fetches either.
  def with_desk
    Dir.mktmpdir do |dir|
      remote = File.join(dir, "remote")
      desk = File.join(dir, "desk")
      git!(nil, "init -q --bare #{remote}")

      seed = File.join(dir, "seed")
      FileUtils.mkdir_p(seed)
      git!(seed, "init -q")
      configure_identity(seed)
      File.write(File.join(seed, "README.md"), "base\n")
      git!(seed, "add -A") && git!(seed, "commit -q -m base")
      git!(seed, "branch -M accepted")
      git!(seed, "remote add origin #{remote}")
      git!(seed, "push -q origin accepted")
      git!(seed, "checkout -q -b feat/x")
      File.write(File.join(seed, "feature.rb"), "1\n")
      git!(seed, "add -A") && git!(seed, "commit -q -m feature")
      git!(seed, "push -q origin feat/x")

      git!(nil, "clone -q #{remote} #{desk}")
      configure_identity(desk)
      git!(desk, "checkout -q feat/x")

      yield(desk, seed, remote)
    end
  end

  # NOT `setup` — that is Minitest's per-test hook, and shadowing it with a
  # one-argument method makes every test in the file error before it runs.
  def configure_identity(dir)
    git!(dir, "config user.email tester@example.com")
    git!(dir, "config user.name tester")
  end

  def git!(dir, args)
    cmd = dir ? "git -C #{dir} #{args}" : "git #{args}"
    assert system("#{cmd} >/dev/null 2>&1"), "failed: #{cmd}"
  end

  def sha(dir, ref)
    IO.popen(["git", "-C", dir, "rev-parse", ref], &:read).strip
  end

  # A reviewer zap, pushed from SOMEWHERE THAT IS NOT THE DESK — the case that leaves
  # the desk's remote-tracking ref pre-zap, and the case the cert fingerprint cannot
  # catch because it hashes that very ref.
  def zap!(seed, message: "zap")
    File.write(File.join(seed, "feature.rb"), "2\n")
    git!(seed, "add -A") && git!(seed, "commit -q -m #{message}")
    git!(seed, "push -q origin feat/x")
    sha(seed, "HEAD")
  end

  # ==== SEAM 1 — the graded tree vs the PR head ==================================

  def test_head_matches_before_anybody_pushes
    with_desk do |desk|
      head = sha(desk, "origin/feat/x")
      result = ReviewTreeGuard.head_assessment(root: desk, branch: "feat/x", pr_head: head)

      assert_equal :match, result[:state]
      assert_equal head, result[:local_sha]
      assert_equal "origin/feat/x", result[:ref],
                   "must resolve through the SAME ref review_fingerprint hashes, or it is describing a " \
                   "different commit than the verdict actually graded"
    end
  end

  # THE SEAM, reproduced end to end: the reviewer pushes a zap from elsewhere, the desk
  # never fetches, and the desk's ref still points at the pre-zap commit. This is the
  # state in which the cert reads FRESH and the gate would otherwise pass a verdict
  # about a tree that is not the one merging.
  def test_head_mismatch_after_a_zap_the_desk_never_fetched
    with_desk do |desk, seed|
      pre_zap = sha(desk, "origin/feat/x")
      zapped = zap!(seed)

      refute_equal pre_zap, zapped, "the fixture failed to move the branch; the rest of this proves nothing"
      assert_equal pre_zap, sha(desk, "origin/feat/x"),
                   "the desk must still be at the PRE-ZAP commit — if the fixture fetched, this test is " \
                   "no longer about the seam it is named for"

      result = ReviewTreeGuard.head_assessment(root: desk, branch: "feat/x", pr_head: zapped)

      assert_equal :mismatch, result[:state],
                   "a desk one commit behind the PR head was reported as grading the merge tree"
      assert_equal pre_zap, result[:local_sha]
      assert_equal zapped, result[:pr_head]
    end
  end

  # …and fetching is what clears it, which is why the false refusal is cheap: the
  # remedy for the harmless case IS the remedy for the real one.
  def test_head_matches_again_once_the_desk_fetches
    with_desk do |desk, seed|
      zapped = zap!(seed)
      git!(desk, "fetch -q origin feat/x")

      assert_equal :match, ReviewTreeGuard.head_assessment(root: desk, branch: "feat/x", pr_head: zapped)[:state]
    end
  end

  # Neither half of the comparison may be assumed. Both absences are :unobservable —
  # NOT a pass — and each names which half was missing, because the remedies differ.
  def test_a_missing_pr_head_is_unobservable_not_a_match
    with_desk do |desk|
      result = ReviewTreeGuard.head_assessment(root: desk, branch: "feat/x", pr_head: "")

      assert_equal :unobservable, result[:state]
      assert_equal :no_pr_head, result[:reason]
    end
  end

  def test_a_missing_local_ref_is_unobservable_not_a_match
    with_desk do |desk|
      result = ReviewTreeGuard.head_assessment(root: desk, branch: "feat/nope", pr_head: sha(desk, "HEAD"))

      assert_equal :unobservable, result[:state]
      assert_equal :no_local_ref, result[:reason]
    end
  end

  # gh and git hand back SHAs at different widths.
  def test_an_abbreviated_pr_head_still_matches
    with_desk do |desk|
      full = sha(desk, "origin/feat/x")

      assert_equal :match,
                   ReviewTreeGuard.head_assessment(root: desk, branch: "feat/x", pr_head: full[0, 7])[:state]
    end
  end

  # THE ABBREVIATION FLOOR, which is a safety rule rather than a nicety: comparing on a
  # 1-char prefix makes unrelated commits "match", and on this guard a false match is a
  # false PASS — the one direction it is built never to produce.
  def test_a_uselessly_short_head_is_not_treated_as_a_match
    full = "abcdef1234567890abcdef1234567890abcdef12"

    refute ReviewTreeGuard.same_commit?(full, full[0, 1])
    refute ReviewTreeGuard.same_commit?(full, "")
    assert ReviewTreeGuard.same_commit?(full, full[0, 4])
  end

  # ==== SEAM 2 — the base moving out from under the branch =======================

  def test_no_movement_seen_while_the_base_is_an_ancestor
    with_desk do |desk|
      result = ReviewTreeGuard.base_assessment(root: desk, branch: "feat/x", base: "accepted")

      assert_equal :no_movement_seen, result[:state]
    end
  end

  # #517 merging into `accepted` while #519's checks were still running, reproduced.
  def test_base_movement_is_detected_when_the_base_gains_a_commit
    with_desk do |desk, seed|
      git!(seed, "checkout -q accepted")
      File.write(File.join(seed, "e2e_lane.yml"), "executed: 205\n")
      git!(seed, "add -A") && git!(seed, "commit -q -m 'other PR merges'")
      git!(seed, "push -q origin accepted")
      git!(desk, "fetch -q origin accepted")

      result = ReviewTreeGuard.base_assessment(root: desk, branch: "feat/x", base: "accepted")

      assert_equal :moved, result[:state],
                   "the base gained a commit the branch has not taken, so every check that ran against the " \
                   "old merge describes a tree the merge will not produce"
      assert_equal 1, result[:behind_by]
    end
  end

  def test_base_movement_reports_how_far_behind
    with_desk do |desk, seed|
      git!(seed, "checkout -q accepted")
      2.times do |i|
        File.write(File.join(seed, "n#{i}.md"), "x\n")
        git!(seed, "add -A") && git!(seed, "commit -q -m n#{i}")
      end
      git!(seed, "push -q origin accepted")
      git!(desk, "fetch -q origin accepted")

      assert_equal 2, ReviewTreeGuard.base_assessment(root: desk, branch: "feat/x", base: "accepted")[:behind_by]
    end
  end

  # THE ASYMMETRY, pinned as a test rather than left as a claim in the header. A desk
  # that has NOT fetched the moved base reports :no_movement_seen — which is exactly
  # why that state is never rendered as "the base is current". The guard understates;
  # it must never overstate.
  def test_an_unfetched_desk_understates_movement_rather_than_inventing_freshness
    with_desk do |desk, seed|
      git!(seed, "checkout -q accepted")
      File.write(File.join(seed, "moved.md"), "x\n")
      git!(seed, "add -A") && git!(seed, "commit -q -m moved")
      git!(seed, "push -q origin accepted")
      # deliberately NO fetch in the desk

      result = ReviewTreeGuard.base_assessment(root: desk, branch: "feat/x", base: "accepted")

      assert_equal :no_movement_seen, result[:state],
                   "with a stale ref the honest answer is 'the refs I can see show none' — if this ever " \
                   "returned :moved the guard would be reading a ref it does not have"
      refute_equal :current, result[:state],
                   "there is deliberately NO :current state: this gate never fetches, so it can never " \
                   "certify freshness — only report movement it can see"
    end
  end

  def test_a_missing_base_ref_is_unobservable
    with_desk do |desk|
      result = ReviewTreeGuard.base_assessment(root: desk, branch: "feat/x", base: "no-such-base")

      assert_equal :unobservable, result[:state]
      assert_equal :no_base_ref, result[:reason]
    end
  end

  def test_a_blank_base_is_unobservable
    with_desk do |desk|
      assert_equal :unobservable, ReviewTreeGuard.base_assessment(root: desk, branch: "feat/x", base: "")[:state]
    end
  end
end
