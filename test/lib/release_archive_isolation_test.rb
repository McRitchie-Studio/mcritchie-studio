# frozen_string_literal: true

# [unit] `bin/release archive` must reach the machine ONLY through stubbed seams: it calls
# sweep_artifacts, sweep_docs and commit_artifact_to_accepted with `apply: true`. The rationale
# is in test/support/release_archive_seams.rb. A POISON, NOT A DIFF: `git status` either side
# only reports a mutation that already happened; this raises on the attempt and names the
# command. Nothing here writes to disk. WHEN THIS FAILS, add the named seam to
# ReleaseArchiveSeams::ISOLATION_STUB. Never delete the assertion, and never let the test shell
# out "just this once".
# History: task suite-must-not-mutate-repos.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/release_archive_seams"

class ReleaseArchiveIsolationTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The board read/write and the worktree reclaim, which the release CLI archive tests
  # also stub. Kept minimal and local: this file's subject is the FILESYSTEM seams,
  # and depending on another test class's constants would couple the two.
  BOARD_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        { "archivable" => ["a", "b"], "kept" => ["m1"] }
      else
        { "archived" => ["a", "b"], "kept" => ["m1"], "count" => 2 }
      end
    end
    def reclaim_worktrees(apply:)
      apply ? ["reclaimed 3 worktree(s); freed redis DBs: 11, 12, 13", true]
            : ["reclaim candidates:", true]
    end
  RUBY

  def test_archive_reaches_the_machine_only_through_stubbed_seams
    out = run_archive("#{BOARD_STUB}; #{ReleaseArchiveSeams::ISOLATION_STUB}; " \
                      "#{ReleaseArchiveSeams::SHELL_POISON}")

    refute_includes out, "SHELL ESCAPE",
                    "archive shelled out to the real machine through an unstubbed seam. " \
                    "Add whatever the message names to ReleaseArchiveSeams::ISOLATION_STUB. " \
                    "A `bin/rails test` run must never mutate the developer's repos.\n\n#{out}"
    assert_includes out, "Archived 2 tasks",
                    "archive must still COMPLETE under the poison — a run that died early " \
                    "would satisfy the refute above while proving nothing.\n\n#{out}"
  end

  # The stubs return the tools' REAL tagged JSON; these assertions prove sweep_summary and
  # docs_summary PARSED it, so a stub cannot drift to any shape uncovered. POISONED TOO, though it
  # asserts nothing about the poison: under a new seam in `archive` that ISOLATION_STUB does not
  # cover, an unpoisoned run would shell out to the real bin/clean-artifacts with apply: true.
  # Minitest runs both tests whichever way the guard lands, so the guard alone cannot protect this
  # one.
  # History: task suite-must-not-mutate-repos.
  def test_the_stubbed_seams_still_feed_the_real_summary_parsers
    out = run_archive("#{BOARD_STUB}; #{ReleaseArchiveSeams::ISOLATION_STUB}; " \
                      "#{ReleaseArchiveSeams::SHELL_POISON}")

    assert_includes out, "Swept 1 KB of regenerable artifacts across 2 repo(s) / 3 worktree(s)",
                    "clean-artifacts-summary: JSON did not reach ArtifactSweep.parse_summary\n\n#{out}"
    assert_includes out, "Retired 1 frozen doc(s)", out
    assert_includes out, "rolled 2 ledger row(s)", out
  end

  # [integration] THE EXIT SEAM MUST NEVER GO QUIET ABOUT THE LOG CAP. ISOLATION_STUB's payload
  # carries `rotation_missing: [], rotation_unknown: [], audited_envs: []`, a sweep that audited
  # NOTHING, as --skip-audit and an unparseable summary line both look (sweep_summary returns {}
  # on purpose). The stub is deliberately left as it was: asserting against the UNAUDITED payload
  # is the point. A fixture carrying loose apps proves only that a non-empty list prints.
  # History: task cap-loose-app-logs.
  def test_the_exit_seam_names_an_unaudited_sweep_rather_than_reading_as_capped
    out = run_archive("#{BOARD_STUB}; #{ReleaseArchiveSeams::ISOLATION_STUB}; " \
                      "#{ReleaseArchiveSeams::SHELL_POISON}")

    assert_includes out, "LOG CAP NOT PROVEN",
                    "an audit that checked no app must say so in the Exit Seam, not print " \
                    "the silence a capped machine prints\n\n#{out}"
    refute_includes out, "every audited app caps its local logs",
                    "the sweep audited nothing — it cannot claim every app is capped\n\n#{out}"
  end

  private

  def run_archive(setup)
    env = SessionEnv.neutralized(OutboundSeams.env)
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; archive)
    out, = Open3.capture2e(env, "ruby", "-e", script)
    out
  end
end
