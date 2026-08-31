# frozen_string_literal: true

# [unit] EVERY script in bin/ is classified for how it handles an argument it does
# not recognize. This is the test that stops the class from recurring.
#
# THE CLASS, and its cost. A script hand-parses a few exact flag spellings and has
# no notion of an unrecognized argument, so `--help` — the universal safe probe,
# reached for precisely BECAUSE it is expected to do nothing — matches nothing, is
# silently dropped, and the script RUNS ITS REAL ACTION.
#
#   PR #974     bin/lib/review_claim_cli.rb   `--help` took a real review claim
#   PR #980     bin/lib/release_claim_cli.rb  same shape, release lane
#   (devops)    bin/devops-shift              `acquire avi --help` TOOK THE SHIFT
#   2026-08-31  bin/archive-docs              `--help` ROLLED THE DOCS LEDGER
#
# Each of those was fixed one at a time, in place, and the third was written up as
# "the third and last member of the family". It was not — a sweep on 2026-08-31
# found five more, including one that DROPS DATABASES on any argument and one that
# installs a credential into the wrong lane on a typo. The class kept costing
# because nothing enumerated it: each instance had to be discovered by an operator
# probing a command and watching it act.
#
# WHAT THIS FILE DOES ABOUT IT. It requires every executable in bin/ to be named in
# MANIFEST below with how it handles unrecognized arguments. A NEW SCRIPT FAILS
# THIS TEST until someone classifies it. That is the whole point: the next instance
# is caught by CI at the moment it is written, by an author who still has the
# context, instead of by an operator whose ledger it just rewrote.
#
# WHY THE ASSERTIONS ARE STATIC. The honest behavioural proof — "the tree and index
# are byte-identical after --help" — lives in test/lib/archive_docs_help_guard_test.rb,
# which spawns a real process against a fixture repo that carries its own bin/.
# That technique does not generalise here: to prove `bin/clean-artifacts --help`
# sweeps nothing you must be willing to run it, and if the guard has regressed it
# truncates logs and deletes caches across every repo on the machine. config/test_health.yml
# records what that costs — two under-stubbed tests once ran bin/clean-artifacts and
# bin/archive-docs FOR REAL against a developer's machine, reclaiming 32.9 MB across
# 9 repos and leaving a `git mv` in the primary checkout that the next run died on.
# So this tier asserts the guard is WIRED, and never executes a bin/ script.
#
#   ruby -Itest test/lib/bin_help_flag_class_test.rb

require "minitest/autorun"

