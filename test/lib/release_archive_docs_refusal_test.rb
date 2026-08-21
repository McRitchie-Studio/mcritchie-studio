# frozen_string_literal: true

# [integration] Does `bin/release archive` HONOUR bin/archive-docs' refusal?
#
# PR #981 taught bin/archive-docs to exit 1 when the delete-later ledger has lost a
# resolved row. That refusal was INERT through the only caller that matters: sweep_docs
# returns `[out, status.success?]` and BOTH call sites took `.first`, dropping the
# boolean on the floor. So the warning printed, the beat carried on, and
# commit_artifact_to_release git-added the ledger plus its archive and pushed them to
# `release` — committing the exact loss archive-docs had just refused.
#
# WHY THIS TEST DRIVES bin/release AND NOT bin/archive-docs. The sub-command already
# refused correctly; test/lib/archive_docs_cli_test.rb pins that and would have stayed
# green through the whole defect. The bug lived entirely in the CALLER's handling of the
# verdict, so a test that re-checks the sub-command's exit code proves nothing about it.
# This spawns the REAL bin/release.rb, calls its REAL `archive` entrypoint, and lets its
# REAL sweep_docs cross a REAL Open3 process boundary. The only thing faked is what the
# child process DOES — which is precisely the variable under test.
#
# Run directly:  ruby -Itest test/lib/release_archive_docs_refusal_test.rb
#
# It lives outside test/lib/release_cli_test.rb deliberately: that file is a frozen
# hotspot in config/test_health.yml (7364 lines, 26 of the last 200 merged PRs), and the
# ratchet's remedy for "I need to add something" is a new named home, not an append.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class ReleaseArchiveDocsRefusalTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The marker the commit spy prints. `bin/release archive` reaching this line is the
  # damage: it is where the lost ledger becomes a commit on `release`.
  COMMITTED = "SPY-COMMIT-ARTIFACT-REACHED"

  # bin/release's three sweep helpers each spawn a CWD-RELATIVE command
  # (`bin/archive-docs`, `bin/agent-worktree`, `bin/clean-artifacts`). Running the CLI
  # from a scratch dir that carries its own `bin/` is what lets the real Open3 boundary
  # run while the child's behaviour stays under the test's control.
  #
  # `archive_docs_exit` is the whole experiment: 0 = the sweep is happy, 1 = it refuses.
  # The stub mirrors the real contract exactly — a --dry-run PREVIEW reports and exits 0
  # even when rows are lost (a preview that failed would wedge the callers that preview
  # before confirming), and only an APPLY refuses.
  def with_stub_bin(archive_docs_exit:, dry_run_exit: 0)
    Dir.mktmpdir("release-archive-refusal") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))

      write_stub(dir, "archive-docs", <<~SH)
        for arg in "$@"; do
          if [ "$arg" = "--dry-run" ]; then
            echo "==> Archiving frozen doc snapshots (dry-run — nothing will change)"
            echo 'archive-docs-summary: {"moved":0,"ledger_rolled":0,"moved_paths":[]}'
            exit #{dry_run_exit}
          fi
        done
        if [ "#{archive_docs_exit}" -ne 0 ]; then
          echo "==> DELETE-LATER LEDGER: rows destroyed (already lost before this sweep ran)" >&2
          echo "delete-later ledger: 2 resolved row(s) DESTROYED against HEAD." >&2
          exit #{archive_docs_exit}
        fi
        echo 'archive-docs-summary: {"moved":0,"ledger_rolled":0,"moved_paths":[]}'
        exit 0
      SH

      write_stub(dir, "agent-worktree", %(echo "reclaimed 0 worktree(s)"\nexit 0))
      write_stub(dir, "clean-artifacts", %(exit 0))

      yield dir
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, "bin", name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  # Everything bin/release's `archive` reaches that is NOT the doc sweep. `conductor` is
  # the board (Rails + a dyno); commit_artifact_to_release is the git write whose
  # NON-execution is the assertion. Both are replaced after `load`, so the production
  # script grows no test-only seam.
  STUBS = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "archivable" => [], "kept" => [] } if ruby.include?("archivable_completed_slugs")
      { "archived" => [], "kept" => [], "count" => 0 }
    end

    def commit_artifact_to_release(*)
      puts(#{COMMITTED.inspect})
    end
  RUBY

  # Spawn the REAL CLI: argv is set before `load` (DRY/PROD/ASSUME_YES are read from ARGV
  # at load time), the stubs are injected after, then the real entrypoint is called.
  # Returns [combined output, exit status]. Unlike the release_cli_test helper this does
  # NOT assert success — a refusal exiting non-zero is the expected result here.
  def run_archive(dir, argv: ["archive", "--yes", "--local"])
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{STUBS}; archive)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "ruby", "-e", script, chdir: dir)
    ["#{out}\n#{err}", status]
  end

  # --- the regression -------------------------------------------------------

  # [integration] THE BUG. archive-docs refuses the apply; `bin/release archive` must
  # stop, and must stop BEFORE the artifact commit. Against the pre-fix CLI this test
  # fails on both counts: the status is 0 and the commit spy has already printed.
  def test_release_archive_halts_when_archive_docs_refuses_the_apply
    with_stub_bin(archive_docs_exit: 1) do |dir|
      out, status = run_archive(dir)

      refute_predicate status, :success?,
                       "bin/release archive must EXIT NON-ZERO when archive-docs refuses — " \
                       "otherwise the refusal is a warning the beat walks past:\n#{out}"
      assert_includes out, "DELETE-LATER LEDGER",
                       "the refusal the child printed must reach the operator:\n#{out}"
      refute_includes out, COMMITTED,
                       "commit_artifact_to_release MUST NOT run — this is the line that " \
                       "commits the destroyed ledger to `release` and makes the loss " \
                       "permanent:\n#{out}"
    end
  end

  # [integration] THE CONTROL, and it is not optional: a guard that aborts unconditionally
  # would pass the test above while breaking every real archive run. With the same harness
  # and the sweep exiting 0, the beat must run THROUGH to the artifact commit.
  def test_release_archive_still_commits_when_the_sweep_is_clean
    with_stub_bin(archive_docs_exit: 0) do |dir|
      out, status = run_archive(dir)

      assert_predicate status, :success?, "a clean sweep must not abort the archive beat:\n#{out}"
      assert_includes out, COMMITTED,
                       "a clean sweep must still reach commit_artifact_to_release:\n#{out}"
    end
  end

  # [integration] The PREVIEW call site (the other `.first`). A failing preview must stop
  # the beat too — and it must stop BEFORE the confirm, while nothing has been mutated.
  # This cannot be reached by the ledger-loss path (a dry run reports and exits 0 on
  # purpose), so it fires only when the sweep tool itself is broken — exactly when
  # confirming a sweep you could not preview is worst.
  def test_release_archive_halts_when_the_docs_preview_fails
    with_stub_bin(archive_docs_exit: 0, dry_run_exit: 1) do |dir|
      out, status = run_archive(dir)

      refute_predicate status, :success?, "a failed docs PREVIEW must halt the beat:\n#{out}"
      refute_includes out, COMMITTED, "nothing may be committed after a failed preview:\n#{out}"
    end
  end

  # [integration] The dry-run contract stays intact: `bin/release archive --dry-run` walks
  # the previews and exits 0. The fix must not turn the preview into a wedge for the
  # pipeline callers that preview before confirming.
  def test_dry_run_archive_still_previews_and_exits_zero
    with_stub_bin(archive_docs_exit: 1) do |dir|
      out, status = run_archive(dir, argv: ["archive", "--dry-run", "--local"])

      assert_predicate status, :success?, "--dry-run must still exit 0:\n#{out}"
      assert_includes out, "DRY RUN", "the dry run must still print its plan:\n#{out}"
      refute_includes out, COMMITTED, "--dry-run must never commit:\n#{out}"
    end
  end
end
