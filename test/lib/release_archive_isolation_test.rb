# frozen_string_literal: true

# [unit] `bin/release archive` must reach the machine ONLY through stubbed seams.
#
# THE DEFECT THIS EXISTS TO CATCH (found 2026-08-28). release_cli_test.rb's two
# archive tests stubbed the conductor and the worktree reclaim, but not
# sweep_artifacts, sweep_docs or commit_artifact_to_release — and `archive` calls
# all three with `apply: true`. So `bin/rails test` ran bin/clean-artifacts and
# bin/archive-docs FOR REAL: 32.9 MB reclaimed across 9 repos and 32 worktrees,
# and a `git mv` in the PRIMARY checkout that the next run then died on. The
# rationale, and why commit_artifact_to_release was the sharpest of the three,
# is recorded in test/support/release_archive_seams.rb.
#
# WHY A POISON RATHER THAN A DIFF. The obvious guard — capture `git status`
# either side of the run and assert it is unchanged — can only report a mutation
# that has ALREADY happened, and the mutation is the thing being prevented. This
# raises on the attempt instead, before anything runs, and names the command so
# the fix is obvious. Nothing here writes to disk.
#
# WHEN THIS FAILS, the remedy is to add the named seam to
# ReleaseArchiveSeams::ISOLATION_STUB. Never to delete the assertion, and never
# to let the test shell out "just this once".

require "bundler/setup"
require "minitest/autorun"
require "open3"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/release_archive_seams"

class ReleaseArchiveIsolationTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The board read/write and the worktree reclaim, which release_cli_test.rb also
  # stubs. Kept minimal and local: this file's subject is the FILESYSTEM seams,
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

  # The stubs return the tools' REAL tagged JSON, and these assertions are what
  # make that fidelity load-bearing: they prove sweep_summary and docs_summary
  # actually PARSED it. Without them a stub could drift to any shape and the
  # parsers would be uncovered — they were, before this file existed.
  # POISONED TOO, though it asserts nothing about the poison. Under the very
  # regression the guard above exists to catch — a new seam in `archive` that
  # ISOLATION_STUB does not yet cover — an UNPOISONED run of this test would
  # shell out to the real bin/clean-artifacts with apply: true and sweep the
  # machine, which is the exact harm this file was written to prevent. Minitest
  # runs both tests whichever way the guard lands, so the guard alone does not
  # protect this one. Costs nothing when the stubs are complete.
  def test_the_stubbed_seams_still_feed_the_real_summary_parsers
    out = run_archive("#{BOARD_STUB}; #{ReleaseArchiveSeams::ISOLATION_STUB}; " \
                      "#{ReleaseArchiveSeams::SHELL_POISON}")

    assert_includes out, "Swept 1 KB of regenerable artifacts across 2 repo(s) / 3 worktree(s)",
                    "clean-artifacts-summary: JSON did not reach ArtifactSweep.parse_summary\n\n#{out}"
    assert_includes out, "Retired 1 frozen doc(s)", out
    assert_includes out, "rolled 2 ledger row(s)", out
  end

  private

  def run_archive(setup)
    env = SessionEnv.neutralized(OutboundSeams.env)
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; archive)
    out, = Open3.capture2e(env, "ruby", "-e", script)
    out
  end
end
