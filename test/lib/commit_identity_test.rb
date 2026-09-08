# frozen_string_literal: true

# [unit] A commit made from a desk must name the SOUL that claimed it.
#
# THE DEFECT THIS EXISTS TO CATCH (measured 2026-09-06/07). Every commit a desk
# makes is authored by whatever git identity the CHECKOUT happens to carry, and
# that identity has nothing to do with the soul on the task board:
#
#   file:/Users/alex/.gitconfig                        -> Alex McRitchie    (the operator)
#   file:/Users/alex/projects/turf-monster/.git/config -> Steffon (Claude)  (a relic)
#
# turf-monster PR 573 was built by `shannon` and every commit on it reads
# "Steffon (Claude)". Commit 599c5327 on the same desk carries the identical
# mis-stamp, and a second desk shared by two builders produced six commits that
# all read "Steffon (Claude)" — the author field carried ZERO information about
# who wrote what.
#
# WHY NOT `git config user.name` IN THE DESK. A git worktree has NO config file
# of its own: `git rev-parse --git-dir` is .git/worktrees/<name>, but config
# resolves through --git-common-dir, so every desk of a repo SHARES
# .git/config. Writing an identity "into a desk" renames all 30 turf-monster
# desks at once. That is the defect, not the fix — and it is why
# test_two_desks_of_one_repo_do_not_share_an_identity below is the load-bearing
# test in this file rather than a nicety.
#
# WHY NOT extensions.worktreeConfig. It would work, but it re-resolves config
# for EVERY read in the repo, for all 52 live worktrees across the two repos, to
# attribute a commit. And it still buys the wrong GRAIN: a desk holds one
# identity, while the measured reality is two souls on one desk.
#
# SO: the author is set PER COMMIT, from the environment, which outranks every
# config file. That is the only grain that matches what actually happened, and
# it costs no config write at all.
#
# WHERE THE WIRING IS PROVED. Not here, and not by reading bin/ship's source: a
# source scan asserts a string, not a behaviour. test/lib/ship_test.rb runs the
# REAL bin/ship against a repo whose repo-level identity is `tester` and asserts
# the resulting commit's author out of git.
#
# WHAT THIS MUST NEVER DO. `devops.builders` is the AUTHOR SET bin/reviewer-select
# reads to keep a soul off their own PR, and its incompleteness is what makes
# that selector REFUSE — a loud, fail-closed refusal that is the system working.
# This code is READ-ONLY with respect to that set: it reads built_by and writes
# nothing back. A fix that made the field merely LOOK right would remove the
# refusal without restoring the property.

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

require_relative "../../lib/commit_identity"