class BinHelpFlagClassTest < Minitest::Test
  BIN = File.expand_path("../../bin", __dir__)

  # How each script accounts for an argument it does not recognize.
  #
  #   :cli_arg_guard — calls CliArgGuard.guard!; help exits without acting and an
  #                    unaccounted-for argument REFUSES. The retrofit target.
  #   :own_guard     — carries its own equivalent guard (bin/task, bin/devops-shift,
  #                    bin/ledger-guard, and the shell scripts fixed alongside them).
  #   :optparse      — OptionParser with a -h/--help arm; an unknown flag raises
  #                    OptionParser::InvalidOption, which is never rescued.
  #   :subcommand    — dispatches on a subcommand and falls through to usage.
  #   :delegates     — a binstub; the underlying tool owns --help.
  #   :accepted_gap  — a KNOWN gap, deliberately not fixed here, with the reason.
  #                    Every entry is a filed obligation, not a shrug.
  MANIFEST = {
    # --- retrofitted onto the shared guard, 2026-08-31 ------------------------
    "archive-docs"           => :cli_arg_guard,
    "clean-artifacts"        => :cli_arg_guard,
    "control-check"          => :cli_arg_guard,
    "reap-cert-databases"    => :cli_arg_guard,
    # --- shell scripts, same sweep, same defect, different idiom --------------
    "setup-1pass-token"      => :own_guard,
    "ecosystem-build"        => :own_guard,
    # --- the three prior fixes -----------------------------------------------
    "task"                   => :own_guard,
    "devops-shift"           => :own_guard,
    "ledger-guard"           => :own_guard,
    # --- OptionParser ---------------------------------------------------------
    "ship"                   => :optparse,
    "dor-check"              => :optparse,
    "fast-check"             => :optparse,
    "full-suite-check"       => :optparse,
    "pr-review"              => :optparse,
    "session-preflight"      => :optparse,
    "reviewer-select"        => :optparse,
    "qa-intake"              => :optparse,
    "devops-cycle"           => :optparse,
    "devops-tests"           => :optparse,
    "devops-reconcile"       => :optparse,
    "register-satellite"     => :optparse,
    "review-autopilot"       => :optparse,
    "verify-review-hop"      => :optparse,
    "measure-client-surface" => :optparse,
    # --- subcommand dispatch that falls through to usage ----------------------
    "agent-worktree"         => :subcommand,
    "qa-server"              => :subcommand,
    "conductor"              => :subcommand,
    "triage"                 => :subcommand,
    "agent-marker"           => :subcommand,
    "codex-update"           => :subcommand,
    "agent-runtime"          => :subcommand,
    "install-agent-docs"     => :subcommand,
    "session-kickoff"        => :subcommand,
    "release"                => :subcommand,
    "release.rb"             => :subcommand,
    "atomic-event"           => :subcommand,
    "agent-activity"         => :subcommand,
    "gate"                   => :subcommand,
    "secret"                 => :subcommand,
    "gh-app-git-credential"  => :subcommand,
    "ci-shard"               => :subcommand,
    "op-reads"               => :subcommand,
    "measure-test-timings"   => :subcommand,
    "gh-auth-refresh"        => :subcommand,
    "gh-token"               => :subcommand,
    "prod-smoke"             => :subcommand,
    "e2e-executed-set-check" => :subcommand,
    "rails-executed-set-check" => :subcommand,
    # --- binstubs -------------------------------------------------------------
    "rails"                  => :delegates,
    "rake"                   => :delegates,
    "bundle"                 => :delegates,
    "rubocop"                => :delegates,
    "brakeman"               => :delegates,
    "importmap"              => :delegates,
    "jobs"                   => :delegates,
    "dev"                    => :delegates,
    "docker-entrypoint"      => :delegates,
    "island-background"      => :delegates,
    # --- known gaps, filed rather than fixed in this change -------------------
    #
    # Each of these ignores an unrecognized argument. None of them mutates a
    # durable artifact the way the six retrofitted above do, which is why they are
    # filed rather than swept into a change that already touches a credential
    # installer and the ecosystem bootstrap. They are listed so the next sweep
    # starts from a written set instead of rediscovering them.
    "setup"                  => :accepted_gap, # Rails-generated; re-runs an idempotent bundle/db:prepare
    "statusline"             => :accepted_gap, # writes throttle markers, spawns a lease heartbeat
    "gh-app-mint-token"      => :accepted_gap, # no local write, but prints a live installation token
    "pr-status"              => :accepted_gap, # read-only gh pr view
    "ci-scope-capture"       => :accepted_gap, # best-effort telemetry POST; always exits 0
    "session-insights"       => :accepted_gap, # read-only GET
    "atomic-capture-hook"    => :accepted_gap, # stdin hook; a bare probe hits its rescue
    "codex-session-title"    => :accepted_gap  # stdin hook; exits 0 with no session id
  }.freeze

  def scripts
    Dir.children(BIN).reject { |name| name == "lib" }
       .select { |name| File.file?(File.join(BIN, name)) }
       .sort
  end

  def source(name)
    File.read(File.join(BIN, name))
  end

  # Source with whole-line comments removed.
  #
  # EVERY position assertion below runs on THIS, not on the raw file, and the two
  # are not interchangeable. These scripts carry long doctrinal headers that NAME
  # the very calls being located — bin/control-check's header explains
  # `ControlReplay.partition` at line 19, 140 lines above the call, and
  # bin/setup-1pass-token's explains `pbpaste` at line 34, 80 lines above the read.
  # Indexing the raw text finds the PROSE and concludes the guard runs after a
  # mutation that has not happened yet. A substring assertion that can match a
  # comment is asserting about documentation, not about code.
  def code_only(name)
    source(name).lines.reject { |line| line.lstrip.start_with?("#") }.join
  end

  # THE POINT OF THIS FILE. A script added to bin/ without a decision about what it
  # does with `--help` fails here, at the moment it is written.
  def test_every_bin_script_is_classified
    unclassified = scripts - MANIFEST.keys

    assert_empty unclassified,
                 "bin/ script(s) with no entry in MANIFEST: #{unclassified.join(', ')}.\n" \
                 "Decide what each does with an argument it does not recognize, then add it.\n" \
                 "If it MUTATES anything, wire bin/lib/cli_arg_guard.rb and use :cli_arg_guard — " \
                 "`--help` is the probe every operator tries first, and on this ecosystem it has " \
                 "already rolled a docs ledger, taken a shift lease, and dropped databases."
  end

  # The manifest must not outlive the scripts it names, or it becomes a list of
  # reassurances about files that no longer exist.
  def test_the_manifest_names_no_script_that_is_gone
    stale = MANIFEST.keys - scripts

    assert_empty stale, "MANIFEST names script(s) not in bin/: #{stale.join(', ')}"
  end

  # --- the wiring, asserted rather than assumed ------------------------------

  def test_every_cli_arg_guard_script_actually_calls_the_guard
    MANIFEST.select { |_, kind| kind == :cli_arg_guard }.each_key do |name|
      src = source(name)

      assert_includes src, 'require_relative "lib/cli_arg_guard"',
                      "bin/#{name} is classified :cli_arg_guard but does not require it"
      assert_includes src, "CliArgGuard.guard!",
                      "bin/#{name} requires the guard but never calls it — a required-but-uncalled " \
                      "guard is exactly the shape of an inert fix"
    end
  end

  # A guard that runs AFTER the side effect protects nothing. The four retrofitted
  # Ruby scripts must call it before their first mutating call — asserted by
  # position, because "it is in the file somewhere" is not the property that matters.
  FIRST_MUTATION = {
    "archive-docs"        => "DocsArchive.roll_ledger!",
    "clean-artifacts"     => "ArtifactSweep",
    "control-check"       => "ControlReplay.partition",
    "reap-cert-databases" => "CertDatabaseReaper.reap!"
  }.freeze

  def test_the_guard_runs_before_the_first_mutation
    FIRST_MUTATION.each do |name, mutation|
      src = code_only(name)
      guard_at = src.index("CliArgGuard.guard!")
      mutation_at = src.index(mutation)

      refute_nil guard_at, "bin/#{name} never calls the guard"
      refute_nil mutation_at, "bin/#{name} no longer contains #{mutation} — update FIRST_MUTATION"
      assert_operator guard_at, :<, mutation_at,
                      "bin/#{name} calls #{mutation} BEFORE its argument guard — the guard cannot " \
                      "protect a side effect that has already happened"
    end
  end

  # reap-cert-databases boots Rails to reach its databases. A probe must not pay for
  # that boot, and more importantly must answer on a machine where the test database
  # is unreachable — so the guard sits ahead of the environment require.
  def test_reap_cert_databases_guards_before_it_boots_rails
    src = code_only("reap-cert-databases")

    assert_operator src.index("CliArgGuard.guard!"), :<, src.index("config/environment"),
                    "the guard must run before the Rails boot, so --help answers without a database"
  end

  def test_the_shell_scripts_answer_help_without_acting
    {
      "setup-1pass-token" => "INSTALLS NOTHING",
      "ecosystem-build"   => "BUILDS NOTHING"
    }.each do |name, promise|
      src = source(name)

      assert_match(/--help\|-h\)/, src, "bin/#{name} must match --help and -h explicitly")
      assert_includes src, promise, "bin/#{name}'s usage must say plainly that it did not act"
      assert_includes src, "unrecognized argument",
                      "bin/#{name} must REFUSE an argument it cannot account for, not default a lane"
    end
  end

  # The credential installer is the sharpest instance in the sweep: the LANE comes
  # from argv and the SECRET comes from the clipboard, and nothing cross-checks them.
  # Its old parser defaulted every non-`--admin` argument to the AGENT lane, so a
  # typo'd `--admin` wrote the admin token into the profile every background agent
  # shell sources. The refusal must therefore come BEFORE the lane is chosen.
  def test_the_credential_installer_refuses_before_it_picks_a_lane
    src = code_only("setup-1pass-token")

    assert_operator src.index("unrecognized argument"), :<, src.index('LANE="agent"'),
                    "an unrecognized argument must refuse BEFORE a lane is defaulted"
    assert_operator src.index("unrecognized argument"), :<, src.index("TOKEN=$(pbpaste"),
                    "…and before the clipboard secret is read"
  end

  # OptionParser answers `--help` from its OFFICIOUS default even when a script
  # declares no arm of its own (bin/devops-reconcile declares none and is still
  # safe), and it raises OptionParser::InvalidOption on an unknown flag. Both
  # properties are the parser's, so what has to be asserted is that the parser is
  # actually in the path and that its refusal is not swallowed — a rescue that
  # logs and continues would put the script right back in the defect class.
  def test_optparse_scripts_leave_the_parsers_refusal_intact
    MANIFEST.select { |_, kind| kind == :optparse }.each_key do |name|
      src = code_only(name)

      assert_includes src, "OptionParser",
                      "bin/#{name} is classified :optparse but never builds a parser"
      refute_match(/rescue\s+OptionParser::InvalidOption/, src,
                   "bin/#{name} rescues InvalidOption — an unknown flag must refuse, not be logged " \
                   "and stepped over")
    end
  end

  # An accepted gap is a filed obligation. Keeping the reason ON the entry is what
  # makes the next sweep able to re-judge it instead of rediscovering it.
  def test_every_accepted_gap_records_why
    manifest_src = File.read(__FILE__)
    section = manifest_src[/known gaps, filed rather than fixed.*?\}\.freeze/m]

    MANIFEST.select { |_, kind| kind == :accepted_gap }.each_key do |name|
      assert_match(/"#{Regexp.escape(name)}"\s*=> :accepted_gap,?\s+#.+\S/, section,
                   "the :accepted_gap entry for bin/#{name} needs a trailing comment saying why " \
                   "it was not fixed — an unexplained gap is indistinguishable from an oversight")
    end
  end
end
