# frozen_string_literal: true

# [unit] DocsArchive.failure_report — does a failing doc sweep report what ACTUALLY
# failed, and does it claim ledger loss ONLY on a measured loss?
#
# THE DEFECT THIS PINS. `bin/release archive` announced "the delete-later ledger has
# lost resolved row(s)" for EVERY non-zero exit of bin/archive-docs, having checked no
# such thing. On 2026-09-01, mid production deploy, it said exactly that when a
# `git mv` had crashed. The operator counted the rows by hand — delete-later.md 86 → 45
# (−41), its archive 524 → 565 (+41) — and found them perfectly conserved. The message
# had diagnosed something it never looked at, and the wrong diagnosis cost a detour at
# the worst possible moment.
#
# WHAT MAKES THIS TIER THE RIGHT ONE. The report is PURE: strings in, string out, no
# git and no subprocess. So the DISCRIMINATION — the same failure reading differently
# depending only on the measured verdict — is provable here in milliseconds, with the
# verdict supplied directly rather than staged. The CALLER's half (does it measure the
# verdict at all, and does it stop before the commit?) needs a real process boundary and
# lives in test/lib/release_archive_docs_diagnosis_test.rb.
#
# BOTH HALVES ARE ASSERTED HERE, and that is deliberate. A test that only proved "a
# crash must not be called ledger loss" would stay green if the ledger claim were
# deleted outright — which would be a worse bug, silently shipped under a passing test.
#
# Run directly:  ruby -Itest test/lib/docs_archive_failure_report_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/docs_archive"

