# frozen_string_literal: true

# [unit] DocsArchive.failure_report: does a failing doc sweep report what ACTUALLY failed? The
# report must not announce a cause it never checked: it names the command, the exit status and
# the stderr, whatever the cause. The report is PURE: strings in, string out.
# The caller's half needs a real process boundary: test/lib/release_archive_docs_diagnosis_test.rb.
# History: task archive-error-blames-ledger.

require "minitest/autorun"
require_relative "../../bin/lib/docs_archive"

class DocsArchiveFailureReportTest < Minitest::Test
  COMMAND = "bin/archive-docs --repo=/Users/alex/projects/mcritchie-studio"

  # The REAL 2026-09-01 crash, as bin/archive-docs emitted it: DocsArchive.git raising
  # CommandFailed out of apply_moves! because `git mv`'s destination already existed.
  CRASH = <<~ERR
    bin/lib/docs_archive.rb:267:in 'DocsArchive.git': git mv docs/agents/maintenance/open-pr-decisions-2026-08-26.md docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md: fatal: destination exists, source=docs/agents/maintenance/open-pr-decisions-2026-08-26.md, destination=docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md
     (DocsArchive::CommandFailed)
    \tfrom bin/lib/docs_archive.rb:118:in 'block in apply_moves!'
  ERR

  def report(stderr: CRASH, exit_label: "1", **rest)
    DocsArchive.failure_report(command: COMMAND, exit_label: exit_label, stderr: stderr, **rest)
  end

  # [unit] THE PROPERTY. The real cause, the command to re-run and the exit status.
  def test_a_failure_reports_its_real_cause
    out = report

    assert_includes out, "docs archive FAILED"
    assert_includes out, "fatal: destination exists", "the ACTUAL cause must appear:\n#{out}"
    assert_includes out, "DocsArchive::CommandFailed", "the exception class names the mechanism:\n#{out}"
    assert_match(/command:\s+bin\/archive-docs --repo=/, out, "the command must be quoted:\n#{out}")
    assert_match(/exit status:\s+1/, out, "the exit status must be reported:\n#{out}")
    refute_match(/ledger/i, out, "the ledger is retired, so the report has nothing to say about it:\n#{out}")
  end

  # [unit] The PREVIEW call site supplies its own consequence line.
  def test_the_callers_consequence_line_survives
    out = report(consequence: "Nothing has been archived, reclaimed, or swept.")

    assert_includes out, "Nothing has been archived", "the caller's consequence line must survive:\n#{out}"
    refute_includes out, DocsArchive::DEFAULT_CONSEQUENCE
  end

  # [unit] A sweep that dies without a word must not produce a report with a blank
  # cause — "(none)" is an answer, an empty line is a hole the reader fills in wrongly.
  def test_silent_failure_says_so_rather_than_printing_nothing
    out = report(stderr: "")

    assert_includes out, "without writing anything to stderr", "a silent sweep must be named as silent:\n#{out}"
  end

  # [unit] A signal death has no exitstatus. The caller's exit_label carries whatever it
  # has, and the report prints it rather than leaving the field blank.
  def test_exit_label_passes_through_verbatim
    out = report(exit_label: "killed by signal 9")

    assert_includes out, "killed by signal 9", "the exit label must survive to the reader:\n#{out}"
  end

  # [unit] A long backtrace is TRUNCATED, and the truncation is DECLARED.
  def test_long_stderr_is_truncated_and_the_elision_is_declared
    stderr = (1..40).map { |i| "line #{i}" }.join("\n")
    out = report(stderr: stderr)

    assert_includes out, "line 1", "the head of the trace — where the cause is — must survive:\n#{out}"
    assert_includes out, "line #{DocsArchive::STDERR_QUOTE_LINES}", "the quota must be used in full:\n#{out}"
    refute_includes out, "line 40", "the tail is elided:\n#{out}"
    assert_includes out, "more line(s)", "and the elision must be DECLARED, never silent:\n#{out}"
  end
end
