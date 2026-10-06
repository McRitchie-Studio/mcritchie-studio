# frozen_string_literal: true

# Does the archive beat's artifact commit carry a retired doc's REMOVAL to `release`,
# or only its archive copy?
#
# THE DEFECT (rel-20261006-f6a119, commit e8f121d4). Step 10 of `bin/release archive`
# named DocsArchive.archive_path_for(rel) for each moved doc but never `rel` itself.
# That happened to work while the staged `git mv` deletion rode the checkout flip. On
# the hub primary that morning, the local `release` (dcc53183) was OLDER than `main`
# and predated the doc, so the staged deletion carried over as nothing. The
# `merge --ff-only origin/release` then wrote the doc back, and the commit
# carried only the archive copy. `release` held the doc at both paths, and
# ArchivePathCollisionTest reddened the next candidate.
#
# Naming the source in `git add` cannot fix this alone, because by then the path
# exists on disk again. The fix names the source at the call site, and
# commit_artifact_to_release reads it as a removal (absent on `main` before the flip)
# and `git rm`s it after the ff.
#
# WHY A FILE OF ITS OWN: the release CLI files are frozen append hotspots under the
# suite's size ratchet. Nothing here touches a real repo: the integration
# fixture is a bare origin plus a clone in a tmpdir, under OutboundSeams.

require "bundler/setup"
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/release_archive_seams"
require_relative "../../bin/lib/docs_archive"

class ReleaseArchiveRetiredDocCommitTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  SOURCE = "docs/agents/audits/census-2026-10-06.md"
  ARCHIVED = DocsArchive.archive_path_for(SOURCE)

  BOARD_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      read_only ? { "archivable" => ["a"], "kept" => [] } : { "archived" => ["a"], "kept" => [], "count" => 1 }
    end
    def reclaim_worktrees(apply:)
      apply ? ["reclaimed 0 worktree(s)", true] : ["reclaim candidates:", true]
    end
  RUBY

  # Defined AFTER ISOLATION_STUB, so it replaces that stub's no-op and records what
  # step 10 hands the commit. Still never reaches git.
  RECORD_COMMIT = <<~RUBY
    def commit_artifact_to_release(repo, paths, message)
      Array(paths).each { |p| puts("ARTIFACT_PATH " + p.to_s) }
    end
  RUBY

  # ---- [unit] step 10 names both sides of every move -------------------------

  def test_unit_archive_commit_names_the_retired_source_and_its_archive_copy
    env = SessionEnv.neutralized(OutboundSeams.env)
    setup = "#{BOARD_STUB}; #{ReleaseArchiveSeams::ISOLATION_STUB}; #{RECORD_COMMIT}; " \
            "#{ReleaseArchiveSeams::SHELL_POISON}"
    out, = Open3.capture2e(env, "ruby", "-e", %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; archive))
    named = out.lines.filter_map { |l| l.chomp.delete_prefix("ARTIFACT_PATH ") if l.start_with?("ARTIFACT_PATH ") }

    refute_empty named, "archive never reached the artifact commit\n\n#{out}"
    # ISOLATION_STUB's sweep_docs retires docs/agents/audits/stub.md.
    assert named.any? { |p| p.end_with?("/docs/agents/archive/audits/stub.md") },
           "the archive copy must be committed\n\n#{named.join("\n")}"
    assert named.any? { |p| p.end_with?("/docs/agents/audits/stub.md") },
           "the retired doc's SOURCE must be named too, or the commit carries the archive copy without " \
           "the live copy's removal and release holds the doc at two paths (e8f121d4)\n\n#{named.join("\n")}"
  end

  # ---- [integration] the committed tree holds the doc at exactly one path ------

  # The e8f121d4 shape: the local `release` is behind `main` and predates the doc.
  def test_integration_stale_local_release_still_commits_the_removal
    with_fixture(stale_release: true) do |repo, dir|
      retire_and_commit(repo, dir, [ARCHIVED, SOURCE])

      tree = release_tree(repo)
      assert_includes tree, ARCHIVED, "the archive copy must land on release"
      refute_includes tree, SOURCE, "the live copy must be REMOVED on release, not left beside its archive copy"
      assert_empty collisions(tree), "release holds a retired doc at two paths: #{collisions(tree).inspect}"
    end
  end

  # The common shape: the local `release` already has the doc. The staged deletion rides
  # the flip, so the removal path is already gone from disk. Naming it must not make
  # git abort the batch on an unmatched pathspec.
  def test_integration_current_local_release_commits_the_move_once
    with_fixture(stale_release: false) do |repo, dir|
      retire_and_commit(repo, dir, [ARCHIVED, SOURCE])

      tree = release_tree(repo)
      assert_includes tree, ARCHIVED
      refute_includes tree, SOURCE
      assert_empty collisions(tree)
    end
  end

  private

  # ArchivePathCollisionTest's detector, bound to the same archive_path_for.
  def collisions(paths)
    present = paths.to_h { |p| [p, true] }
    paths.reject { |p| p.start_with?("#{DocsArchive::ARCHIVE_DIR}/") }
         .map { |p| [p, DocsArchive.archive_path_for(p)] }
         .select { |_live, archived| present[archived] }
  end

  # A bare origin plus a clone. origin/main and origin/release both carry the doc; the
  # local `release` either matches origin (current) or sits at the seed (stale).
  def with_fixture(stale_release:)
    Dir.mktmpdir("release-retired-doc") do |dir|
      origin = File.join(dir, "origin.git")
      repo = File.join(dir, "repo")
      system("git", "init", "--bare", "-q", origin, out: File::NULL, err: File::NULL) || flunk("git init --bare failed")
      system("git", "clone", "-q", origin, repo, out: File::NULL, err: File::NULL) || flunk("git clone failed")
      git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
      git(repo, "config", "user.email", "t@t.t")
      git(repo, "config", "user.name", "t")
      git(repo, "config", "commit.gpgsign", "false")
      File.write(File.join(repo, "README"), "fixture")
      git(repo, "add", "README")
      git(repo, "commit", "-qm", "seed")
      git(repo, "branch", "release")

      FileUtils.mkdir_p(File.join(repo, File.dirname(SOURCE)))
      File.write(File.join(repo, SOURCE), "frozen census\n")
      git(repo, "add", SOURCE)
      git(repo, "commit", "-qm", "file the census")
      git(repo, "push", "-q", "origin", "main")
      git(repo, "push", "-q", "origin", "main:release")
      git(repo, "branch", "-f", "release", "main") unless stale_release
      yield repo, dir
    end
  end

  # Retire the doc exactly as DocsArchive does (a staged `git mv`), then run the real
  # commit_artifact_to_release with `rels` named.
  def retire_and_commit(repo, dir, rels)
    FileUtils.mkdir_p(File.join(repo, File.dirname(ARCHIVED)))
    git(repo, "mv", SOURCE, ARCHIVED)
    paths = rels.map { |r| File.join(repo, r) }
    setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) + %(def repo_path(_repo) = #{repo.inspect})
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; ) +
             %{commit_artifact_to_release("mcritchie-studio", #{paths.inspect}, "ledger: fixture"); puts("DONE")}
    out, err, status = Open3.capture3(OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => dir), "ruby", "-e", script)
    assert_predicate status, :success?, "the dance must not crash: #{err}"
    assert_includes out, "committed", "the artifact commit must land on release\n\n#{out}"
  end

  def release_tree(repo)
    out, = Open3.capture2("git", "-C", repo, "ls-tree", "-r", "--name-only", "origin/release")
    out.lines.map(&:chomp)
  end

  def git(repo, *args)
    system("git", "-C", repo, *args, out: File::NULL, err: File::NULL) || flunk("git #{args.join(' ')} failed")
  end
end
