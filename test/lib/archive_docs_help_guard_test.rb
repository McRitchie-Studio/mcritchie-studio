# frozen_string_literal: true

# [integration] `bin/archive-docs --help` must MUTATE NOTHING.
#
# THE DEFECT, observed in production 2026-08-31. Steffon probed an unfamiliar
# command for its usage. `bin/archive-docs --help` was not a help flag: the script
# read four exact spellings out of ARGV (`--dry-run`, `--json`, `--repo=`,
# `--ledger-cutoff=`) and had no notion of an argument it did not recognize, so
# `--help` matched nothing, was silently dropped, and the script ran a REAL archive
# roll. It rewrote docs/agents/maintenance/delete-later.md by -41 lines and staged a
# second file. The ledger is append-only audit product with no reflog behind it; only
# his copy-first habit kept the rows he was mid-rescue on.
#
# WHY THIS FILE SPAWNS A REAL PROCESS AGAINST A REAL GIT REPO. The property under
# test is "the working tree and the index are byte-identical afterwards". That is not
# assertable in the unit tier — it is a statement about what a process did to a disk,
# and the parser it depends on is the thing that was wrong.
#
# WHY THE FIXTURE CARRIES ITS OWN bin/. The operator typed a BARE `bin/archive-docs
# --help`, with no `--repo`, and that is the invocation that has to be proven safe.
# With no `--repo`, this script sweeps THE CHECKOUT IT SHIPS IN — so a bare run
# driven from the real bin/ would sweep the developer's own worktree if the guard
# ever regressed. Copying bin/ into the fixture makes the fixture that checkout, so
# the dangerous invocation is exercised for real with the blast radius inside
# mktmpdir. config/test_health.yml records what the alternative costs: two tests that
# under-stubbed this beat once ran bin/archive-docs FOR REAL against a developer's
# machine and left a `git mv` in the primary checkout that the next run died on.
#
# THE CONTROL IS THE POINT (test_control_*). A tree-identical assertion passes
# trivially against a fixture the sweep would never have touched — it would pass on
# the DEFECT too, and prove nothing. So the same fixture, byte for byte, is also run
# WITHOUT the help flag and asserted to change. That is what establishes this fixture
# can express the bug, and therefore that the help assertions bite.
#
#   ruby -Itest test/lib/archive_docs_help_guard_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "open3"

