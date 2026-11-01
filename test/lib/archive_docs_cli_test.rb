# frozen_string_literal: true

# [integration] tests for bin/archive-docs — the real CLI, spawned as a real
# process, against a real git repo on disk.
#
# The properties that matter here cannot be asserted in the unit tier: that the
# retirement is a `git mv` with history intact (not a delete-and-write), that a
# second run is a no-op, and that a dry run leaves the tree byte-identical.
# Run directly:
#   ruby -Itest test/lib/archive_docs_cli_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require_relative "../../bin/lib/docs_archive"

class ArchiveDocsCliTest < Minitest::Test
  CLI = File.expand_path("../../bin/archive-docs", __dir__)

  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    assert status.success?, "git #{args.join(' ')} failed:\n#{out}"
    out
  end

  def write(repo, rel, content = "placeholder\n")
    path = File.join(repo, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # A fixture tree with one of each interesting shape.
  def with_repo
    Dir.mktmpdir("archive-docs-cli") do |repo|
      git(repo, "init", "--quiet", ".")
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Test")

      write(repo, "docs/agents/audits/frozen-2026-05-01.md", "frozen snapshot\n")
      write(repo, "docs/agents/audits/cited-2026-05-02.md", "still cited\n")
      write(repo, "docs/agents/modules/live-guide.md", "see [it](../audits/cited-2026-05-02.md)\n")
      write(repo, "docs/agents/maintenance/kickoff-do-the-thing.md", "LIVE HANDOFF — undated\n")
      write(repo, "docs/agents/maintenance/parking-lot.md", "live\n")
      git(repo, "add", "-A")
      git(repo, "commit", "--quiet", "-m", "fixture")
      yield repo
    end
  end

  def run_cli(repo, *flags)
    out, err, status = Open3.capture3(RbConfig.ruby, CLI, "--repo=#{repo}", *flags)
    assert status.success?, "bin/archive-docs failed:\n#{out}\n#{err}"
    [out, DocsArchive.parse_summary(out)]
  end

  # --- the sweep -----------------------------------------------------------

  def test_dry_run_lists_the_moves_and_changes_nothing
    with_repo do |repo|
      before = git(repo, "status", "--porcelain")
      out, summary = run_cli(repo, "--dry-run")

      assert_includes summary[:moved_paths], "docs/agents/audits/frozen-2026-05-01.md"
      assert_equal 1, summary[:moved]
      assert summary[:dry_run]
      assert_includes out, "dry-run"
      assert_equal before, git(repo, "status", "--porcelain"), "a dry run must not touch the tree"
      assert File.exist?(File.join(repo, "docs/agents/audits/frozen-2026-05-01.md"))
    end
  end

  def test_the_real_run_retires_via_git_mv_with_history_intact
    with_repo do |repo|
      _out, summary = run_cli(repo)

      old_path = File.join(repo, "docs/agents/audits/frozen-2026-05-01.md")
      new_path = File.join(repo, "docs/agents/archive/audits/frozen-2026-05-01.md")

      assert_equal 1, summary[:moved]
      refute File.exist?(old_path)
      assert File.exist?(new_path)
      assert_equal "frozen snapshot\n", File.read(new_path), "content must survive byte for byte"

      # Staged as a RENAME, not as a delete plus an add — that is what keeps
      # `git log --follow` and blame working across the retirement.
      staged = git(repo, "diff", "--cached", "--name-status", "-M")
      assert_match(/^R\d*\s+docs\/agents\/audits\/frozen-2026-05-01\.md\s+docs\/agents\/archive\/audits\/frozen-2026-05-01\.md/,
                   staged, "expected a staged rename, got:\n#{staged}")
    end
  end

  def test_nothing_is_ever_deleted
    with_repo do |repo|
      run_cli(repo)

      staged = git(repo, "diff", "--cached", "--name-status", "-M")
      deletions = staged.lines.select { |l| l.start_with?("D") }

      assert_empty deletions, "the sweep must never delete; every retirement is a move"
    end
  end

  def test_a_still_referenced_snapshot_is_skipped_and_named
    with_repo do |repo|
      out, summary = run_cli(repo)

      skipped = summary[:skipped].find { |s| s[:path].include?("cited-2026-05-02") }
      refute_nil skipped, "a cited snapshot must be skipped, not moved"
      assert_equal ["docs/agents/modules/live-guide.md"], skipped[:referrers]
      assert_includes out, "still referenced"
      assert File.exist?(File.join(repo, "docs/agents/audits/cited-2026-05-02.md"))
    end
  end

  def test_undated_live_handoffs_are_untouched
    with_repo do |repo|
      run_cli(repo)

      assert File.exist?(File.join(repo, "docs/agents/maintenance/kickoff-do-the-thing.md")),
             "an undated kickoff doc is a LIVE handoff and must survive the sweep"
      assert File.exist?(File.join(repo, "docs/agents/maintenance/parking-lot.md"))
    end
  end

  # Archive is idempotent by contract — bin/release archive can be re-run after
  # an interruption and must not move anything twice.
  def test_re_running_moves_nothing_twice
    with_repo do |repo|
      _out, first = run_cli(repo)
      git(repo, "commit", "--quiet", "-m", "first sweep")

      _out2, second = run_cli(repo)

      assert_equal 1, first[:moved]
      assert_equal 0, second[:moved], "a second sweep must find nothing left to retire"
      assert_empty git(repo, "status", "--porcelain").strip
    end
  end

  # --- the retired ledger ----------------------------------------------------

  # The sweep runs in a real primary, where an old copy of the ledger could still be
  # lying around in a branch or a working tree. It is an ordinary undated doc now: no
  # roll, no refusal, nothing staged.
  def test_a_leftover_ledger_file_is_left_alone
    with_repo do |repo|
      body = "| `/new/two` | worktree | recent | done | removed 2026-07-14 |\n"
      write(repo, "docs/agents/maintenance/delete-later.md", body)
      git(repo, "add", "-A")
      git(repo, "commit", "--quiet", "-m", "stray ledger")

      _out, summary = run_cli(repo)

      assert_equal 1, summary[:moved], "the frozen snapshot still retires"
      assert_equal body, File.read(File.join(repo, "docs/agents/maintenance/delete-later.md"))
      refute File.exist?(File.join(repo, "docs/agents/archive/maintenance/delete-later-archive.md")),
             "nothing may recreate the ledger's archive"
    end
  end

  def test_the_summary_line_is_machine_readable_for_the_archive_step
    with_repo do |repo|
      out, = run_cli(repo, "--dry-run")

      summary = DocsArchive.parse_summary(out)
      refute_nil summary, "bin/release archive parses this line for its Exit Seam report"
      %i[moved moved_paths skipped].each do |key|
        assert summary.key?(key), "the archive summary needs #{key}"
      end
    end
  end

  def test_json_flag_prints_only_the_summary
    with_repo do |repo|
      out, = run_cli(repo, "--dry-run", "--json")

      assert_equal 1, out.lines.reject { |l| l.strip.empty? }.size
    end
  end
end