class DocsArchiveFailureReportTest < Minitest::Test
  COMMAND = "bin/archive-docs --repo=/Users/alex/projects/mcritchie-studio"

  # The REAL 2026-09-01 crash, as bin/archive-docs emitted it: DocsArchive.git raising
  # CommandFailed out of apply_moves! because `git mv`'s destination already existed.
  # Nothing in it mentions the ledger — that is the point.
  CRASH = <<~ERR
    bin/lib/docs_archive.rb:267:in 'DocsArchive.git': git mv docs/agents/maintenance/open-pr-decisions-2026-08-26.md docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md: fatal: destination exists, source=docs/agents/maintenance/open-pr-decisions-2026-08-26.md, destination=docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md
     (DocsArchive::CommandFailed)
    \tfrom bin/lib/docs_archive.rb:118:in 'block in apply_moves!'
  ERR

  # What LedgerGuard.report hands the caller for a genuine loss.
  LOSS_DETAIL = <<~MSG
    delete-later ledger: 1 resolved row(s) DESTROYED against HEAD.

      | `/projects/desk-alpha` | worktree | merged | branch merged | removed 2026-08-20 |

    Recover them: git show HEAD:docs/agents/maintenance/delete-later.md
  MSG

  def report(ledger: nil, stderr: CRASH, exit_label: "1", **rest)
    DocsArchive.failure_report(command: COMMAND, exit_label: exit_label, stderr: stderr,
                               ledger: ledger, **rest)
  end

  # --- half one: the real cause, and NO false ledger claim -------------------

  # [unit] THE BUG. A crash with the ledger measured INTACT must report the crash and
  # must not breathe a word about lost rows. Against the pre-fix message this fails on
  # every count: it named no command, no exit status, no stderr, and asserted a loss.
  def test_intact_ledger_reports_the_real_cause_and_denies_loss
    out = report(ledger: { verdict: :intact })

    assert_includes out, "ledger check: INTACT",
                    "an intact ledger must be stated as such, not left to inference:\n#{out}"
    assert_includes out, "This is NOT ledger",
                    "the report must actively clear the ledger, since that is the fear it created:\n#{out}"
    assert_includes out, "fatal: destination exists",
                    "the ACTUAL cause must appear — this is the whole acceptance:\n#{out}"
    assert_includes out, "DocsArchive::CommandFailed",
                    "the exception class names the failing mechanism:\n#{out}"
    assert_match(/command:\s+bin\/archive-docs --repo=/, out,
                 "the failing command must be quoted so it can be re-run:\n#{out}")
    assert_match(/exit status:\s+1/, out, "the exit status must be reported:\n#{out}")

    refute_includes out, "ledger check: LOST", "a conserved ledger must never read as LOST:\n#{out}"
    refute_match(/ledger HAS lost|has lost resolved row/i, out,
                 "THE DEFECT: no ledger-loss claim may survive a measured-intact verdict:\n#{out}")
    refute_includes out, "Recover the row(s)",
                    "recovery instructions under a conserved ledger are what sent the operator hunting:\n#{out}"
  end

  # [unit] The THIRD verdict, which is neither of the other two. A check that could not
  # run certifies nothing, so it must read as UNKNOWN — collapsing it into INTACT would
  # rebuild this same bug facing the other way.
  def test_unreadable_baseline_claims_neither_intact_nor_lost
    out = report(ledger: { verdict: :unreadable, detail: "`HEAD` does not resolve in /tmp/nope" })

    assert_includes out, "ledger check: UNKNOWN", "an unrunnable check must say so:\n#{out}"
    assert_includes out, "UNDETERMINED", "and must refuse to conclude either way:\n#{out}"
    assert_includes out, "does not resolve", "the reason the check could not run belongs in the report:\n#{out}"
    assert_includes out, "fatal: destination exists", "the sweep's own cause is still reported:\n#{out}"

    refute_includes out, "ledger check: INTACT", "'could not look' is not 'nothing was lost':\n#{out}"
    refute_includes out, "ledger check: LOST", "'could not look' is not 'rows were lost':\n#{out}"
  end

  # [unit] The PREVIEW call site passes no verdict at all. Silence about the ledger is
  # the honest answer there; an unmeasured ledger must not be reported as clean.
  def test_unmeasured_ledger_makes_no_claim_in_either_direction
    out = report(consequence: "Nothing has been archived, reclaimed, or swept.")

    assert_includes out, "not measured", "an unmeasured ledger must be declared unmeasured:\n#{out}"
    assert_includes out, "Nothing has been archived", "the caller's consequence line must survive:\n#{out}"
    refute_includes out, "ledger check: INTACT", "not measuring is not a clean bill of health:\n#{out}"
    refute_includes out, "ledger check: LOST", "not measuring is not an accusation either:\n#{out}"
  end

  # --- half two: a REAL loss must still be caught, loudly -------------------

  # [unit] THE CONTROL, and it is not optional. Deleting the ledger check entirely would
  # satisfy every assertion above while shipping a strictly worse bug — a real loss
  # committed to `release` in silence. A measured loss must still raise the alarm, name
  # the destroyed rows, and carry the recovery command.
  def test_measured_loss_still_raises_the_alarm_with_the_rows_and_the_recovery
    out = report(ledger: { verdict: :lost, missing: 1, detail: LOSS_DETAIL })

    assert_includes out, "ledger check: LOST", "a measured loss must be stated:\n#{out}"
    assert_includes out, "ledger HAS lost resolved row(s)",
                    "the lead sentence must still alarm when the alarm is earned:\n#{out}"
    assert_includes out, "1 resolved row(s) recorded at HEAD",
                    "the COUNT is what makes the claim falsifiable:\n#{out}"
    assert_includes out, "desk-alpha", "the destroyed row must be named so it can be recovered:\n#{out}"
    assert_includes out, "git show HEAD:docs/agents/maintenance/delete-later.md",
                    "the recovery command must be present:\n#{out}"
    assert_includes out, "permanent on `release`", "and the stake must be named:\n#{out}"

    # The two halves are one report: a real loss does NOT excuse hiding what failed.
    assert_includes out, "fatal: destination exists",
                    "a loss verdict must not swallow the underlying cause:\n#{out}"
    refute_includes out, "ledger check: INTACT", "a loss must never read as intact:\n#{out}"
  end

  # --- the report's own edges ----------------------------------------------

  # [unit] A sweep that dies without a word must not produce a report with a blank
  # cause — "(none)" is an answer, an empty line is a hole the reader fills in wrongly.
  def test_silent_failure_says_so_rather_than_printing_nothing
    out = report(ledger: { verdict: :intact }, stderr: "")

    assert_includes out, "without writing anything to stderr", "a silent sweep must be named as silent:\n#{out}"
  end

  # [unit] A signal death has no exitstatus. The caller's exit_label carries whatever it
  # has, and the report prints it rather than leaving the field blank.
  def test_exit_label_passes_through_verbatim
    out = report(ledger: { verdict: :intact }, exit_label: "killed by signal 9")

    assert_includes out, "killed by signal 9", "the exit label must survive to the reader:\n#{out}"
  end

  # [unit] A long backtrace is TRUNCATED, and the truncation is DECLARED. Dropping the
  # tail in silence would be a smaller version of the same defect: a report implying it
  # showed everything it had.
  def test_long_stderr_is_truncated_and_the_elision_is_declared
    stderr = (1..40).map { |i| "line #{i}" }.join("\n")
    out = report(ledger: { verdict: :intact }, stderr: stderr)

    assert_includes out, "line 1", "the head of the trace — where the cause is — must survive:\n#{out}"
    assert_includes out, "line #{DocsArchive::STDERR_QUOTE_LINES}", "the quota must be used in full:\n#{out}"
    refute_includes out, "line 40", "the tail is elided:\n#{out}"
    assert_includes out, "more line(s)", "and the elision must be DECLARED, never silent:\n#{out}"
  end
end