class ArchiveDocsHelpGuardTest < Minitest::Test
  REAL_BIN = File.expand_path("../../bin", __dir__)

  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    assert status.success?, "git #{args.join(' ')} failed:\n#{out}"
    out
  end

  def write(repo, rel, content)
    path = File.join(repo, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # A fixture repo that IS a checkout of this script: it carries its own bin/, so a
  # bare (no --repo) run resolves its repo root to the fixture and never to the
  # developer's tree.
  def with_repo
    Dir.mktmpdir("archive-docs-help") do |repo|
      git(repo, "init", "--quiet", ".")
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Test")

      FileUtils.mkdir_p(File.join(repo, "bin/lib"))
      FileUtils.cp(File.join(REAL_BIN, "archive-docs"), File.join(repo, "bin/archive-docs"))
      FileUtils.chmod(0o755, File.join(repo, "bin/archive-docs"))
      Dir.glob(File.join(REAL_BIN, "lib", "*.rb")).each do |lib|
        FileUtils.cp(lib, File.join(repo, "bin/lib", File.basename(lib)))
      end

      # An unreferenced dated snapshot: the sweep's move candidate.
      write(repo, "docs/agents/audits/frozen-2026-05-01.md", "frozen snapshot\n")
      # A live undated doc, which must survive either way.
      write(repo, "docs/agents/maintenance/parking-lot.md", "live\n")
      write(repo, "docs/agents/maintenance/delete-later.md", ledger)
      git(repo, "add", "-A")
      git(repo, "commit", "--quiet", "-m", "fixture")

      # DIRTY ON PURPOSE, the way the real tree was. The incident happened while the
      # ledger carried uncommitted rows from that day's reclaim — content that exists
      # in no commit, so a rewrite over it is unrecoverable. An APPENDED row is the
      # honest shape: LedgerGuard refuses a tree that LOST a dated row, so appending
      # keeps the guard green and lets the control run reach the mutation.
      File.write(File.join(repo, "docs/agents/maintenance/delete-later.md"),
                 File.read(File.join(repo, "docs/agents/maintenance/delete-later.md")) +
                 "| `/uncommitted/today` | worktree | today's reclaim | done | removed 2026-08-31 |\n")
      write(repo, "docs/agents/maintenance/scratch-notes.md", "untracked working notes\n")

      yield repo
    end
  end

  def ledger
    <<~MD
      # Delete Later Ledger

      | Path | Type | Why it is a candidate | Safe-delete condition | Status |
      |------|------|-----------------------|-----------------------|--------|
      | `/old/one` | worktree | old | done | removed 2026-06-13 |
      | `/new/two` | worktree | recent | done | removed 2026-07-14 |
      | `/unresolved/three` | worktree | waiting | needs approval | pending approval |
    MD
  end

  # --- the fingerprint -------------------------------------------------------
  #
  # Two halves, because the incident damaged both: it REWROTE a file (working tree)
  # and it STAGED a second one (index). A check on only one would have missed half.

  # Every byte of every file outside .git, plus its executable bit and path.
  # Untracked files included deliberately — the sweep's damage does not respect the
  # tracked/untracked line, and untracked content is the least recoverable of all.
  def tree_fingerprint(repo)
    Dir.glob(File.join(repo, "**", "*"), File::FNM_DOTMATCH)
       .reject { |p| p.include?("/.git/") || p.end_with?("/.git") }
       .select { |p| File.file?(p) }
       .sort
       .map do |p|
         rel = p.delete_prefix("#{repo}/")
         mode = File.stat(p).mode & 0o111 == 0 ? "rw" : "rx"
         "#{rel}\t#{mode}\t#{Digest::SHA256.file(p).hexdigest}"
       end.join("\n")
  end

  # Mode, blob sha, stage and path for every index entry — the index's content,
  # without the stat noise that a mere refresh would perturb.
  def index_fingerprint(repo)
    git(repo, "ls-files", "--stage")
  end

  def fingerprint(repo)
    { tree: tree_fingerprint(repo), index: index_fingerprint(repo) }
  end

  def run_cli(repo, *flags)
    Open3.capture3(RbConfig.ruby, File.join(repo, "bin/archive-docs"), *flags, chdir: repo)
  end

  # --- the guard -------------------------------------------------------------

  def test_bare_help_prints_usage_and_mutates_nothing
    with_repo do |repo|
      before = fingerprint(repo)

      out, err, status = run_cli(repo, "--help")

      assert_equal 0, status.exitstatus, "an explicit --help is a successful request:\n#{out}#{err}"
      assert_includes out, "usage: bin/archive-docs", "it must actually answer the question"
      assert_includes out, "SWEEPS NOTHING", "…and say plainly that it did not act"

      after = fingerprint(repo)
      assert_equal before[:tree], after[:tree], "--help must leave the working tree BYTE-IDENTICAL"
      assert_equal before[:index], after[:index], "--help must leave the index BYTE-IDENTICAL"
      refute_includes "#{out}#{err}", "archive-docs-summary:",
                      "it must never emit a sweep summary — that line is a caller's evidence a sweep ran"
    end
  end

  def test_short_h_is_the_same_probe
    with_repo do |repo|
      before = fingerprint(repo)

      out, _err, status = run_cli(repo, "-h")

      assert_equal 0, status.exitstatus
      assert_includes out, "usage: bin/archive-docs"
      assert_equal before, fingerprint(repo), "-h must be as safe as --help"
    end
  end

  # From ANY position. A parser that only inspects ARGV[0] hands the mutation to the
  # second spelling, and `--repo=… --help` is the natural way to ask "what else does
  # this take?" once you have already typed half the line.
  def test_help_after_other_flags_still_refuses_to_act
    with_repo do |repo|
      before = fingerprint(repo)

      out, _err, status = run_cli(repo, "--repo=#{repo}", "--help")

      assert_equal 0, status.exitstatus
      assert_includes out, "usage: bin/archive-docs"
      assert_equal before, fingerprint(repo), "--help anywhere on the line must mutate nothing"
    end
  end

  # The generalisation, and the reason this is a class fix rather than a spelling
  # fix. `--help` was only the spelling that got caught; ANY token this script cannot
  # account for used to fall through to the roll the same way.
  def test_an_unrecognized_flag_refuses_instead_of_sweeping
    with_repo do |repo|
      before = fingerprint(repo)

      out, err, status = run_cli(repo, "--dry-runn")

      refute_equal 0, status.exitstatus, "an unaccounted-for argument must REFUSE, not guess"
      assert_includes err, "unrecognized", "the refusal names what it could not account for"
      assert_includes err, "--dry-runn"
      assert_includes err, "NOTHING was archived", "…and what the caller is left with"
      assert_equal before, fingerprint(repo), "a refusal must mutate nothing"
      refute_includes "#{out}#{err}", "archive-docs-summary:"
    end
  end

  # A typo'd `--dry-run` is the dangerous instance: the caller believes they asked for
  # a PREVIEW and the old parser gave them a live sweep.
  def test_a_typoed_dry_run_does_not_silently_become_a_live_sweep
    with_repo do |repo|
      before = fingerprint(repo)

      _out, _err, status = run_cli(repo, "--dryrun")

      refute_equal 0, status.exitstatus
      assert_equal before, fingerprint(repo),
                   "a misspelled --dry-run must never be honoured as a real run"
    end
  end

  # A value flag with nothing to consume is a usage error, not a boolean. Storing
  # `true` here is how devops-shift once labelled a shift after a holder called "true".
  def test_a_value_flag_with_no_value_refuses
    with_repo do |repo|
      before = fingerprint(repo)

      _out, err, status = run_cli(repo, "--ledger-cutoff")

      refute_equal 0, status.exitstatus
      assert_includes err, "--ledger-cutoff"
      assert_equal before, fingerprint(repo)
    end
  end

  # --- THE CONTROLS ----------------------------------------------------------
  #
  # Without these the assertions above are unfalsifiable: a fixture the sweep would
  # never have touched satisfies "byte-identical" on the DEFECT as readily as on the
  # fix. These establish that this exact fixture, run this exact way, DOES mutate.

  def test_control_the_same_fixture_really_does_mutate_without_the_flag
    with_repo do |repo|
      before = fingerprint(repo)

      out, err, status = run_cli(repo)

      assert_equal 0, status.exitstatus, "the control run must succeed:\n#{out}#{err}"
      after = fingerprint(repo)
      refute_equal before[:tree], after[:tree],
                   "CONTROL FAILED: this fixture never reaches the mutation, so the " \
                   "byte-identical assertions above prove nothing"
      refute_equal before[:index], after[:index],
                   "CONTROL FAILED: the sweep must stage something in this fixture"
    end
  end

  # And specifically the two damages the incident caused, so the controls track the
  # real failure rather than merely "something changed".
  def test_control_the_mutation_is_the_one_the_incident_caused
    with_repo do |repo|
      ledger_path = File.join(repo, "docs/agents/maintenance/delete-later.md")
      before_ledger = File.read(ledger_path)

      _out, _err, status = run_cli(repo)
      assert_equal 0, status.exitstatus

      refute_equal before_ledger, File.read(ledger_path),
                   "CONTROL: the roll rewrites the ledger — the -41 line damage"
      refute_empty git(repo, "diff", "--cached", "--name-only").strip,
                   "CONTROL: the roll STAGES files — the second half of the damage"
    end
  end

  # --- the real callers ------------------------------------------------------
  #
  # A guard that refuses everything is indistinguishable from a guard that works, and
  # the failure is silent and expensive: refuse bin/release's own line and the archive
  # beat aborts every release. So every real invocation in the ecosystem is replayed
  # here and asserted to DISPATCH, with its values intact.
  #
  # Sources: bin/release.rb sweep_docs (the only programmatic caller) and
  # docs/agents/agents/steffon/sops/archive-shipped.md (what an operator is told to type).
  REAL_ARGV = [
    [],
    ["--dry-run"],
    ["--json"],
    ["--dry-run", "--json"],
    ["--repo=REPO"],
    ["--repo=REPO", "--dry-run"],
    ["--ledger-cutoff=2026-08-09"],
    ["--repo=REPO", "--ledger-cutoff=2026-06-01", "--dry-run"]
  ].freeze

  def test_every_real_invocation_still_dispatches
    with_repo do |repo|
      REAL_ARGV.each do |argv|
        line = argv.map { |a| a.sub("REPO", repo) }
        out, err, status = run_cli(repo, *line, "--dry-run")

        assert_equal 0, status.exitstatus,
                     "a REAL invocation must not be refused: #{line.inspect}\n#{out}#{err}"
        refute_includes err, "unrecognized",
                        "the guard must not reject a line the ecosystem actually uses: #{line.inspect}"
      end
    end
  end

  # The space form must reach the same place as the `=` form. Before the guard the
  # script only ever grepped for `--repo=`, so `--repo /path` was SILENTLY IGNORED and
  # the sweep ran against its default repo — the same silent substitution as the
  # dropped flag, one seam over, and strictly worse because it mutates the wrong tree.
  def test_the_space_form_is_honoured_rather_than_silently_ignored
    with_repo do |repo|
      out, err, status = run_cli(repo, "--repo", repo, "--dry-run", "--json")

      assert_equal 0, status.exitstatus, "#{out}#{err}"
      assert_includes out, "archive-docs-summary:", "the space form must reach the sweep"
    end
  end
end
