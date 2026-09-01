# frozen_string_literal: true

# [integration] When the doc sweep fails, does `bin/release archive` report what ACTUALLY
# failed — and does it claim ledger loss only when rows genuinely fail to conserve?
#
# THE DEFECT. `bin/release archive` caught EVERY non-zero exit of bin/archive-docs and
# announced one cause: "the delete-later ledger has lost resolved row(s)". It had checked
# no such thing. On 2026-09-01, mid production deploy, it said exactly that while a
# `git mv` had crashed on an existing destination. The operator counted the rows by hand —
# delete-later.md 86 → 45 (−41), its archive 524 → 565 (+41) — perfectly conserved, 41 out
# and 41 in. A ledger-loss claim reads as DATA LOSS IN AN AUDIT TRAIL; an operator who
# believes it may start "recovering" rows that were never lost. It cost a real detour at
# the worst possible moment.
#
# WHY THIS TEST DRIVES bin/release AND NOT DocsArchive.failure_report. The report is pure
# and unit-tested in test/lib/docs_archive_failure_report_test.rb — hand it a verdict and
# it renders that verdict faithfully. The question HERE is a different one and the unit
# tier cannot ask it: does the caller MEASURE the verdict at all? A caller that kept
# inferring the verdict from the exit code would pass every unit assertion. So this
# spawns the REAL bin/release.rb, lets its REAL sweep_docs cross a REAL Open3 boundary,
# and points it at a REAL git repo whose ledger state the test controls.
#
# THE EXPERIMENT, and the reason it proves discrimination rather than string-matching:
# BOTH failing cases use the SAME child failure — byte-identical `git mv` crash stderr,
# same exit code. The ONLY variable is the fixture repo's ledger. If the verdict flips
# with it, the caller is measuring. If the caller were parroting the child, or inferring
# from the exit status, both cases would read the same and one of the two would fail.
#
# THE CONTROL IS NOT OPTIONAL. Deleting the ledger check outright would satisfy "a crash
# must not be called ledger loss" while shipping a strictly worse bug: a genuine loss
# committed to `release` in silence. test_genuine_ledger_loss_* is what stops that.
#
# Run directly:  ruby -Itest test/lib/release_archive_docs_diagnosis_test.rb
#
# Sibling file: test/lib/release_archive_docs_refusal_test.rb pins that the refusal is
# HONOURED (the beat halts before the artifact commit). This one pins that the halt is
# EXPLAINED honestly. Both properties are load-bearing and they fail independently.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class ReleaseArchiveDocsDiagnosisTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The commit spy from the sibling test, same meaning: reaching this line is where a
  # lost ledger would become permanent history on `release`.
  COMMITTED = "SPY-COMMIT-ARTIFACT-REACHED"

  LEDGER  = "docs/agents/maintenance/delete-later.md"
  ARCHIVE = "docs/agents/archive/maintenance/delete-later-archive.md"

  TABLE_HEAD = <<~MD
    | Path | Type | Why it is a candidate | Safe-delete condition | Status |
    |------|------|-----------------------|-----------------------|--------|
  MD

  # Two RESOLVED rows (dated status = immutable history) and one UNRESOLVED row (undated
  # status = an open item, which the invariant deliberately ignores).
  ALPHA = "| `/projects/desk-alpha` | worktree | merged | branch merged | removed 2026-08-20 |"
  BETA  = "| `/projects/desk-beta` | worktree | merged | branch merged | removed 2026-08-21 |"
  OPEN  = "| `/projects/desk-open` | worktree | live | none | pending approval |"

  # THE CHILD'S FAILURE, held constant across both cases. This is the real 2026-09-01
  # crash: DocsArchive.git raising CommandFailed out of apply_moves! because `git mv`'s
  # destination already existed. It says NOTHING about the ledger — so any ledger verdict
  # in the parent's report is the parent's OWN measurement, never an echo of this text.
  CRASH_LINE = "bin/lib/docs_archive.rb:267:in 'DocsArchive.git': git mv " \
               "docs/agents/maintenance/open-pr-decisions-2026-08-26.md " \
               "docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md: " \
               "fatal: destination exists (DocsArchive::CommandFailed)"

  # --- the fixture ----------------------------------------------------------

  # `dir` holds BOTH the cwd-relative bin/ stubs (bin/release spawns `bin/archive-docs`
  # and friends relative to the working directory) AND the sibling checkout the CLI
  # resolves through PROJECTS_DIR → repo_path("mcritchie-studio"). That last part is what
  # lets the test own the ledger the caller measures, instead of reading the operator's.
  #
  # `ledger:` picks the WORKING-TREE state laid over a fixed HEAD:
  #   :conserved — ALPHA moved from the ledger into the archive. The archive beat, done
  #                correctly. The union still holds every resolved row: NOT a loss.
  #   :lost      — ALPHA removed from the ledger and added to NEITHER file. A real loss.
  def with_fixture(ledger: :conserved, archive_docs_exit: 1, dry_run_exit: 0, git_repo: true)
    Dir.mktmpdir("release-archive-diagnosis") do |dir|
      write_stubs(dir, archive_docs_exit: archive_docs_exit, dry_run_exit: dry_run_exit)
      hub = File.join(dir, "mcritchie-studio")
      git_repo ? seed_hub(hub, ledger) : FileUtils.mkdir_p(hub)
      yield dir
    end
  end

  # HEAD carries ALPHA + BETA + OPEN in the ledger and an empty archive. Committing it is
  # what gives LedgerGuard a baseline to count against — the invariant is measured against
  # git history, never against another copy of the working tree.
  def seed_hub(hub, ledger)
    write_pair(hub, ledger: TABLE_HEAD + ALPHA + "\n" + BETA + "\n" + OPEN + "\n", archive: TABLE_HEAD)
    git(hub, "init", "--quiet")
    git(hub, "add", "--all")
    git(hub, "-c", "user.email=test@example.com", "-c", "user.name=Test",
        "commit", "--quiet", "-m", "seed ledger")

    case ledger
    when :conserved
      write_pair(hub, ledger: TABLE_HEAD + BETA + "\n" + OPEN + "\n", archive: TABLE_HEAD + ALPHA + "\n")
    when :lost
      write_pair(hub, ledger: TABLE_HEAD + BETA + "\n" + OPEN + "\n", archive: TABLE_HEAD)
    else raise ArgumentError, "unknown ledger state #{ledger.inspect}"
    end
  end

  def write_pair(hub, ledger:, archive:)
    [[LEDGER, ledger], [ARCHIVE, archive]].each do |rel, body|
      path = File.join(hub, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
  end

  def git(repo, *args)
    out, status = Open3.capture2e(SessionEnv.neutralized, "git", "-C", repo, *args)
    raise "git #{args.join(' ')} failed in #{repo}: #{out}" unless status.success?
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
          echo 'archive-docs-summary: {"moved":0,"ledger_rolled":0,"moved_paths":[]}'
          exit 0
        fi
      done
      if [ "#{archive_docs_exit}" -ne 0 ]; then
        echo "#{CRASH_LINE}" >&2
        echo "	from bin/lib/docs_archive.rb:118:in 'block in apply_moves!'" >&2
        exit #{archive_docs_exit}
      fi
      echo 'archive-docs-summary: {"moved":0,"ledger_rolled":0,"moved_paths":[]}'
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
  # test-only seam. Identical in purpose to the sibling test's stubs.
  STUBS = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "archivable" => [], "kept" => [] } if ruby.include?("archivable_completed_slugs")
      { "archived" => [], "kept" => [], "count" => 0 }
    end

    def commit_artifact_to_release(*)
      puts(#{COMMITTED.inspect})
    end
  RUBY

  # PROJECTS_DIR is the whole point: bin/release's `projects_root` honours it, so
  # repo_path("mcritchie-studio") resolves to the fixture hub. Without it the CLI would
  # measure the operator's real checkout and the verdict would not be the test's to set.
  def run_archive(dir, argv: ["archive", "--yes", "--local"])
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{STUBS}; archive)
    env = SessionEnv.neutralized("PROJECTS_DIR" => dir)
    out, err, status = Open3.capture3(env, "ruby", "-e", script, chdir: dir)
    ["#{out}\n#{err}", status]
  end

  # THE REPORT ITSELF, sliced out of the run's combined streams — and this narrowing is
  # load-bearing, not tidiness.
  #
  # sweep_docs also ECHOES the child's stderr (`warn(err)`) so a passing run reads as it
  # always did, and the pre-fix CLI echoed it too via capture2e. So "the crash text appears
  # somewhere in the output" was true BEFORE this fix and stays true if the report stops
  # quoting stderr entirely — an assertion on the whole run proves nothing about the
  # message. MEASURED: a mutation replacing `stderr: docs_sweep.err` with `stderr: ""`
  # SURVIVED a whole-output assertion and is KILLED by this one.
  #
  # `abort` writes last, so everything from the report's lead line to the end IS the
  # report. Returns "" when there is none, so an assertion on a passing run fails loudly
  # rather than matching nil.
  LEAD = "docs archive FAILED"

  def report_in(out)
    index = out.index(LEAD)
    index ? out[index..] : ""
  end

  # --- half one: a non-ledger failure must report ITSELF --------------------

  # [integration] THE BUG, end to end. The sweep crashes on a `git mv`; the ledger is
  # CONSERVED (ALPHA moved from the ledger into the archive — the beat working correctly).
  # The beat must halt, name the crash, and state plainly that the ledger is intact.
  #
  # Against the pre-fix CLI every ledger assertion below inverts: it printed "the
  # delete-later ledger has lost resolved row(s)" and named neither the command, the exit
  # status, nor the crash.
  def test_non_ledger_crash_reports_its_own_cause_and_clears_the_ledger
    with_fixture(ledger: :conserved) do |dir|
      out, status = run_archive(dir)
      report = report_in(out)

      refute_predicate status, :success?, "a failing sweep must still halt the beat:\n#{out}"
      refute_includes out, COMMITTED, "nothing may be committed after a failed sweep:\n#{out}"

      assert_includes report, "fatal: destination exists",
                      "ACCEPTANCE 1: the failure MESSAGE must name the REAL cause — not merely " \
                      "the run somewhere:\n#{out}"
      assert_includes report, "DocsArchive::CommandFailed",
                      "the failing mechanism must be named, not summarized away:\n#{out}"
      assert_match(/command:\s+bin\/archive-docs --repo=/, report,
                   "the command that failed must be quoted so it can be re-run:\n#{out}")
      assert_match(/exit status:\s+1/, report, "its exit status must be reported:\n#{out}")

      assert_includes report, "ledger check: INTACT",
                      "ACCEPTANCE 2: a conserved ledger must be MEASURED and reported intact:\n#{out}"
      refute_match(/ledger HAS lost|ledger has lost resolved row/i, out,
                   "THE DEFECT: a crash must never be reported as ledger loss:\n#{out}")
      refute_includes out, "Recover the row(s)",
                      "recovery instructions are what sent the operator hunting for rows " \
                      "that were never lost:\n#{out}"
    end
  end

  # [integration] The verdict must not be guessable from a broken checkout either. With no
  # git repo to measure against, the honest answer is UNKNOWN — "I could not look" is
  # neither "nothing was lost" nor "rows were lost", and collapsing it into either is this
  # same defect wearing a different hat.
  def test_unmeasurable_ledger_reports_unknown_rather_than_guessing
    with_fixture(ledger: :conserved, git_repo: false) do |dir|
      out, status = run_archive(dir)
      report = report_in(out)

      refute_predicate status, :success?, "a failing sweep must still halt the beat:\n#{out}"
      assert_includes report, "ledger check: UNKNOWN",
                      "an unrunnable conservation check must say so:\n#{out}"
      assert_includes report, "fatal: destination exists", "the real cause is still reported:\n#{out}"
      refute_includes out, "ledger check: INTACT", "'could not look' is not a clean bill of health:\n#{out}"
      refute_includes out, "ledger check: LOST", "'could not look' is not an accusation:\n#{out}"
      refute_includes out, COMMITTED, "nothing may be committed on an unknown verdict:\n#{out}"
    end
  end

  # --- half two: a GENUINE loss must still be caught ------------------------

  # [integration] THE CONTROL. Identical child failure, identical exit code, identical
  # stderr — the ONLY change is that ALPHA is now in NEITHER file. The beat must flip to
  # LOST, name the destroyed row, and carry the recovery command.
  #
  # This is what makes the pair a discrimination rather than a string match, and it is
  # what stops the real check being deleted: a caller that simply stopped claiming loss
  # would pass every assertion in the first test and fail here.
  def test_genuine_ledger_loss_is_still_caught_and_named
    with_fixture(ledger: :lost) do |dir|
      out, status = run_archive(dir)
      report = report_in(out)

      refute_predicate status, :success?, "a lost ledger must halt the beat:\n#{out}"
      refute_includes out, COMMITTED,
                      "commit_artifact_to_release MUST NOT run — this is where the loss " \
                      "becomes permanent on `release`:\n#{out}"

      assert_includes report, "ledger check: LOST",
                      "a MEASURED loss must still raise the alarm:\n#{out}"
      assert_includes report, "1 resolved row(s) recorded at HEAD",
                      "the count is what makes the claim falsifiable:\n#{out}"
      assert_includes report, "desk-alpha",
                      "the destroyed row must be named from the caller's OWN measurement — " \
                      "the child said nothing about it:\n#{out}"
      assert_includes report, "git show HEAD:#{LEDGER}",
                      "the recovery command must be present:\n#{out}"
      assert_includes report, "fatal: destination exists",
                      "a loss verdict must not swallow what actually failed:\n#{out}"
      refute_includes out, "ledger check: INTACT", "a real loss must never read as intact:\n#{out}"
    end
  end

  # --- the beat still works -------------------------------------------------

  # [integration] A guard that aborted unconditionally, or a report that raised while
  # rendering, would pass everything above and break every real archive run. With the same
  # fixture and a clean sweep the beat must run THROUGH to the artifact commit.
  def test_clean_sweep_still_reaches_the_artifact_commit
    with_fixture(ledger: :conserved, archive_docs_exit: 0) do |dir|
      out, status = run_archive(dir)

      assert_predicate status, :success?, "a clean sweep must not abort the archive beat:\n#{out}"
      assert_includes out, COMMITTED, "a clean sweep must still commit the artifact:\n#{out}"
      refute_includes out, "docs archive FAILED", "a clean sweep must report no failure:\n#{out}"
    end
  end

  # [integration] The PREVIEW call site owns the same message family. It cannot be reached
  # by a ledger loss (a dry run reports and exits 0 by design), so it must name the real
  # cause and make NO ledger claim in either direction.
  def test_failing_preview_names_its_cause_and_makes_no_ledger_claim
    with_fixture(ledger: :conserved, archive_docs_exit: 0, dry_run_exit: 1) do |dir|
      out, status = run_archive(dir)
      report = report_in(out)

      refute_predicate status, :success?, "a failed docs PREVIEW must halt the beat:\n#{out}"
      refute_includes out, COMMITTED, "nothing may be committed after a failed preview:\n#{out}"
      assert_includes report, "fatal: destination exists", "the preview's real cause must be named:\n#{out}"
      assert_includes report, "not measured",
                      "the preview does not inspect the ledger, so it must claim nothing:\n#{out}"
      assert_includes report, "Nothing has been archived, reclaimed, or swept",
                      "the preview's consequence line must survive:\n#{out}"
      refute_includes out, "ledger check: LOST", "a preview failure is never a ledger loss:\n#{out}"
    end
  end
end
