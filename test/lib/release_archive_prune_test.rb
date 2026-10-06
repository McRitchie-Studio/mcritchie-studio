# frozen_string_literal: true

# [integration] `bin/release archive` drives both pruners: the dry run previews
# their counts, --yes applies them and logs what went, and a pruner that refuses
# warns without failing the archive.
#
#   bin/rails test test/lib/release_archive_prune_test.rb
#
# Every seam is stubbed and the shell is poisoned (ReleaseArchiveSeams), so nothing
# here reaches the machine, the board or a remote.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/release_archive_seams"

class ReleaseArchivePruneTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  BOARD_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        { "archivable" => ["a", "b"], "kept" => ["m1"] }
      else
        raise "a dry run must not write the board" if DRY
        { "archived" => ["a", "b"], "kept" => ["m1"], "count" => 2 }
      end
    end
    def reclaim_worktrees(apply:)
      apply ? ["reclaimed 0 worktree(s)", true] : ["reclaim candidates:", true]
    end
  RUBY

  def test_dry_run_previews_both_pruners_counts
    out = run_archive("--dry-run")

    assert_includes out, "session marker prune preview", out
    assert_includes out, "branch prune preview", out
    assert_includes out, "✓ session markers: would remove 3 (a.json, a.heartbeat, a.mascot-heal)", out
    assert_includes out, "✓ merged branches: would remove 2 (feat/done-a, feat/done-b)", out
    refute_includes out, "session marker prune: bin/prune-session-markers --yes", "a dry run applies nothing"
  end

  def test_yes_applies_both_pruners_and_logs_what_went
    out = run_archive("--yes")

    assert_includes out, "session marker prune: bin/prune-session-markers --yes", out
    assert_includes out, "branch prune: bin/prune-branches --yes", out
    assert_includes out, "✓ session markers: removed 3 (a.json, a.heartbeat, a.mascot-heal)", out
    assert_includes out, "✓ merged branches: removed 2 (feat/done-a, feat/done-b)", out
  end

  def test_a_refused_pruner_warns_and_the_archive_completes
    refused = <<~RUBY
      def prune_branches(apply:)
        BranchPrune.parse_summary(BranchPrune.summary_line(
          BranchPrune.summary(BranchPrune::Plan.new(prune: [], skipped: {}, refusal: "open PRs could not be read"),
                              applied: false)
        )) || {}
      end
    RUBY
    out = run_archive("--yes", extra: refused)

    assert_includes out, "⚠ merged branches: refused — open PRs could not be read", out
    assert_includes out, "Archived 2 tasks", "the archive still completes"
  end

  def test_a_pruner_that_cannot_run_warns_and_the_archive_completes
    # The real seam, with the tool missing from the cwd: run_pruner rescues the raise.
    broken = <<~RUBY
      module Open3
        def self.capture2e(*cmd, **) = raise(Errno::ENOENT, cmd.first.to_s)
      end
      def prune_session_markers(apply:)
        run_pruner(["bin/prune-session-markers", "--yes"]) { |out| MarkerPrune.parse_summary(out) }
      end
    RUBY
    out = run_archive("--yes", extra: broken)

    assert_includes out, "⚠ bin/prune-session-markers failed (Errno::ENOENT", out
    assert_includes out, "⚠ session markers: no summary", out
    assert_includes out, "Archived 2 tasks", out
  end

  private

  def run_archive(flag, extra: "")
    env = SessionEnv.neutralized(OutboundSeams.env)
    setup = "#{BOARD_STUB}; #{ReleaseArchiveSeams::ISOLATION_STUB}; #{ReleaseArchiveSeams::SHELL_POISON}; #{extra}"
    script = %(ARGV.replace([#{flag.inspect}]); load #{BIN.inspect}; #{setup}; archive)
    out, = Open3.capture2e(env, "ruby", "-e", script)
    out
  end
end
