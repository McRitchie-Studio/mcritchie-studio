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
      write(repo, "docs/agents/maintenance/delete-later.md", ledger)
      git(repo, "add", "-A")
      git(repo, "commit", "--quiet", "-m", "fixture")
      yield repo
    end
  end

  def ledger
    <<~MD
      # Delete Later Ledger

      | Path | Type | Why it is a candidate | Safe-delete condition | Status |
      |------|------|-----------------------|-----------------------|--------|
      | `/old/one` | worktree | old | done | removed 2026-06-13 |
      | `/new/two` | worktree | recent | done | removed 2026-07-14 |
      | `/unresolved/three` | worktree | waiting | needs approval | pending approval |
    MD
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
      assert_equal 0, second[:ledger_rolled]
      assert_empty git(repo, "status", "--porcelain").strip
    end
  end

  # --- the ledger ----------------------------------------------------------

  def test_the_ledger_rolls_resolved_rows_and_keeps_unresolved_ones
    with_repo do |repo|
      _out, summary = run_cli(repo)

      live = File.read(File.join(repo, "docs/agents/maintenance/delete-later.md"))
      archived = File.read(File.join(repo, DocsArchive::LEDGER_ARCHIVE))

      assert_equal 1, summary[:ledger_rolled]
      assert_equal "2026-07-14", summary[:ledger_cutoff]
      assert_includes archived, "/old/one"
      refute_includes live, "/old/one"
      assert_includes live, "/new/two", "the current cycle stays live"
      assert_includes live, "pending approval", "unresolved rows never roll"
      assert_includes live, "| Path | Type |", "the table header survives"
    end
  end

  def test_an_explicit_cutoff_overrides_the_derived_one
    with_repo do |repo|
      _out, summary = run_cli(repo, "--ledger-cutoff=2026-06-01")

      assert_equal "2026-06-01", summary[:ledger_cutoff]
      assert_equal 0, summary[:ledger_rolled], "nothing predates 2026-06-01 in this fixture"
    end
  end

  # Ledger FIRST, then the doc plan: a ledger row citing a dated doc pins it, so
  # rolling that row over must free the doc in the SAME run.
  def test_rolling_a_ledger_row_frees_the_doc_it_cited
    with_repo do |repo|
      write(repo, "docs/agents/audits/named-by-ledger-2026-05-03.md", "frozen\n")
      write(repo, "docs/agents/maintenance/delete-later.md", <<~MD)
        # Delete Later Ledger

        | Path | Type | Why it is a candidate | Safe-delete condition | Status |
        |------|------|-----------------------|-----------------------|--------|
        | `docs/agents/audits/named-by-ledger-2026-05-03.md` | docs | old | done | removed 2026-06-13 |
        | `/new/two` | worktree | recent | done | removed 2026-07-14 |
      MD
      git(repo, "add", "-A")
      git(repo, "commit", "--quiet", "-m", "ledger cites a dated doc")

      _out, summary = run_cli(repo)

      assert_includes summary[:moved_paths], "docs/agents/audits/named-by-ledger-2026-05-03.md",
                      "the ledger row rolled over, so it no longer pins the doc it named"
    end
  end

  def test_the_summary_line_is_machine_readable_for_the_archive_step
    with_repo do |repo|
      out, = run_cli(repo, "--dry-run")

      summary = DocsArchive.parse_summary(out)
      refute_nil summary, "bin/release archive parses this line for its Exit Seam report"
      %i[moved moved_paths skipped ledger_rolled ledger_cutoff].each do |key|
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

  # --- the move-never-delete invariant, at the beat that makes the loss permanent ------
  #
  # This sweep is where three destroyed rows became history in 2026-08-21: a teardown
  # driven from a desk carrying a stale bin/agent-worktree overwrote their dated rows in
  # the hub's WORKING TREE, and `bin/release archive` committed the result. The roller was
  # never at fault — it archived what it was handed, 40 of 43 rows — so the refusal belongs
  # in front of it, where the destroyed row is still one `git show HEAD:` away.
  #
  # THE DAMAGE IS PRODUCED THE WAY THE STALE WRITER PRODUCES IT: a dated row replaced in
  # place. Nothing here calls the fixed writer, because the writer is exactly the component
  # that cannot be relied on.
  def clobber_dated_row(repo)
    path = File.join(repo, DocsArchive::LEDGER)
    File.write(path, File.read(path).sub("| `/new/two` | worktree | recent | done | removed 2026-07-14 |",
                                         "| `/new/two` | worktree | recycled | done | removed 2026-08-21 |"))
  end

  def test_the_sweep_refuses_a_ledger_that_has_already_lost_a_resolved_row
    with_repo do |repo|
      clobber_dated_row(repo)

      out, err, status = Open3.capture3(RbConfig.ruby, CLI, "--repo=#{repo}")
      combined = "#{out}#{err}"

      refute status.success?, "the archive beat must refuse to sweep over a destroyed row"
      assert_includes combined, "/new/two", "the refusal names the path that lost its row"
      assert_includes combined, "removed 2026-07-14", "…and the teardown episode that is gone"
      assert_includes combined, "git show HEAD:", "…and how to get it back"
      refute_includes combined, "archive-docs-summary:",
                      "it must refuse BEFORE reporting a successful sweep"
      assert_empty git(repo, "diff", "--cached", "--name-only").strip,
                   "and it must stage NOTHING on top of a ledger that has lost history"
    end
  end

  # THE CONTROL, and it is the reason the check above is trustworthy: the same sweep, the
  # same repo, an UNdamaged ledger — and the beat runs to completion. A guard that refused
  # every sweep would be indistinguishable from a broken one.
  def test_an_intact_ledger_sweeps_to_completion
    with_repo do |repo|
      out, summary = run_cli(repo)

      assert_includes out, "Ledger rollover"
      assert_operator summary[:ledger_rolled], :>, 0
    end
  end

  # A dry run changes nothing, so it REPORTS the damage and still exits 0 — `bin/release
  # archive` previews before it confirms, and a preview that returns failure wedges the
  # beat rather than protecting it.
  def test_a_dry_run_over_a_damaged_ledger_reports_but_does_not_refuse
    with_repo do |repo|
      clobber_dated_row(repo)

      out, err, status = Open3.capture3(RbConfig.ruby, CLI, "--repo=#{repo}", "--dry-run")

      assert status.success?, "a preview must not fail its caller:\n#{out}#{err}"
      assert_includes "#{out}#{err}", "removed 2026-07-14", "…but it must still say what is gone"
    end
  end
end
