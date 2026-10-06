# frozen_string_literal: true

# `bin/release archive`: the plan, the worktree reclaim and its tally.
#
# Part of the bin/release CLI suite, split by subcommand from the old
# test/lib/release_cli_test.rb (release-cli-tests-by-subcommand, 2026-10-05). The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_archive_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliArchiveTest < ReleaseCliHarness
  def test_archive_dry_run_previews_the_plan_and_mutates_nothing
    out = run_cli(["--dry-run"], call: "archive", setup: ARCHIVE_DRY_STUB)

    assert_includes out, "3 shipped task(s) to archive", "the archivable count + sample is shown"
    assert_includes out, "old-ship-a", "a sample of the archivable slugs is shown"
    assert_includes out, "2 last-release member(s) KEPT", "the kept last-release members are shown"
    assert_includes out, "worktree reclaim preview", "the reclaim preview runs in dry-run"
    assert_includes out, "reclaim candidates", "the reclaim tool's own dry-run lists candidates"
    assert_includes out, "DRY RUN", "a dry-run executes nothing"
  end
  def test_archive_run_archives_then_reclaims_and_summarizes
    out = run_cli(["--yes"], call: "archive", setup: ARCHIVE_RUN_STUB)

    assert_includes out, "Archived 2 tasks"
    assert_includes out, "reclaimed 3 worktrees"
    assert_includes out, "SHIPPED → 1"
  end

  # desk-ledger-stops-ghosting. Archive runs the FULL sweep (`cleanup --reclaim --yes`) and
  # says in one line what it took and what the guards held.
  def test_archive_runs_the_full_reclaim_sweep_and_prints_its_tally
    stub = <<~RUBY
      #{ARCHIVE_RUN_STUB}
      def reclaim_worktrees(apply:)
        return ["reclaim candidates:", true] unless apply
        out = "withheld mcritchie-studio/live-desk: the bound task landed a durable artifact 2m ago\n" \
              "withheld turf-monster/other: a builder is live-claiming it\n" \
              "skipping mcritchie-studio/raced: no longer a safe candidate\n" \
              "reclaimed 2 worktree(s); freed redis DBs: 11, 12\n"
        puts "SWEEP-APPLIED"
        [out, true]
      end
    RUBY
    out = run_cli(["--yes"], call: "archive", setup: stub)

    assert_includes out, "SWEEP-APPLIED", "archive applies the reclaim sweep"
    assert_includes out, "worktree reclaim: reclaimed 2, held 3"
    assert_includes out, "reclaimed 2 worktrees"
    refute_includes out, "⚠ worktree reclaim"
  end

  # A reclaim that RAISES must not kill the archive: the board write has landed, and the
  # artifact sweep, doc retirement and summary still run behind a warning.
  def test_archive_survives_a_reclaim_that_raises_with_a_warning
    stub = <<~RUBY
      #{ARCHIVE_RUN_STUB}
      def reclaim_worktrees(apply:)
        return ["reclaim candidates:", true] unless apply
        raise Errno::ENOENT, "bin/agent-worktree"
      end
    RUBY
    out = run_cli(["--yes"], call: "archive", setup: stub)

    assert_match(/⚠ worktree reclaim failed \(Errno::ENOENT.*archive continues/, out)
    assert_includes out, "Archived 2 tasks; reclaimed 0 worktrees", "the archive reaches its summary"
    assert_includes out, "Swept 1 KB", "the steps after the reclaim still run"
  end

  # A reclaim that exits non-zero was dropped without a word; it now warns and archive goes on.
  def test_archive_warns_on_a_reclaim_that_exits_non_zero
    stub = <<~RUBY
      #{ARCHIVE_RUN_STUB}
      def reclaim_worktrees(apply:)
        apply ? ["error: board unreachable\n", false] : ["reclaim candidates:", true]
      end
    RUBY
    out = run_cli(["--yes"], call: "archive", setup: stub)

    assert_includes out, "⚠ worktree reclaim exited non-zero; archive continues"
    assert_includes out, "worktree reclaim: reclaimed 0, held 0"
    assert_includes out, "Archived 2 tasks; reclaimed 0 worktrees"
  end

  # reclaim-after-archive-window. A failed reclaim used to warn MID-output, dozens of lines
  # above the summary, and archive exited 0 with a clean closing line — so the operator
  # reading the end of the run saw a tidy archive and ~25 desks stayed standing. The warning
  # now also closes the run, naming the re-run. The archive itself succeeded, so it still
  # returns normally (exit 0).
  def test_archive_closing_line_names_a_reclaim_that_raised
    stub = <<~RUBY
      #{ARCHIVE_RUN_STUB}
      def reclaim_worktrees(apply:)
        return ["reclaim candidates:", true] unless apply
        raise Errno::ENOENT, "bin/agent-worktree"
      end
    RUBY
    out = run_cli(["--yes"], call: %(archive; puts "ARCHIVE-RETURNED"), setup: stub)
    lines = out.lines.map(&:strip).reject(&:empty?)

    assert_equal "ARCHIVE-RETURNED", lines.last, "a failed reclaim never fails the archive"
    assert_match(/\A⚠ worktree reclaim failed — .*bin\/agent-worktree cleanup --reclaim --yes/, lines[-2],
                 "the closing line is where the operator reads a run's outcome; a failed sweep must be on it")
  end

  def test_archive_closing_line_names_a_reclaim_that_exited_non_zero
    stub = <<~RUBY
      #{ARCHIVE_RUN_STUB}
      def reclaim_worktrees(apply:)
        apply ? ["error: board unreachable\n", false] : ["reclaim candidates:", true]
      end
    RUBY
    out = run_cli(["--yes"], call: %(archive; puts "ARCHIVE-RETURNED"), setup: stub)
    lines = out.lines.map(&:strip).reject(&:empty?)

    assert_equal "ARCHIVE-RETURNED", lines.last
    assert_match(/\A⚠ worktree reclaim failed — .*bin\/agent-worktree cleanup --reclaim --yes/, lines[-2])
  end

  def test_archive_closing_line_is_quiet_about_a_reclaim_that_succeeded
    out = run_cli(["--yes"], call: %(archive; puts "ARCHIVE-RETURNED"), setup: ARCHIVE_RUN_STUB)

    refute_match(/worktree reclaim failed/, out)
  end

  # "held M" used to count the desks OUTSIDE the managed root too — a reviewer's scratch
  # checkout or a Claude Code worktree the sweep will never touch — so it overstated what
  # the guards were protecting. They are tallied apart.
  def test_reclaim_tally_splits_outside_managed_root_from_held
    stub = <<~RUBY
      #{ARCHIVE_RUN_STUB}
      def reclaim_worktrees(apply:)
        return ["reclaim candidates:", true] unless apply
        out = "withheld mcritchie-studio/live-desk: the desk was written to within the last 1.5h\n" \
              "withheld mcritchie-studio/wt-1: outside the managed desk root (/tmp is not <repo>/.worktrees or <repo>.worktrees)\n" \
              "withheld mcritchie-studio/wt-2: outside the managed desk root (/tmp is not <repo>/.worktrees or <repo>.worktrees)\n" \
              "reclaimed 1 worktree(s); freed redis DBs: 11\n"
        [out, true]
      end
    RUBY
    out = run_cli(["--yes"], call: "archive", setup: stub)

    assert_includes out, "worktree reclaim: reclaimed 1, held 1, outside managed root 2"
  end

  def test_reclaim_held_count_counts_partition_holds_and_under_lock_skips
    out = "withheld a/b: x\nskipping c/d: y\nnote: a/b: withholding z\nreclaimed 1 worktree(s)"
    assert_equal "2", eval_helper(%(reclaim_held_count(#{out.inspect}).to_s))
  end

  def test_reclaimed_count_parses_the_agent_worktree_summary
    assert_equal "5", eval_helper(%(reclaimed_count("reclaimed 5 worktree(s); freed redis DBs: 9").to_s))
    assert_equal "0", eval_helper(%(reclaimed_count("reclaim: nothing reclaimed").to_s))
  end
  def test_archive_is_non_blocking_and_never_invokes_retro
    out = run_cli(["--yes"], call: "archive", setup: ARCHIVE_NO_RETRO_STUB)
    assert_includes out, "Archived 1 tasks", "archive completes independently of retro"
  end
end
