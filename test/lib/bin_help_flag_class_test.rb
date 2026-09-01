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
    # --- retrofitted 2026-08-31, /tasks/qa-server-help-provisions -------------
    # It sat in :subcommand looking classified while `provision <app> --yes --help`
    # ran a REAL provision — heroku create, billable add-ons, domains, ACM and a
    # config-var PATCH — with the confirmation already suppressed by the --yes
    # beside it. Found by READING this manifest rather than by an operator watching
    # it act, which is the first time this class has been caught that way. Its
    # per-subcommand dictionary is QaServerCli::COMMANDS; help and refusal both exit
    # NON-ZERO because bin/release reads this script's exit status as "the QA
    # deploy succeeded".
    "qa-server"              => :cli_arg_guard,
    "control-check"          => :cli_arg_guard,
    "reap-cert-databases"    => :cli_arg_guard,
    # The harvest WRITES desk records to the board, so it is guarded like the rest of
    # the mutating flat scripts. Its help exits 1: exit 0 from it asserts "the stranded
    # rows are recorded", which a probe never established.
    "harvest-desk-ledger"    => :cli_arg_guard,
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/atomic-event-help-mutates,
    # 2026-09-01) — the LAST member of the class, and the highest-frequency one. It
    # dispatched with `command = argv.shift` inside AgentActivityCli#run and handed the
    # rest to a parse_flags with no unknown-argument arm, so an unrecognized `--token`
    # became `flags["token"] = true` and was never read. Measured at source, each of
    # these RAN FOR REAL:
    #
    #   grade 42 --disposition good --help        POSTED the grade to the production board
    #   start --category Edit --reason x --help   opened a real activity
    #   close-open --help                         closed every open activity + deleted 3 markers
    #   heartbeat avi --help                      wrote the sticky .acting-agent marker
    #
    # …and `run` swallows every StandardError while the script always exits 0, so a
    # probe that mutated reported nothing and returned SUCCESS. Its per-subcommand
    # dictionary is AgentActivityCli::COMMANDS, which lives in bin/atomic-event itself
    # rather than in bin/lib/: the parsers it must agree with are ten lines below it and
    # the file already `load`s inert under test, so a separate lib would only add a
    # second place to drift. Help exits 0 here — the opposite of bin/release,
    # bin/qa-server and bin/agent-worktree — because this CLI's 0 means only "this ran";
    # every caller discards its status. The rationale names all six callers, on
    # AgentActivityCli::HELP_EXIT.
    "atomic-event"           => :cli_arg_guard,
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/worktree-subcommand-drops-help).
    # The WIDEST surface the class has produced: TWENTY subcommands, THIRTEEN of which
    # reach a durable write — measured from the dispatcher, not estimated; the SIX
    # read-only arms are apps, list, plan, env, shell-hook and doctor. It dispatched with `cmd = ARGV.shift || "help"` and no arm
    # validated the remainder, so `bin/agent-worktree new <app> <task> --help` created a
    # REAL desk — `git worktree add -b`, a port and Redis DB written into
    # .env.agent-stack, the .agent-context.json marker, and a Postgres database from
    # prepare_test_env. The `new` arm did not merely ignore the flag: it destructured
    # `app_name, raw_task, maybe_type, *rest = ARGV` and then chose the branch type with
    # `maybe_type&.start_with?("--") ? "feat" : ...`, so `--help` was RECOGNISED as
    # flag-shaped and thrown away on purpose, while `*rest` was never inspected at all.
    # Four more arms were reachable identically — `bind-task … --help` wrote the stack
    # env and marker, `up … --help` STARTED the stack, `status … --help` wrote the
    # marker, `scale out --help` GREW the persisted Redis band — and `remove`,
    # `cleanup --reclaim`, `sweep-orphan-dbs` and `snapshot --write` were safe only
    # because each gates on an explicit --yes/--write. Safe by luck, not by design.
    #
    # Its per-subcommand dictionary is AgentWorktreeCli::COMMANDS. Help exits 1 and the
    # refusal 2, because exit 0 from this script is read as a FACT by four callers:
    # bin/task:1869 as "THE WORKTREE WAS CREATED" (begin_step! die!s on anything else),
    # bin/qa-intake:56 as "the registry was refreshed", and bin/release.rb:6999/:7047 as
    # "the primary was restored" / "the reclaim ran". A fifth reader is not a script —
    # `shell-hook zsh` is consumed as eval "$(...)" from the login shell — which is why
    # usage goes to stderr.
    #
    # ONE ARM FORWARDS, and is guarded per-arm rather than wholesale: `test <app>
    # <task> [-- rails-test-args]` hands its tail to `bin/rails test`, so it gets the
    # help scan and only the help scan. Classifying that tail would refuse `-n
    # /pattern/` and `--` itself — a top-level guard wearing a per-arm guard's clothes,
    # the mistake bin/agent-runtime's `codex-update` arm exists to avoid.
    #
    # The behavioural half — the guard proven BY RECEIPT, with a pinned `git` spy that
    # stays silent through the probe beside a control that fills it — lives in
    # test/integration/agent_worktree_argv_guard_test.rb, because a green manifest
    # cannot tell a guard that is CALLED from one merely DEFINED.
    "agent-worktree"         => :cli_arg_guard,
    # --- shell scripts, same sweep, same defect, different idiom --------------
    "setup-1pass-token"      => :own_guard,
    "ecosystem-build"        => :own_guard,
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/docs-installer-help-publishes).
    # These two were the sharpest pair in the gap bucket, because the thing they
    # publish is GLOBAL and shared. `bin/install-agent-docs install --help` read its
    # mode as `MODE="${1:-install}"`, tested $1 alone, and had no `$#` check anywhere
    # in the file — so the flag sat in $2, was discarded, and the probe copied
    # AGENTS.md + CLAUDE.md into the projects root, mirrored every skill into
    # ~/.claude/skills and ~/.codex/skills, `rm -rf`'d the retired ones, rewrote the
    # hooks in ~/.claude/settings.json, and appended to ~/.zprofile — the operator's
    # live login profile, from the command people type BECAUSE it should do nothing.
    # bin/agent-runtime was the same defect with a longer fuse: its install/repair/
    # check arms exec'd the installer with the flag intact. Exactly one of its six
    # arms (`doctor`) counted its arguments, which is what made the omission legible
    # as an omission rather than a design.
    #
    # Both now carry the shell idiom the three above use — a whole-line --help|-h
    # scan plus an explicit unrecognized-argument refusal — asserted by
    # test_the_shell_scripts_answer_help_without_acting and positioned by
    # test_the_installer_refuses_before_it_publishes. The behavioural half (a
    # sandboxed HOME/PROJECTS_DIR that stays EMPTY through the probe, with a control
    # install that fills it) lives in
    # test/commands/install_agent_docs_help_guard_test.rb, because a green manifest
    # cannot tell a guard that is CALLED from one merely DEFINED.
    #
    # NOT the shared bin/lib/cli_arg_guard.rb, and the reason is specific to these
    # two: it is Ruby, and this is the fresh-machine bootstrap that installs the
    # login-shell Ruby PATH and whose `doctor` exists to diagnose Ruby drift. An
    # argument guard that needs a working modern Ruby cannot read its own command
    # line on the machine it exists to repair.
    "install-agent-docs"     => :own_guard,
    "agent-runtime"          => :own_guard,
    # RECLASSIFIED, NOT DELETED (/tasks/credential-helper-help-mints). This was
    # :subcommand, a label claiming it "falls through to usage"; it fell through to
    # `*) exit 0` — no usage, no signal — and `get --help` ran the REAL `get`. The
    # release sweep then re-filed it as :subcommand_gap with the probe
    # `bin/gh-app-git-credential get --help`, measured to mint a live installation
    # token, write it to the shared token store, and print it. Both entries were
    # true when written; the fix landed underneath them, so the gap bucket no
    # longer holds this script and the record lives here instead.
    #
    # THE LESSON WORTH KEEPING: :subcommand carried no wiring assertion, so its
    # claim was never checked against the code for anyone. :own_guard is, by
    # test_the_shell_scripts_answer_help_without_acting below.
    "gh-app-git-credential"  => :own_guard,
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
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/atomic-event-help-mutates,
    # 2026-09-01). It carried the identical exposure — `close-open --help` closed every
    # open activity — because it is an 8-line shim that `load`s bin/atomic-event and
    # calls the SAME AgentActivityCli#run. The guard was therefore placed INSIDE `run`,
    # not under bin/atomic-event's `$PROGRAM_NAME == __FILE__` block, so ONE call guards
    # both names. This is the same relationship bin/release has to bin/release.rb above,
    # and it is the bucket's rule rather than an exception — but a label is not a test,
    # so test_the_in_repo_delegating_stubs_reach_a_guarded_script below asserts the
    # delegation, and the shim's refusal is proven by real execution with a control in
    # test/lib/atomic_event_cli_test.rb.
    "agent-activity"         => :delegates, # 8-line shim: loads bin/atomic-event, which owns --help
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
    # ⚠ THE BUCKET IS NOW EMPTY, and that is the finished state, not a missing record.
    # All FIVE entries have LEFT IT, each reclassified above with its record kept in
    # full rather than deleted — every one of them on 2026-09-01:
    #
    #   bin/install-agent-docs  :own_guard      /tasks/docs-installer-help-publishes
    #   bin/agent-runtime       :own_guard      /tasks/docs-installer-help-publishes
    #   bin/agent-worktree      :cli_arg_guard  /tasks/worktree-subcommand-drops-help
    #   bin/atomic-event        :cli_arg_guard  /tasks/atomic-event-help-mutates
    #   bin/agent-activity      :delegates      /tasks/atomic-event-help-mutates
    #
    # The last two closed the family: bin/agent-activity is an 8-line shim over
    # bin/atomic-event, so one guard placed inside AgentActivityCli#run retired both.
    #
    # The tripwire that guarded this moment has been retired DELIBERATELY. Steffon left
    # `refute_empty gaps` in test_the_two_subcommand_buckets_are_disjoint with a note
    # saying it would go red BY DESIGN on the last fix, so the record could not be
    # deleted quietly, and instructing whoever did that fix to remove the line in the
    # SAME change. That is what happened; `assert_empty plain & gaps` stays, because it
    # is still meaningful on an empty bucket. Its failure message anticipated a bucket
    # emptied by DELETION and told the reader to reclassify — which was already done, so
    # the message alone would have been misleading here. That is why the instruction
    # lived on the entries and not only in the assertion.
    #
    # THE BUCKET ITSELF STAYS, armed and empty: :subcommand_gap remains a legal
    # classification, test_every_subcommand_gap_carries_a_probe_and_a_filed_task still
    # enforces the probe + filed task on any future entry, and the section headers below
    # are what that test anchors on. The next sweep that finds a gap files it here.

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

  # A HASH LITERAL WITH ONE KEY TWICE KEEPS THE LAST, SILENTLY — so a duplicate is
  # invisible to every other test in this file, because MANIFEST.keys has already
  # collapsed it before they run. This one reads the SOURCE instead.
  #
  # MEASURED 2026-08-31. The sweep that fixed bin/release filed five more scripts as
  # :subcommand_gap, one of them bin/gh-app-git-credential. A branch fixing that
  # script reclassified it :own_guard. Both landed, git merged both hunks without a
  # conflict, and the gap entry — being LATER in the literal — won. The
  # reclassification the change existed to make was discarded, the enforced
  # shell-promise hash below still passed because it is a SEPARATE literal, and
  # nothing went red.
  #
  # That is not a one-off: four more :subcommand_gap entries are still open, each
  # with a filed task that will do exactly this to exactly this hash.
  def test_no_script_is_classified_twice
    literal = File.read(__FILE__)[/MANIFEST = \{.*?\}\.freeze/m]
    refute_nil literal, "the MANIFEST literal moved — re-anchor this test"

    names = literal.scan(/^\s*"([a-z0-9._-]+)"\s*=>/).flatten
    dupes = names.tally.select { |_, count| count > 1 }

    assert_empty dupes.keys,
                 "classified more than once in MANIFEST: #{dupes.keys.join(', ')}. Ruby keeps the " \
                 "LAST entry, so the earlier classification is silently discarded — pick one and " \
                 "carry the other's record into a comment on it."
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
    "release.rb"          => "case ARGV.shift",
    # Same reasoning as release.rb: not one call but the DISPATCHER. Every Heroku
    # and git write bin/qa-server can perform — create, addons:create, domains:add,
    # certs:auto:enable, the config-var PATCH, the QA force-push, ps:scale — is
    # reached through `case cmd`, so that line is the seam the guard has to precede.
    "qa-server"           => "case cmd",
    # Same reasoning again, and the widest surface of the three: every worktree, port,
    # Redis DB, Postgres database, branch removal and Redis-band write
    # bin/agent-worktree can perform is reached through `case cmd`.
    "agent-worktree"      => "case cmd",
    # Same reasoning once more, and the LAST of the family. Every POST and marker write
    # bin/atomic-event can perform — the activity open/close, the close_all teardown,
    # the grade, the action report, the sticky acting-agent — is reached through
    # `case command` inside AgentActivityCli#run, so that line is the seam the guard has
    # to precede. Unlike the three above, this one wraps the guard in NO helper: the
    # only occurrence of `CliArgGuard.guard!` in the file IS the call site, which is why
    # it needs no GUARD_HELPER_CALLERS entry below. Its behavioural proof is stronger
    # than a static index either way — test/lib/atomic_event_cli_test.rb runs the real
    # script against a recording stub server and asserts a POST RECEIPT, each probe
    # paired with a control that fires.
    "atomic-event"        => "case command"
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

  # The two binstubs whose TARGET lives in this same bin/, mapped to the script that
  # owns `--help` for them. The other :delegates entries (rails, rake, bundle,
  # rubocop, …) hand off to a gem outside this repo, which this file cannot assert
  # about; these two it can.
  #
  # WHY THIS EXISTS. :delegates was, until 2026-09-01, the last bucket in this manifest
  # with no wiring assertion behind it — the exact condition this file spent a hundred
  # lines recording as the reason six real gaps sat here looking classified. Moving
  # bin/agent-activity from :subcommand_gap (which enforces a probe AND a filed task)
  # into :delegates would have been a NET LOSS of enforcement on the very script the
  # change existed to fix, and the label's claim — "the underlying tool owns --help" —
  # would have rested on prose. Prose does not fail CI. This does.
  IN_REPO_DELEGATES = {
    "release"        => "release.rb",
    "agent-activity" => "atomic-event"
  }.freeze

  def test_the_in_repo_delegating_stubs_reach_a_guarded_script
    IN_REPO_DELEGATES.each do |stub, target|
      assert_equal :delegates, MANIFEST[stub], "bin/#{stub} is no longer a delegating stub"
      assert_equal :cli_arg_guard, MANIFEST[target],
                   "bin/#{stub} delegates to bin/#{target}, so bin/#{target} must own a REAL guard — " \
                   "a stub whose target is unguarded is a gap wearing a safe label"

      src = code_only(stub)

      assert_includes src, target, "bin/#{stub} must actually invoke bin/#{target}"
      assert_match(/"\$@"|\bARGV\b/, src,
                   "bin/#{stub} must hand bin/#{target} the WHOLE line — a stub that forwards only " \
                   "part of it puts the dropped part back on the floor")
      refute_match(/ARGV\.(?:include\?|delete|shift)|OptionParser|getopts/, src,
                   "bin/#{stub} parses the line ITSELF — then bin/#{target}'s dictionary is not what " \
                   "read it, and the stub is a second, laxer parser of exactly the kind this family " \
                   "of defects is made of")
    end
  end

  # The two scripts big enough to wrap the shared guard in a helper of their own, and
  # the CALL that helper has to make. Both keep their dispatcher in
  # `if $PROGRAM_NAME == __FILE__`, so the seam is the `ARGV.shift` that reads the
  # subcommand.
  GUARD_HELPER_CALLERS = %w[qa-server agent-worktree].freeze

  # ANCHORED ON THE CALL SITE, NEVER THE DEFINITION — the property
  # test_the_guard_runs_before_the_first_mutation above CANNOT establish on these two.
  #
  # WHY THIS TEST EXISTS (finding-e429a953ff23, reproduced twice). That test indexes
  # `CliArgGuard.guard!`, and in a script that wraps the guard in `def guard_argv!`
  # near the top, the first occurrence of that string is inside the DEFINITION — which
  # sits above the dispatcher by construction, whether or not anything ever calls it.
  # Measured: with the guard's CALL deleted and its definition left intact,
  # this entire file passed 16 runs, 209 assertions, 0 failures against a script that
  # was fully unguarded. A guard that is defined and never called is the exact shape
  # of an inert fix, and it is invisible to every assertion in this file but this one.
  #
  # The regex matches the INVOCATION — a bare `guard_argv!` or `guard_argv!(ARGV)`
  # alone on its line — and cannot match `def guard_argv!(argv = ARGV, out: …)`.
  # The behavioural proof that the call is reached at RUNTIME lives one tier up, in
  # test/integration/agent_worktree_argv_guard_test.rb and
  # test/integration/qa_server_argv_guard_test.rb; this is the cheap static half that
  # fails the instant the line is deleted.
  def test_the_dispatcher_calls_its_guard_rather_than_merely_defining_it
    GUARD_HELPER_CALLERS.each do |name|
      src = code_only(name)
      call_at = src.index(/^\s*guard_argv!(\(ARGV\))?\s*$/)
      shift_at = src.index("ARGV.shift")

      refute_nil call_at,
                 "bin/#{name} DEFINES guard_argv! but never CALLS it — a defined-and-uncalled " \
                 "guard passes every other assertion in this file on a fully unguarded script"
      refute_nil shift_at, "bin/#{name} no longer shifts its subcommand — re-anchor this test"
      assert_operator call_at, :<, shift_at,
                      "bin/#{name} shifts its subcommand BEFORE calling its guard — the rest of " \
                      "the line is then on the floor, which IS the defect this family closes"
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
      "setup-1pass-token"     => "INSTALLS NOTHING",
      "ecosystem-build"       => "BUILDS NOTHING",
      "gh-app-git-credential" => "MINTS NOTHING",
      "install-agent-docs"    => "PUBLISHES NOTHING",
      "agent-runtime"         => "INSTALLS NOTHING"
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

  # The docs installer is the credential installer's twin, one blast radius up: the
  # targets are not this repo but the SHARED roots every session reads — the projects
  # root AGENTS.md/CLAUDE.md, ~/.claude/skills, ~/.codex/skills, ~/.claude/settings.json
  # and ~/.zprofile. So the refusal has to come before the first COPY, not merely
  # somewhere in the file.
  #
  # ANCHORED ON CALL SITES, NEVER DEFINITIONS. `install_pair` and `guard_no_arguments`
  # are both FUNCTIONS defined near the top, so indexing `install_pair() {` or the `cp`
  # inside it finds the definition — which sits ABOVE the guard by construction — and
  # this test would fail on correct code while passing on a script whose guard runs
  # after the copy loop. The pairs below are the invocations: the loop that copies, the
  # `rm -rf` of a retired skill, and the exec that hands the line to the installer.
  FIRST_PUBLISH = {
    "install-agent-docs" => ['install_pair "$src" "$tgt"', 'rm -rf "$retired"'],
    "agent-runtime"      => ['exec "$INSTALLER"']
  }.freeze

  def test_the_installer_refuses_before_it_publishes
    FIRST_PUBLISH.each do |name, publishes|
      src = code_only(name)
      refusal_at = src.index("unrecognized argument")
      refute_nil refusal_at, "bin/#{name} must REFUSE an argument it cannot account for"

      publishes.each do |publish|
        publish_at = src.index(publish)
        refute_nil publish_at, "bin/#{name} no longer contains #{publish} — update FIRST_PUBLISH"
        assert_operator refusal_at, :<, publish_at,
                        "bin/#{name} reaches #{publish} BEFORE its argument refusal — a guard cannot " \
                        "protect a publish that has already happened, and these targets are the " \
                        "SHARED roots every other session on the machine reads"
      end
    end
  end

  # …and the help scan must precede the refusal, so a probe is answerable on a line
  # that is otherwise malformed — the property CliArgGuard.guard! spells "HELP FIRST".
  def test_the_installer_answers_help_before_it_refuses
    FIRST_PUBLISH.each_key do |name|
      src = code_only(name)

      assert_operator src.index("--help|-h)"), :<, src.index("unrecognized argument"),
                      "bin/#{name} must answer a help probe ahead of the dictionary check, so " \
                      "`--help` still works on a command line it would otherwise refuse"
    end
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
  #
  # This carried a `refute_empty gaps` tripwire until 2026-09-01, whose whole purpose
  # was to go RED on the last fix in the family so the record could not be deleted
  # quietly. bin/atomic-event was that last fix; the gap bucket is now legitimately
  # empty and the tripwire was retired in the same change, exactly as the note on the
  # bucket instructed. The disjointness below stays meaningful on an empty bucket.
  def test_the_two_subcommand_buckets_are_disjoint
    plain = MANIFEST.select { |_, k| k == :subcommand }.keys
    gaps  = MANIFEST.select { |_, k| k == :subcommand_gap }.keys

    assert_empty plain & gaps,
                 "a script cannot be both a plain :subcommand and a CONFIRMED gap — the two buckets " \
                 "answer opposite questions, so an entry in both puts two truths on one screen"
  end

  # --- the :subcommand label, made a tested property -------------------------
  #
  # WHY THIS EXISTS. Until 2026-08-31 :subcommand was the ONLY bucket in this
  # manifest with no wiring assertion behind it. Its legend was prose, and prose
  # does not fail CI — which is exactly how bin/qa-server sat here looking
  # classified while
  #
  #     bin/qa-server provision <app> --yes --help
  #
  # PROVISIONED A QA SERVER FOR REAL. It deleted `--yes` to suppress the
  # confirmation, dispatched on ARGV[0], and never inspected `--help` at all, so
  # the flag fell off the end of the line and the create / addons / domains /
  # config-var writes ran to completion. The label was true about the BARE form
  # and the reader's conclusion was false — the same way bin/release read one
  # task earlier. Narrowing that legend's wording was the right move and did not
  # fix a single script. This does.
  #
  # WHAT IT ASSERTS, and why the predicate is exactly this wide. The bucket only
  # ever claimed something about the BARE form, so this must NOT assert that
  # `<cmd> --help` is safe — that would be a STRONGER promise than the label
  # makes, and a record that overclaims is the very thing being fixed here. What
  # it CAN require is the property whose absence makes the bare-form claim
  # actively misleading: a script that reaches a durable, outside-the-process
  # mutation must account for an argument it does not recognize SOMEWHERE in its
  # code. Three spellings satisfy that, because all three genuinely account for
  # the line — the shared guard, an explicit help-flag arm, or an explicit
  # unknown-argument refusal.
  #
  # MEASURED across all sixteen entries before it was written: bin/qa-server was
  # the ONLY failure. bin/gate and bin/triage both write to the PRODUCTION board
  # and both refuse an unknown flag BEFORE the POST; the nine confessed
  # flag-loops carry explicit `--help` arms; bin/secret reaches no durable
  # mutation. So this assertion cost no reclassification and no churn — it makes
  # the one real gap impossible to re-introduce silently, which is the only thing
  # a safety record is for.

  # Calls that reach outside this process and leave something behind. A small,
  # literal vocabulary rather than a clever heuristic, and every entry is a call
  # this bin/ actually makes. The control test below proves the set still matches
  # source known to mutate: a vocabulary that quietly stopped matching would turn
  # this whole assertion green by reading nothing at all.
  DURABLE_MUTATION = {
    "heroku create"   => /heroku["',\s]+create/,
    "heroku addons"   => /addons:create/,
    "heroku domains"  => /domains:add/,
    "heroku ps:scale" => /ps:scale/,
    "git push"        => /git["',\s]+push/,
    "HTTP write"      => /Net::HTTP::(?:Post|Patch|Put|Delete)|\b(?:request|api)\(:(?:post|patch|put|delete)|-X\s*(?:POST|PATCH|PUT|DELETE)/,
    "file write"      => /File\.write|FileUtils\.(?:mv|rm|cp|mkdir)/
  }.freeze

  # The three spellings that genuinely account for an unrecognized argument.
  ACCOUNTS_FOR_ARGV = /CliArgGuard\.guard!|--help|(?<!\w)-h\)|"-h"|'-h'|unknown flag|unrecognized argument|refuse_unknown_args!/

  def test_every_mutating_subcommand_script_accounts_for_an_unknown_argument
    offenders = MANIFEST.select { |_, kind| kind == :subcommand }.each_key.filter_map do |name|
      src = code_only(name)
      mutations = DURABLE_MUTATION.select { |_, re| src.match?(re) }.keys
      next if mutations.empty? || src.match?(ACCOUNTS_FOR_ARGV)

      "bin/#{name} (reaches: #{mutations.join(', ')})"
    end

    assert_empty offenders,
                 "#{offenders.join('; ')} — classified :subcommand, reaches a DURABLE mutation, and " \
                 "accounts for an unrecognized argument nowhere in its code. That is the bin/qa-server " \
                 "shape: `provision <app> --yes --help` dropped the flag and provisioned for real. " \
                 "Wire bin/lib/cli_arg_guard.rb and reclassify :cli_arg_guard, or — if the gap is " \
                 "being left open on purpose — move it to :subcommand_gap with its probe and a filed task."
  end

  # The defect, frozen as a fixture, so the assertion above is proven to BITE.
  # A predicate that silently stopped matching would pass the bucket by reading
  # nothing, and "the test is green" would mean the opposite of what it looks
  # like. This is the pre-fix bin/qa-server dispatcher, verbatim in shape.
  REGRESSED_SHAPE = <<~SHAPE
    cmd = ARGV.shift || "help"
    case cmd
    when "provision"
      assume_yes = ARGV.delete("--yes")
      run_provision(ARGV[0], assume_yes: !!assume_yes)
    end
    sh("heroku", "create", app, "--no-remote")
  SHAPE

  def test_the_unknown_argument_predicate_actually_bites
    assert DURABLE_MUTATION.any? { |_, re| REGRESSED_SHAPE.match?(re) },
           "the mutation vocabulary no longer recognizes `heroku create` — the bucket assertion above " \
           "would pass by matching nothing"
    refute REGRESSED_SHAPE.match?(ACCOUNTS_FOR_ARGV),
           "the accounting predicate now matches source that accounts for nothing — it would bless the " \
           "exact shape that provisioned a QA server"

    # …and it must still SEE the accounting in a script that really has it.
    gate = code_only("gate")
    assert DURABLE_MUTATION.any? { |_, re| gate.match?(re) },
           "bin/gate writes to the board; a vocabulary that misses it is reading nothing"
    assert gate.match?(ACCOUNTS_FOR_ARGV),
           "bin/gate refuses an unknown flag before its POST — the predicate must see that"
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
