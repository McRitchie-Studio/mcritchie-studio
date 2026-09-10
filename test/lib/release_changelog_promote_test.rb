# frozen_string_literal: true

# [integration] bin/release prepare's promote step REFUSES a merge that would file
# a new CHANGELOG entry under a version heading that already shipped — against
# real git (/tasks/rolled-changelog-merge-misfiles).
#
# THE DEFECT. The roll (Release::Changelog.roll) lands on `release` only, in the
# `Release <version>` commit. `accepted` keeps its un-rolled `## Unreleased` until
# something merges that commit back, and builders keep writing into it. So the
# next promote merges an un-rolled bucket into a rolled file, and git does one of
# two things (measured on studio-engine's real file with the real roll):
#
#   * a bullet added INSIDE an existing `###` subsection merges CLEAN and lands
#     under the heading the roll just wrote — a version that shipped without it.
#     Silent, and permanent: the next roll moves only what is under Unreleased.
#   * a new subsection at the TOP of the bucket CONFLICTS, and the batch PR dies
#     in `gh pr merge` with GitHub's generic "not mergeable".
#
# REAL, not mocked: a bare origin, a clone, a `release` rolled and tagged, an
# `accepted` that did not absorb it, and bin/release's own guard reading them. The
# promote itself (`gh pr merge`) is network and is NOT driven; the guard runs
# before it, which is the point — a refusal there means nothing was promoted.
#
#   ruby -Itest test/lib/release_changelog_promote_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../app/models/release/changelog"

class ReleaseChangelogPromoteTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  SOURCE = File.read(BIN).freeze
  PUBLISHED = "0.40.0"
  BASE = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- entry one\n\n" \
         "## 0.39.0 — 2026-08-11\n\n- older entry\n"

  # Same discipline as ReleaseGemAllocationTest: the child must never reach the
  # operator's real lock store, and must run outside the suite's bundler context.
  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("changelog-promote-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  BUNDLER_ENV_KEYS = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP].freeze

  def child_env(root)
    scrubbed = BUNDLER_ENV_KEYS.to_h { |key| [key, nil] }
    SessionEnv.neutralized(scrubbed.merge("PROJECTS_DIR" => root, "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir))
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    assert status.success?, "git #{args.join(' ')} failed in #{dir}:\n#{out}"
    out
  end

  def commit(repo, text, message)
    File.write(File.join(repo, "CHANGELOG.md"), text)
    git(repo, "add", "CHANGELOG.md")
    git(repo, "commit", "--quiet", "-m", message)
  end

  # The state a sweep that allocated 0.40.0 leaves behind: `release` and
  # `accepted` forked from one base, `release` rolled into 0.40.0 and tagged.
  def build(root)
    origin = File.join(root, "origin.git")
    repo = File.join(root, "studio-engine")
    Open3.capture2e("git", "init", "--quiet", "--bare", origin)
    Open3.capture2e("git", "init", "--quiet", "-b", "release", repo)
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "commit.gpgsign", "false")
    git(repo, "config", "tag.gpgsign", "false")
    commit(repo, BASE, "base")
    git(repo, "remote", "add", "origin", origin)
    git(repo, "branch", "accepted")
    commit(repo, Release::Changelog.roll(BASE, version: PUBLISHED, date: "2026-09-11"), "Release #{PUBLISHED}")
    git(repo, "tag", "-a", "v#{PUBLISHED}", "-m", "Release studio-engine v#{PUBLISHED}")
    git(repo, "push", "--quiet", "origin", "release", "accepted", "v#{PUBLISHED}")
    repo
  end

  def on_accepted(repo)
    git(repo, "checkout", "--quiet", "accepted")
    yield File.read(File.join(repo, "CHANGELOG.md"))
    git(repo, "push", "--quiet", "origin", "accepted")
    git(repo, "checkout", "--quiet", "release")
  end

  def guard(root)
    script = "require \"json\"\nload #{BIN.inspect}\nputs(\"CHECKED \" + refuse_misfiled_changelog!([\"studio-engine\"]).to_json)"
    out, status = Open3.capture2e(child_env(root), RbConfig.ruby, "-W0", "-e", script)
    [out, status.exitstatus]
  end

  def remote_release(repo) = git(repo, "ls-remote", "origin", "refs/heads/release").split.first

  def with_root(&block) = Dir.mktmpdir("changelog-promote", &block)

  # THE REGRESSION. The bullet `accepted` wrote after 0.40.0 shipped would merge
  # clean under `## 0.40.0`; the promote must refuse it, naming the line, before
  # anything reaches `release`.
  def test_a_promote_that_would_misfile_a_bullet_is_refused_before_anything_moves
    with_root do |root|
      repo = build(root)
      on_accepted(repo) do |text|
        commit(repo, text.sub("### Fixed\n\n", "### Fixed\n\n- entry two\n"), "entry two")
      end
      before = remote_release(repo)

      out, status = guard(root)

      refute_equal 0, status, "a misfiling promote must abort:\n#{out}"
      assert_includes out, "- entry two", "the refusal names the mis-filed line"
      assert_includes out, PUBLISHED, "and the shipped version it would land under"
      assert_includes out, "NOTHING was promoted"
      assert_equal before, remote_release(repo), "the guard writes nothing"
    end
  end

  # The control: once `accepted` has absorbed the release commit, the same bullet
  # sits under `## Unreleased`, the promote is clean, and the guard hands back the
  # exact `accepted` head it checked — the one `gh pr merge` is pinned to.
  def test_the_same_bullet_after_accepted_absorbs_the_roll_is_let_through
    with_root do |root|
      repo = build(root)
      on_accepted(repo) do
        git(repo, "merge", "--quiet", "--ff-only", "release")
        rolled = File.read(File.join(repo, "CHANGELOG.md"))
        commit(repo, rolled.sub("## Unreleased\n\n", "## Unreleased\n\n### Fixed\n\n- entry two\n\n"), "entry two")
      end
      head = git(repo, "rev-parse", "accepted").strip

      out, status = guard(root)

      assert_equal 0, status, "a clean promote must pass the guard:\n#{out}"
      assert_includes out, "CHECKED {\"studio-engine\":\"#{head}\"}"
    end
  end

  # The other half of the same merge: a new subsection at the TOP of the bucket
  # conflicts. It is refused by name here instead of dying in `gh pr merge`.
  def test_a_changelog_conflict_is_refused_by_name
    with_root do |root|
      repo = build(root)
      on_accepted(repo) do |text|
        commit(repo, text.sub("## Unreleased\n\n", "## Unreleased\n\n### Added\n\n- entry two\n\n"), "entry two")
      end

      out, status = guard(root)

      refute_equal 0, status, "a conflicting promote must abort:\n#{out}"
      assert_includes out, "CHANGELOG.md", "the refusal names the file"
      assert_match(/CONFLICT/, out, "and says it is a conflict, not a misfile")
      assert_includes out, "NOTHING was promoted"
    end
  end

  # The seam, pinned in source (bin/release.rb cannot be loaded into a Rails test,
  # and `gh pr merge` is network): the guard runs INSIDE the promote, before the
  # merge, and the merge is pinned to the head the guard checked — so what merges
  # is what was checked, even if `accepted` moves in between.
  def test_the_promote_merges_only_the_head_the_guard_checked
    start = SOURCE.index(/^def promote_accepted_to_release!\(/)
    body = SOURCE[start...(SOURCE.index(/^def /, start + 1) || SOURCE.length)]

    guard_at = body.index("refuse_misfiled_changelog!(targets)")
    merge_at = body.index('sh("gh", "pr", "merge"')
    assert guard_at, "promote_accepted_to_release! must call the misfile guard"
    assert merge_at, "and still merge with gh"
    assert_operator guard_at, :<, merge_at, "the guard must run BEFORE the merge"
    assert_includes body[merge_at, 200], "--match-head-commit", "the merge must be pinned to the checked head"
  end
end
