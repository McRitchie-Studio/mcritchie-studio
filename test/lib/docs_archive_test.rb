# frozen_string_literal: true

# [unit] tests for bin/lib/docs_archive.rb — the two qualification rules and the
# ledger rollover split.
#
# The reference rule is exercised against a REAL git repo in a tmpdir rather than
# a stubbed search, because `git grep` (tracked files only, exit 1 on no match)
# is the behavior being relied on. Building one costs milliseconds; stubbing it
# would test the stub.
# Run directly:
#   ruby -Itest test/lib/docs_archive_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/docs_archive"

class DocsArchiveTest < Minitest::Test
  def with_repo
    Dir.mktmpdir("docs-archive") do |repo|
      system("git", "init", "--quiet", repo, exception: true)
      system("git", "-C", repo, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", repo, "config", "user.name", "Test", exception: true)
      yield repo
    end
  end

  def write(repo, rel, content = "placeholder\n")
    path = File.join(repo, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def commit_all(repo)
    system("git", "-C", repo, "add", "-A", exception: true)
    system("git", "-C", repo, "commit", "--quiet", "-m", "fixture", exception: true)
  end

  # --- rule 1 --------------------------------------------------------------

  def test_a_dated_filename_qualifies
    assert DocsArchive.frozen_shape?("docs/agents/system/opsec-audit-pre-prod-2026-05-19.md")
    assert DocsArchive.frozen_shape?("docs/agents/maintenance/worktree-disposition-2026-06-13.md")
  end

  def test_a_retro_rel_filename_qualifies_even_without_a_dashed_date
    assert DocsArchive.frozen_shape?("docs/agents/audits/retro-rel-20260623-fb969a.md"),
           "retro-rel-* carries a compact date, not YYYY-MM-DD — rule 1 names it explicitly"
  end

  def test_everything_in_audits_qualifies_dated_or_not
    assert DocsArchive.frozen_shape?("docs/agents/audits/some-undated-audit.md")
  end

  # THE FAIL-SAFE HALF OF RULE 1. Undated live handoffs — kickoff docs, the
  # parking lot, the ledger itself — are current instructions, not snapshots.
  def test_undated_live_docs_never_qualify
    refute DocsArchive.frozen_shape?("docs/agents/maintenance/kickoff-log-rotation.md")
    refute DocsArchive.frozen_shape?("docs/agents/maintenance/parking-lot.md")
    refute DocsArchive.frozen_shape?("docs/agents/maintenance/delete-later.md")
    refute DocsArchive.frozen_shape?("docs/agents/system/devops-cycle-design.md")
    refute DocsArchive.frozen_shape?("docs/agents/modules/worktrees.md")
  end

  def test_already_archived_files_never_qualify_again
    refute DocsArchive.frozen_shape?("docs/agents/archive/audits/first-pass-2026-06-13.md"),
           "the archive is the destination; re-qualifying it would move files forever"
  end

  def test_non_markdown_is_left_alone
    refute DocsArchive.frozen_shape?("docs/agents/maintenance/pr361-guardrails.diff")
  end

  # --- rule 2 --------------------------------------------------------------

  def test_a_file_cited_by_a_live_doc_is_pinned
    with_repo do |repo|
      write(repo, "docs/agents/audits/frozen-2026-05-01.md")
      write(repo, "docs/agents/modules/live-guide.md", "see [audit](../audits/frozen-2026-05-01.md)\n")
      commit_all(repo)

      plan = DocsArchive.plan(repo)

      assert_empty plan[:moves]
      assert_equal ["docs/agents/modules/live-guide.md"], plan[:skipped].first[:referrers]
    end
  end

  def test_a_file_cited_only_by_code_is_still_pinned
    with_repo do |repo|
      write(repo, "docs/agents/audits/frozen-2026-05-01.md")
      write(repo, "config/feature_shapes.yml", "# see docs/agents/audits/frozen-2026-05-01.md\n")
      commit_all(repo)

      plan = DocsArchive.plan(repo)

      assert_empty plan[:moves], "a citation from code pins the doc as hard as one from a doc"
      assert_equal ["config/feature_shapes.yml"], plan[:skipped].first[:referrers]
    end
  end

  # THE RULE THAT MAKES THE SWEEP WORK AT ALL. These snapshots cross-reference
  # each other — in this repo, prelaunch-audit-2026-05-24-{carl,jasper,steffon}
  # are referenced ONLY by prelaunch-audit-2026-05-24-synthesis, itself a
  # candidate. A referrer that is ALSO leaving is not "the live tree", so the
  # cluster retires together. Count references from candidates and the sweep
  # moves nothing, forever.
  def test_a_cluster_that_only_cites_itself_retires_together
    with_repo do |repo|
      write(repo, "docs/agents/system/prelaunch-2026-05-24-synthesis.md",
            "rolls up [carl](prelaunch-2026-05-24-carl.md) and [jasper](prelaunch-2026-05-24-jasper.md)\n")
      write(repo, "docs/agents/system/prelaunch-2026-05-24-carl.md")
      write(repo, "docs/agents/system/prelaunch-2026-05-24-jasper.md")
      commit_all(repo)

      plan = DocsArchive.plan(repo)

      assert_equal 3, plan[:moves].size, "all three should retire together"
      assert_empty plan[:skipped]
    end
  end

  def test_untracked_files_are_never_touched
    with_repo do |repo|
      write(repo, "docs/agents/audits/committed-2026-05-01.md")
      commit_all(repo)
      write(repo, "docs/agents/audits/scratch-2026-05-02.md") # never added

      moves = DocsArchive.plan(repo)[:moves].map { |m| m[:from] }

      assert_equal ["docs/agents/audits/committed-2026-05-01.md"], moves,
                   "an untracked scratch file is not ours to move, and git mv would fail on it"
    end
  end

  # --- where files land ----------------------------------------------------

  def test_the_source_subdirectory_is_mirrored_under_the_archive
    assert_equal "docs/agents/archive/audits/x-2026-05-01.md",
                 DocsArchive.archive_path_for("docs/agents/audits/x-2026-05-01.md")
    assert_equal "docs/agents/archive/system/y-2026-05-01.md",
                 DocsArchive.archive_path_for("docs/agents/system/y-2026-05-01.md")
  end

  def test_mirroring_keeps_co_archived_siblings_resolving_each_other
    from = %w[docs/agents/system/a-2026-05-01.md docs/agents/system/b-2026-05-01.md]
    dirs = from.map { |p| File.dirname(DocsArchive.archive_path_for(p)) }.uniq

    assert_equal 1, dirs.size,
                 "siblings must land in ONE directory or their bare-filename links break"
  end

  # --- the ledger rollover -------------------------------------------------

  LEDGER = <<~MD
    # Delete Later Ledger

    Preamble prose that must survive.

    | Path | Type | Why it is a candidate | Safe-delete condition | Status |
    |------|------|-----------------------|-----------------------|--------|
    | `/old/one` | worktree | old | done | removed 2026-06-13 |
    | `/old/two` | worktree | old | done | removed 2026-07-04 |
    | `/new/three` | worktree | recent | done | removed 2026-07-14 |
    | `/unresolved/four` | worktree | waiting | needs approval | pending approval |
    | `/reference/five` | local memory | keep | n/a | reference only |
  MD

  # REGRESSION. A row reads "… | removed 2026-06-13 |\\n", so a naive
  # split("|").last is the trailing NEWLINE, never the status cell. That read as
  # "no date" for every row: the cutoff came back nil and the rollover silently
  # did nothing while reporting success.
  def test_the_status_date_is_read_from_the_last_cell_not_the_trailing_newline
    row = "| `/old/one` | worktree | old | done | removed 2026-06-13 |\n"

    assert_equal "2026-06-13", DocsArchive.row_date(row)
  end

  def test_the_default_cutoff_is_the_newest_date_in_the_ledger
    assert_equal "2026-07-14", DocsArchive.newest_ledger_date(LEDGER)
  end

  def test_rows_older_than_the_cutoff_roll_over
    split = DocsArchive.split_ledger(LEDGER, "2026-07-14")

    assert_equal 2, split[:rolled].size
    assert(split[:rolled].all? { |row| row.include?("2026-06-13") || row.include?("2026-07-04") })
    assert_includes split[:kept], "/new/three", "the current cycle's rows stay live"
  end

  # Undated rows are UNRESOLVED WORK, not history. Rolling them into an archive
  # would hide a pending approval behind a file nobody opens.
  def test_undated_rows_always_stay_live
    split = DocsArchive.split_ledger(LEDGER, "2026-07-14")

    assert_includes split[:kept], "pending approval"
    assert_includes split[:kept], "reference only"
    refute(split[:rolled].any? { |row| row.include?("pending approval") })
  end

  def test_the_preamble_and_table_header_survive
    split = DocsArchive.split_ledger(LEDGER, "2026-07-14")

    assert_includes split[:kept], "# Delete Later Ledger"
    assert_includes split[:kept], "Preamble prose that must survive."
    assert_includes split[:kept], "| Path | Type |"
    assert_includes split[:kept], "|------|------|"
  end

  def test_the_rollover_is_idempotent
    once = DocsArchive.split_ledger(LEDGER, DocsArchive.newest_ledger_date(LEDGER))
    twice = DocsArchive.split_ledger(once[:kept], DocsArchive.newest_ledger_date(once[:kept]))

    assert_empty twice[:rolled], "a second pass must find nothing left to roll"
    assert_equal once[:kept], twice[:kept]
  end
end
