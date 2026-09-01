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
#   2026-08-31  bin/release.rb                `prepare --yes --help` PROMOTED FOR REAL
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
  #   :subcommand    — dispatches on a subcommand and falls through to usage FOR
  #                    THE BARE FORM ONLY. Read that narrowly: it asserts what
  #                    `bin/foo --help` does and NOTHING about `bin/foo <cmd>
  #                    --help`, because a dispatcher that shifts the subcommand
  #                    and never validates the REST is the same defect one
  #                    position over. bin/release carried this label under the old
  #                    wording — "falls through to usage", full stop — while
  #                    `bin/release prepare --yes --help` promoted `accepted` onto
  #                    `release` across every repo and deployed QA. The label was
  #                    true and the reader's conclusion was false, which is the
  #                    worst thing a safety record can be.
  #   :subcommand_gap — that shape, CONFIRMED reachable: a subcommand-position
  #                    argument is dropped onto a durable mutation. Each entry
  #                    carries the exact probe an operator would type and the task
  #                    filed to fix it. A gap you can reproduce is not a shrug.
  #   :delegates     — a binstub; the underlying tool owns --help.
  #   :accepted_gap  — a KNOWN gap, deliberately not fixed here, with the reason.
  #                    Every entry is a filed obligation, not a shrug.
  MANIFEST = {
    # --- retrofitted onto the shared guard, 2026-08-31 ------------------------
    "archive-docs"           => :cli_arg_guard,
    # --- retrofitted 2026-08-31, /tasks/release-subcommand-drops-help ---------
    # The release machinery, and the sharpest instance the class has produced:
    # the side effect is not a local file but shared branch state in every repo,
    # a production board write, and (on `ship`) a RubyGems publish, whose version
    # can never be re-pushed. Its per-subcommand dictionary is
    # Release::Cli::COMMANDS.
    "release.rb"             => :cli_arg_guard,
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
    # --- subcommand dispatch that falls through to usage (BARE form) ----------
    #
    # Read the legend above before trusting this bucket: it says what the BARE
    # probe does and nothing about `<cmd> --help`. The six entries that were
    # measured to drop a subcommand-position argument onto a mutation now sit in
    # :subcommand_gap below.
    #
    # KNOWN DILUTION, filed rather than silently re-sorted. Nine of the entries
    # below are not subcommand dispatchers at all — ci-shard, op-reads,
    # measure-test-timings, gh-auth-refresh, gh-token, prod-smoke,
    # e2e-executed-set-check, rails-executed-set-check and secret are single-level
    # flag loops, most with an explicit unknown-argument refusal, i.e. closer to
    # :own_guard. They are safe, so re-sorting them is cosmetic — but a bucket
    # holding two different shapes is exactly what let six real gaps sit here
    # looking classified. Re-judge them in the next sweep, from this written set
    # rather than by rediscovering it.
    "qa-server"              => :subcommand,
    "conductor"              => :subcommand,
    "triage"                 => :subcommand,
    "agent-marker"           => :subcommand,
    "codex-update"           => :subcommand,
    "session-kickoff"        => :subcommand,
    "gate"                   => :subcommand,
    "secret"                 => :subcommand,
    "ci-shard"               => :subcommand,
    "op-reads"               => :subcommand,
    "measure-test-timings"   => :subcommand,
    "gh-auth-refresh"        => :subcommand,
    "gh-token"               => :subcommand,
    "prod-smoke"             => :subcommand,
    "e2e-executed-set-check" => :subcommand,
    "rails-executed-set-check" => :subcommand,
    # --- binstubs -------------------------------------------------------------
    "release"                => :delegates, # sh binstub: execs bin/release.rb, which owns --help
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
    # --- CONFIRMED subcommand-position gaps, each with a filed task -----------
    #
    # Found by the sweep that shipped the bin/release fix
    # (/tasks/release-subcommand-drops-help, 2026-08-31) and verified line by line
    # at source, not inferred. Every one dispatches on a subcommand and then drops
    # whatever is left, so the probe named on each entry RUNS THE REAL ACTION.
    # They are not fixed here on purpose: this change already touches the release
    # machinery, and four more scripts in one PR is how a safety fix becomes
    # unreviewable. They are recorded HERE rather than only on the board so a
    # reader of the manifest cannot conclude, as one just did about bin/release,
    # that a `:subcommand` label means the command is safe to probe.
    "agent-worktree"         => :subcommand_gap, # `new <app> <task> --help` creates the worktree, port, Redis DB and Postgres DB — /tasks/worktree-subcommand-drops-help
    "atomic-event"           => :subcommand_gap, # `grade 42 --disposition good --help` POSTs the grade — /tasks/atomic-event-help-mutates
    "agent-activity"         => :subcommand_gap, # 8-line shim over bin/atomic-event; `close-open --help` closes every activity — /tasks/atomic-event-help-mutates
    "install-agent-docs"     => :subcommand_gap, # `install --help` publishes AGENTS.md/CLAUDE.md/skills and rewrites ~/.claude/settings.json + ~/.zprofile — /tasks/docs-installer-help-publishes
    "agent-runtime"          => :subcommand_gap, # `install --help` execs the installer above with the flag intact — /tasks/docs-installer-help-publishes
    "gh-app-git-credential"  => :subcommand_gap, # `get --help` mints a live installation token and writes it to .agents/github-tokens.json — /tasks/credential-helper-help-mints

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
    "reap-cert-databases" => "CertDatabaseReaper.reap!",
    # Not a single call but the DISPATCHER: every mutation bin/release can perform
    # — promote, merge, board write, prod deploy, gem publish — is reached through
    # `case ARGV.shift`, so that line is the seam the guard has to precede. The
    # guard's own verdict is proven behaviourally in
    # test/integration/release_argv_guard_test.rb, which never runs a mutating
    # subcommand.
    "release.rb"          => "case ARGV.shift"
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

  # A CONFIRMED gap is worth less than nothing if the next reader cannot reproduce
  # it: an unreproducible warning gets re-litigated, then quietly dropped. So each
  # entry must carry BOTH the exact probe an operator would type — the thing that
  # turns "I think this is unsafe" into a two-second demonstration — and the task
  # that owns the fix, so the manifest never becomes the only place the obligation
  # lives.
  def test_every_subcommand_gap_carries_a_probe_and_a_filed_task
    section = File.read(__FILE__)[/CONFIRMED subcommand-position gaps.*?known gaps, filed rather/m]
    refute_nil section, "the :subcommand_gap block moved — re-anchor this test"

    MANIFEST.select { |_, kind| kind == :subcommand_gap }.each_key do |name|
      entry = section[/"#{Regexp.escape(name)}"\s*=> :subcommand_gap,\s*#(.+)/, 1].to_s

      assert_match(/`bin\/#{Regexp.escape(name)} [^`]+--help`|`[^`]*--help`/, entry,
                   "the :subcommand_gap entry for bin/#{name} must quote the probe that mutates — " \
                   "a gap nobody can reproduce is a gap nobody will fix")
      assert_match(%r{/tasks/[a-z0-9-]+}, entry,
                   "…and name the task that owns it, so the manifest is a pointer and not the ledger")
    end
  end

  # The two subcommand buckets answer opposite questions, so an entry in both — or
  # a gap quietly demoted back to :subcommand — would put two truths on one screen.
  def test_the_two_subcommand_buckets_are_disjoint
    plain = MANIFEST.select { |_, k| k == :subcommand }.keys
    gaps  = MANIFEST.select { |_, k| k == :subcommand_gap }.keys

    assert_empty plain & gaps
    refute_empty gaps, "the confirmed-gap bucket emptied without the scripts being fixed — if they " \
                       "were fixed, reclassify them; do not delete the record"
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
