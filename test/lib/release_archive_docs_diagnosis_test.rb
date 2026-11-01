# frozen_string_literal: true

# [integration] When the doc sweep fails, does `bin/release archive` report what ACTUALLY
# failed? The report is pure and unit-tested in test/lib/docs_archive_failure_report_test.rb.
# The question HERE is whether the caller hands it the child's real stderr, so this spawns the
# REAL bin/release.rb and lets its REAL sweep_docs cross a REAL Open3 boundary.
# test/lib/release_archive_docs_refusal_test.rb pins that the refusal is HONOURED (the beat
# halts before the artifact commit); this one pins that the halt is EXPLAINED honestly.
# History: task archive-error-blames-ledger.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class ReleaseArchiveDocsDiagnosisTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  COMMITTED = "SPY-COMMIT-ARTIFACT-REACHED"

  # THE CHILD'S FAILURE. This is the real 2026-09-01 crash: DocsArchive.git raising
  # CommandFailed out of apply_moves! because `git mv`'s destination already existed.
  CRASH_LINE = "bin/lib/docs_archive.rb:267:in 'DocsArchive.git': git mv " \
               "docs/agents/maintenance/open-pr-decisions-2026-08-26.md " \
               "docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md: " \
               "fatal: destination exists (DocsArchive::CommandFailed)"

  SUMMARY = %(archive-docs-summary: {"moved":1,"moved_paths":["docs/agents/audits/frozen-1.md"]})

  # `dir` holds the cwd-relative bin/ stubs (bin/release spawns `bin/archive-docs` and
  # friends relative to the working directory) and the hub checkout PROJECTS_DIR resolves.
  def with_fixture(archive_docs_exit: 1, dry_run_exit: 0)
    Dir.mktmpdir("release-archive-diagnosis") do |dir|
      write_stubs(dir, archive_docs_exit: archive_docs_exit, dry_run_exit: dry_run_exit)
      FileUtils.mkdir_p(File.join(dir, "mcritchie-studio"))
      yield dir
    end
  end

  def write_stubs(dir, archive_docs_exit:, dry_run_exit:)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    write_stub(dir, "archive-docs", <<~SH)
      for arg in "$@"; do
        if [ "$arg" = "--dry-run" ]; then
          if [ "#{dry_run_exit}" -ne 0 ]; then
            echo "#{CRASH_LINE}" >&2
            exit #{dry_run_exit}
          fi
          echo '#{SUMMARY}'
          exit 0
        fi
      done
      if [ "#{archive_docs_exit}" -ne 0 ]; then
        echo "#{CRASH_LINE}" >&2
        echo "	from bin/lib/docs_archive.rb:118:in 'block in apply_moves!'" >&2
        exit #{archive_docs_exit}
      fi
      echo '#{SUMMARY}'
      exit 0
    SH
    write_stub(dir, "agent-worktree", %(echo "reclaimed 0 worktree(s)"\nexit 0))
    write_stub(dir, "clean-artifacts", %(exit 0))
  end

  def write_stub(dir, name, body)
    path = File.join(dir, "bin", name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  # The board and the git write, replaced AFTER `load` so the production script grows no
  # test-only seam.
  STUBS = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "archivable" => [], "kept" => [] } if ruby.include?("archivable_completed_slugs")
      { "archived" => [], "kept" => [], "count" => 0 }
    end

    def commit_artifact_to_accepted(*)
      puts(#{COMMITTED.inspect})
    end
  RUBY

  def run_archive(dir, argv: ["archive", "--yes", "--local"])
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{STUBS}; archive)
    env = SessionEnv.neutralized("PROJECTS_DIR" => dir)
    out, err, status = Open3.capture3(env, "ruby", "-e", script, chdir: dir)
    ["#{out}\n#{err}", status]
  end

  # THE REPORT ITSELF, sliced out of the run's combined streams, and this narrowing is
  # load-bearing. sweep_docs also ECHOES the child's stderr (`warn(err)`), so "the crash
  # text appears somewhere in the output" stays true if the report stops quoting stderr
  # entirely. `abort` writes last, so everything from the lead line on IS the report.
  LEAD = "docs archive FAILED"

  def report_in(out)
    index = out.index(LEAD)
    index ? out[index..] : ""
  end

  # [integration] THE BUG, end to end. The sweep crashes on a `git mv`: the beat must halt
  # and name the crash.
  def test_a_crash_reports_its_own_cause
    with_fixture do |dir|
      out, status = run_archive(dir)
      report = report_in(out)

      refute_predicate status, :success?, "a failing sweep must still halt the beat:\n#{out}"
      refute_includes out, COMMITTED, "nothing may be committed after a failed sweep:\n#{out}"

      assert_includes report, "fatal: destination exists", "the MESSAGE must name the real cause:\n#{out}"
      assert_includes report, "DocsArchive::CommandFailed", "the mechanism must be named:\n#{out}"
      assert_match(/command:\s+bin\/archive-docs --repo=/, report, "the command must be quoted:\n#{out}")
      assert_match(/exit status:\s+1/, report, "its exit status must be reported:\n#{out}")
    end
  end

  # [integration] THE CONTROL: a report that raised while rendering, or a guard that aborted
  # unconditionally, would pass the test above and break every real archive run.
  def test_clean_sweep_still_reaches_the_artifact_commit
    with_fixture(archive_docs_exit: 0) do |dir|
      out, status = run_archive(dir)

      assert_predicate status, :success?, "a clean sweep must not abort the archive beat:\n#{out}"
      assert_includes out, COMMITTED, "a clean sweep must still commit the artifact:\n#{out}"
      refute_includes out, LEAD, "a clean sweep must report no failure:\n#{out}"
    end
  end

  # [integration] The PREVIEW call site owns the same message family.
  def test_failing_preview_names_its_cause
    with_fixture(archive_docs_exit: 0, dry_run_exit: 1) do |dir|
      out, status = run_archive(dir)
      report = report_in(out)

      refute_predicate status, :success?, "a failed docs PREVIEW must halt the beat:\n#{out}"
      refute_includes out, COMMITTED, "nothing may be committed after a failed preview:\n#{out}"
      assert_includes report, "fatal: destination exists", "the preview's real cause must be named:\n#{out}"
      assert_includes report, "Nothing has been archived, reclaimed, or swept",
                      "the preview's consequence line must survive:\n#{out}"
    end
  end
end