class CommitIdentityTest < Minitest::Test
  # --- the defect, reproduced -------------------------------------------------

  def test_a_commit_carries_the_claiming_soul_and_not_the_repo_identity
    in_repo(poison: "Steffon (Claude)") do |root|
      touch(root, "a.txt")
      result = CommitIdentity.commit!(root, "work", devops(built_by: "carl"))

      # .ok, not the Struct — a Result object is always truthy, so asserting the
      # return value itself would pass on a failed commit.
      assert result.ok, "the commit must succeed"
      assert_equal "carl", result.soul

      # Read the identity OUT OF GIT — not out of a config file, and not out of
      # the return value. A test that asserts the script wrote a config line is
      # the inert-guard class this project keeps rediscovering.
      assert_equal "Carl", author_name(root)
      assert_equal "carl@mcritchie.studio", author_email(root),
                   "the email local-part is the exact soul slug, so git history " \
                   "joins directly to the board's author set"
    end
  end

  def test_the_soul_outranks_a_poisoned_repo_level_identity
    # turf-monster's ACTUAL measured state. The relic stays on disk; the commit
    # must be correct anyway, because a fix that requires cleaning 52 checkouts
    # first is a fix that does not land.
    in_repo(poison: "Steffon (Claude)") do |root|
      touch(root, "a.txt")
      CommitIdentity.commit!(root, "work", devops(built_by: "shannon"))

      assert_equal "shannon@mcritchie.studio", author_email(root)
      assert_equal "Steffon (Claude)", repo_config(root, "user.name"),
                   "the fix must not TOUCH the repo config — that write is the " \
                   "thing that renames every sibling desk"
    end
  end

  # --- the isolation property a config write would destroy --------------------

  def test_two_desks_of_one_repo_do_not_share_an_identity
    in_repo(poison: "Steffon (Claude)") do |root|
      desk_a = File.join(root, "..", "desk-a")
      desk_b = File.join(root, "..", "desk-b")
      git!(root, "worktree", "add", "-b", "feat/a", desk_a)
      git!(root, "worktree", "add", "-b", "feat/b", desk_b)

      # Prove the premise before relying on it: these two desks really do share
      # one config file, so an identity written "into" either would hit both.
      assert_equal git!(desk_a, "rev-parse", "--git-common-dir"),
                   git!(desk_b, "rev-parse", "--git-common-dir"),
                   "premise: worktrees of one repo share a config"

      touch(desk_a, "a.txt")
      CommitIdentity.commit!(desk_a, "carl's work", devops(built_by: "carl"))
      touch(desk_b, "b.txt")
      CommitIdentity.commit!(desk_b, "shannon's work", devops(built_by: "shannon"))

      assert_equal "carl@mcritchie.studio", author_email(desk_a)
      assert_equal "shannon@mcritchie.studio", author_email(desk_b),
                   "desk B must be unchanged by desk A's identity — the property " \
                   "`git config user.name` in a desk provably cannot hold"
    end
  end

  # --- the handoff grain ------------------------------------------------------

  def test_a_handoff_authors_under_the_current_builder_not_the_first
    # built_by is the CURRENT builder (Task#builder_roll_call: "built_by KEEPS
    # its meaning (the current builder) and builders ACCUMULATES"). The next
    # commit is written by whoever holds the desk now, so the author follows
    # built_by and never the head of the accumulated set.
    in_repo do |root|
      touch(root, "a.txt")
      CommitIdentity.commit!(root, "work", devops(built_by: "shannon", builders: %w[carl shannon]))

      assert_equal "shannon@mcritchie.studio", author_email(root)
    end
  end

  # --- fail honest, never fabricate ------------------------------------------

  def test_an_unattributed_task_is_not_given_a_fabricated_author
    in_repo(poison: "Steffon (Claude)") do |root|
      touch(root, "a.txt")
      CommitIdentity.commit!(root, "work", devops(built_by: nil))

      assert_equal "Steffon (Claude)", author_name(root),
                   "with no soul on record the commit stays on the machine " \
                   "identity — inventing one would launder an unattributed " \
                   "commit into a confident wrong answer"
    end
  end

  def test_a_value_that_is_not_a_soul_slug_is_refused
    # The exact shapes seen in the wild: a raw session UUID adopted by the
    # heartbeat, a capitalised name, and an underscored slug.
    ["8b12f485-ac04-4134-bbb6-ba9ac7e3c41d", "Steffon", "turf_monster", "", "  "].each do |bad|
      assert_empty CommitIdentity.env_for(devops(built_by: bad)),
                   "#{bad.inspect} is not a soul slug and must yield no identity"
    end
  end

  def test_a_hyphenated_soul_slug_is_accepted
    env = CommitIdentity.env_for(devops(built_by: "turf-monster"))

    assert_equal "Turf Monster", env["GIT_AUTHOR_NAME"]
    assert_equal "turf-monster@mcritchie.studio", env["GIT_AUTHOR_EMAIL"]
  end

  private

  def devops(built_by: :unset, builders: nil)
    d = {}
    d["built_by"] = built_by unless built_by == :unset
    d["builders"] = builders if builders
    d
  end

  # A real repo with a real (poisoned) repo-level identity, isolated from the
  # machine's global config so the test measures only what it set up.
  def in_repo(poison: nil)
    Dir.mktmpdir("commit-identity") do |tmp|
      home = File.join(tmp, "home")
      FileUtils.mkdir_p(home)
      root = File.join(tmp, "repo")
      FileUtils.mkdir_p(root)

      with_env("HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"),
               "GIT_CONFIG_GLOBAL" => File.join(home, ".gitconfig"),
               "GIT_CONFIG_SYSTEM" => File.join(home, ".gitconfig.system"),
               "GIT_AUTHOR_NAME" => nil, "GIT_AUTHOR_EMAIL" => nil,
               "GIT_COMMITTER_NAME" => nil, "GIT_COMMITTER_EMAIL" => nil) do
        git!(root, "init", "-q", "-b", "main")
        # The machine identity every desk inherits when nothing else is set.
        git!(root, "config", "user.name", poison || "Alex McRitchie")
        git!(root, "config", "user.email", "amcritchie@gmail.com")
        yield root
      end
    end
  end

  def with_env(pairs)
    old = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def touch(root, name)
    File.write(File.join(root, name), "#{name}\n#{rand}")
  end

  def git!(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def author_name(root) = git!(root, "log", "-1", "--format=%an")
  def author_email(root) = git!(root, "log", "-1", "--format=%ae")
  def repo_config(root, key) = git!(root, "config", "--local", "--get", key)
end
