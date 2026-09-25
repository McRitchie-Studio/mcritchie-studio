# frozen_string_literal: true

# Unit tests for bin/lib/tree_fingerprint.rb — the content-addressed tree hash
# the `[control@<fp>]` stamp is bound to and graded against.
#
#   ruby -Itest test/lib/tree_fingerprint_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/tree_fingerprint"

class TreeFingerprintTest < Minitest::Test
  def with_repo
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q", "-b", "feat/demo")
      git(dir, "config", "user.email", "t@t.co")
      git(dir, "config", "user.name", "T")
      File.write(File.join(dir, "a.txt"), "one\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "init")
      yield dir
    end
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed")
  end

  def test_the_working_tree_hash_equals_the_committed_tree_hash_for_the_same_content
    with_repo do |dir|
      committed = `git -C #{dir} rev-parse HEAD^{tree}`.strip

      assert_equal committed, TreeFingerprint.working_tree(dir),
                   "a clean tree must hash to its commit's tree — that is what lets a stamp taken " \
                   "before the commit be graded after it"
    end
  end

  def test_an_untracked_file_changes_the_hash_and_committing_it_does_not
    with_repo do |dir|
      before = TreeFingerprint.working_tree(dir)
      File.write(File.join(dir, "b.txt"), "two\n")
      dirty = TreeFingerprint.working_tree(dir)

      refute_equal before, dirty, "an added file is part of the tree"

      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "add b")

      assert_equal dirty, TreeFingerprint.working_tree(dir),
                   "committing the same content must not move the hash (git stash create dropped " \
                   "untracked files and broke exactly this)"
    end
  end

  def test_the_working_tree_hash_leaves_the_real_index_alone
    with_repo do |dir|
      File.write(File.join(dir, "b.txt"), "two\n")
      TreeFingerprint.working_tree(dir)

      staged = `git -C #{dir} diff --cached --name-only`.strip
      assert_equal "", staged, "the fingerprint stages into a THROWAWAY index, never the real one"
    end
  end

  def test_of_ref_resolves_a_committed_tree_and_nil_for_a_bad_ref
    with_repo do |dir|
      assert_equal TreeFingerprint.working_tree(dir), TreeFingerprint.of_ref(dir, "feat/demo")
      assert_nil TreeFingerprint.of_ref(dir, "no-such-branch")
      assert_nil TreeFingerprint.of_ref(dir, "")
      assert_nil TreeFingerprint.of_ref(dir, nil)
    end
  end

  def test_of_first_ref_returns_the_hash_with_its_provenance
    with_repo do |dir|
      found = TreeFingerprint.of_first_ref(dir, "origin/feat/demo", "feat/demo")

      assert_equal TreeFingerprint.working_tree(dir), found[:fingerprint]
      assert_equal "feat/demo^{tree}", found[:ref], "the ref that PRODUCED the hash rides with it"
      assert_equal dir, found[:root]
      assert_nil TreeFingerprint.of_first_ref(dir, "nope", "also-nope")
    end
  end

  def test_a_directory_that_is_not_a_repo_fingerprints_to_nil
    Dir.mktmpdir do |dir|
      assert_nil TreeFingerprint.working_tree(dir)
    end
  end
end
