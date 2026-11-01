# frozen_string_literal: true

# [unit] EVERY script in bin/ must be named in MANIFEST below with how it handles an argument it
# does not recognize. A NEW SCRIPT FAILS THIS TEST until someone classifies it. THE CLASS: a
# script hand-parses exact flags, so `--help`, the universal safe probe, matches nothing, is
# silently dropped, and the script RUNS ITS REAL ACTION. WHY STATIC: with a regressed guard,
# `bin/clean-artifacts --help` truncates logs and deletes caches across every repo
# (config/test_health.yml records the cost). So this tier asserts the guard is WIRED, never
# executes a bin/ script. Behavioural: test/lib/archive_docs_help_guard_test.rb.
# History: task archive-docs-help-mutates.

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
    "test-health"            => :cli_arg_guard,
    # --- the archive's pruners ------------------------------------------------
    "prune-branches"         => :cli_arg_guard,
    "prune-session-markers"  => :cli_arg_guard,
    # --- retrofitted 2026-08-31, /tasks/release-subcommand-drops-help ---------
    # The release machinery, and the sharpest instance the class has produced:
    # the side effect is not a local file but shared branch state in every repo,
    # a production board write, and (on `ship`) a RubyGems publish, whose version
    # can never be re-pushed. Its per-subcommand dictionary is
    # Release::Cli::COMMANDS.
    "release.rb"             => :cli_arg_guard,
    "clean-artifacts"        => :cli_arg_guard,
    "register-app"           => :cli_arg_guard,
    "r2-backup"              => :cli_arg_guard,
    # The nightly UI budget (.github/workflows/ui-budget.yml): --collect opens
    # production pages in a browser and writes a results file.
    "ui-budget"              => :cli_arg_guard,
    # The Cloudflare DNS move: creates zones, rewrites records, sets SSL, writes
    # redirect rules, adds Heroku domains and moves APP_HOST. One guard with a
    # per-subcommand flag dictionary, ahead of the first credential read.
    "domain-cutover"         => :cli_arg_guard,
    # Buys domains on Cloudflare Registrar: the registration POST charges Alex McRitchie's
    # card. One guard with a per-subcommand flag dictionary, ahead of the first
    # credential read, so `register <d> --price x --ok y --help` buys nothing.
    "domain-register"        => :cli_arg_guard,
    # --- retrofitted 2026-08-31, /tasks/qa-server-help-provisions -------------
    # `provision <app> --yes --help` ran a REAL provision, with confirmation suppressed by
    # --yes. Its per-subcommand dictionary is QaServerCli::COMMANDS. Help and refusal both exit
    # NON-ZERO because bin/release reads this script's exit status as "the QA deploy succeeded".
    # History: task qa-server-help-provisions.
    "qa-server"              => :cli_arg_guard,
    # The content pipeline's agent CLI. CLAIMS and WRITES, so `--help` is wired
    # through the parser and exits before dispatch — verified against a dead
    # base URL, so no subcommand reached the network.
    "content"                => :optparse,
    # Posts video to a public X account. `--help` is wired through OptionParser
    # and an unknown flag refuses before any credential read or upload.
    "x-post"                 => :optparse,
    # Leftover positionals beyond <soul> <dir> abort with the usage line.
    "openclaw-workspace"     => :optparse,
    # Generates the SOP registry blocks; --write is the only mutation and --help exits first.
    "sop-registry"           => :optparse,
    # Stamps a T0 board note (start) and writes the ledger (record); OptionParser
    # parses every flag, so --help exits and an unknown flag refuses before any read.
    "ship-clock"             => :optparse,
    # Rewrites db/migrate; the parse (and --help) comes before any file is touched,
    # and an unknown flag or a stray argument aborts with the usage line.
    "db-baseline"            => :optparse,
    # Builds a marketing kit locally (build) or writes it to Drive (publish).
    # OptionParser reads the WHOLE line before dispatch, so `publish SPEC --out D
    # --help` prints and exits; an unknown flag, command or stray argument aborts.
    "marketing-kit"          => :optparse,
    # Asks the board for this machine's harness key and keeps it. `--help` is wired
    # through OptionParser and prints before dispatch; an unknown flag, an unknown
    # command and a stray positional all refuse before any request or write.
    "harness-key"            => :optparse,
    # Sets pmset (sudo), makes directories, clones the hub, installs launchd agents
    # (--take-over) or uninstalls them (--hand-off-to). OptionParser parses every
    # flag, --help exits before any step, and leftover positionals refuse (exit 2);
    # test/commands/conductor_host_setup_test.rb proves `--help --take-over` runs nothing.
    "conductor-host-setup"   => :optparse,
    "control-check"          => :cli_arg_guard,
    # Read-only: it runs the JS dependency audit and reports a verdict; it takes
    # no options and mutates nothing, so there is no first mutation for --help to
    # precede. It is classified anyway because it was born ignoring ARGV, which
    # is exactly the shape this file exists to catch — `--help` would have run a
    # full network audit instead of printing help. Unknown flags exit 2, distinct
    # from the 1 that means "vulnerabilities found", so CI cannot read a typo as
    # a security finding.
    "importmap-audit-ci"     => :optparse,
    # Read-only: counts front-end house-rule offenses in a tree and prints a report.
    # An unknown flag or a second tree refuses with exit 2 before any file is read,
    # distinct from the 1 that --strict means "offenses found".
    "ui-lint"                => :optparse,
    # Generate enqueues a PAID image round; the guard runs before the Rails boot.
    "email-image"            => :cli_arg_guard,
    "game-model"             => :cli_arg_guard, # PAID image calls; the guard runs before bundler
    # PUBLISHES a client app's bundle (flips its live preview); the guard runs
    # before the bundle is read or anything is sent.
    "client-bundle"          => :cli_arg_guard,
    # MOVES an app off Heroku (bucket, DNS, custom domain, URL rewrite, scale to 0)
    # under --execute, and reads the admin Cloudflare token even to plan; the guard
    # runs before the registry or any credential is read.
    "static-downgrade"       => :cli_arg_guard,
    # COPIES the credential helper's whole closure to disk and repoints a symlink,
    # so it is guarded like the rest of the mutating flat scripts. Its --check and
    # --print-config arms install nothing, but the DEFAULT arm (no flags at all)
    # installs — which is exactly the shape where an unaccounted `--help` mutates.
    "install-git-credential-helper" => :cli_arg_guard,
    # THE READ-ONLY ONE, and the only :cli_arg_guard entry with no FIRST_MUTATION
    # row — deliberately, because it has no mutation to precede. bin/agent-presence
    # writes no file, signals no process and takes no lock. It is guarded anyway, and
    # its help exits 3 rather than 0, because THIS script's 0 is a VERDICT ("clear to
    # start") rather than "the command ran". Answering the universal safe probe with
    # a green light is the same defect one meaning over: the operator asked what the
    # command does and would be told the machine is free.
    "agent-presence"         => :cli_arg_guard,
    # READ-ONLY too (GitHub, two RPC reads per cluster, the board; its only write is
    # its own cache file, after the guard). Like agent-presence its exit status is a
    # VERDICT (0 every cluster current), so its help exits 3, never 0.
    "program-drift"          => :cli_arg_guard,
    # The harvest WRITES desk records to the board, so it is guarded like the rest of
    # the mutating flat scripts. Its help exits 1: exit 0 from it asserts "the stranded
    # rows are recorded", which a probe never established.
    "harvest-desk-ledger"    => :cli_arg_guard,
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/atomic-event-help-mutates). `run`
    # swallows every StandardError and the script always exits 0, so a probe that mutated would
    # report SUCCESS. Its dictionary is AgentActivityCli::COMMANDS, in bin/atomic-event itself
    # rather than bin/lib/: the parsers it must agree with are ten lines below it. Help exits 0
    # here, the opposite of bin/release, bin/qa-server and bin/agent-worktree, because this
    # CLI's 0 means only "this ran". The rationale names all six callers, on
    # AgentActivityCli::HELP_EXIT.
    # History: task atomic-event-help-mutates.
    "atomic-event"           => :cli_arg_guard,
    # The agent mailbox (docs/agents/system/agent-message-loop.md). bin/heartbeat
    # CLAIMS a message on the board; bin/agent-inbox only reads. Both guard first.
    "heartbeat"              => :cli_arg_guard,
    "dispatcher"             => :cli_arg_guard,
    # A scoped run's MCP tool server (Scopes::Server), started by `claude -p`.
    # OptionParser with a -h arm; help prints and exits before any tool is served,
    # and a stray positional argument refuses. It writes nothing in any case.
    "agent-scope-mcp"        => :optparse,
    # bin/dispatcher's sibling service: install writes ~/Library/LaunchAgents and
    # run claims board tasks, so every subcommand guards first.
    "client-build-launcher"  => :cli_arg_guard,
    # The services phase of bin/ecosystem-build: `restore` installs launchd
    # services and `allow-rules` rewrites ~/.claude/settings.json, so the guard
    # runs (per subcommand) before either.
    "local-services"         => :cli_arg_guard,
    "agent-inbox"            => :cli_arg_guard,
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/worktree-subcommand-drops-help).
    # Dictionary: AgentWorktreeCli::COMMANDS. Help exits 1 and the refusal 2: exit 0 is read as
    # a FACT by bin/task#begin_step!, bin/qa-intake#refresh_registry,
    # bin/release.rb#restore_primaries and bin/release.rb#reclaim_worktrees. `shell-hook zsh` is
    # eval'd, so usage goes to stderr. ONE ARM FORWARDS: `test <app> <task> [--
    # rails-test-args]` gets the help scan only, or `-n /pattern/` and `--` refuse. Proof:
    # test/integration/agent_worktree_argv_guard_test.rb.
    # History: task worktree-subcommand-drops-help.
    "agent-worktree"         => :cli_arg_guard,
    # --- NEW SCRIPT, guarded at birth (/tasks/backup-collisions-are-silent) ---
    # `restore` OVERWRITES A FILE IN THE WORKING TREE and `save` can overwrite a restore point.
    # Its dictionary is COMMANDS in the script (four arms, same --owner/--root pair), fed to one
    # guard call ahead of the dispatcher. Help exits 1: `verify` makes exit 0 an ASSERTION, and
    # a probe must never answer with an assertion, the same reasoning as
    # bin/harvest-desk-ledger.
    # History: task backup-collisions-are-silent.
    "scratch-backup"         => :cli_arg_guard,
    # --- NEW SCRIPT, guarded at birth (/tasks/local-dev-drops-prod-hub-key) ---
    # `rewrite`/`fix` OVERWRITE a local .env's SECRET_KEY_BASE, and `scan` reads every
    # production app's Heroku config. One guard call ahead of `case command`. Help exits
    # 3: a scan's exit 0 is the ASSERTION "no production key on disk", which a probe
    # must never answer with. Behavioural proof:
    # test/lib/dev_secret_key_scan_integration_test.rb (`rewrite --help` writes nothing).
    "dev-secret-key"         => :cli_arg_guard,
    # Sibling of dev-secret-key (/tasks/dev-google-client-for-local): a dry run by
    # default, `--write` reads the vault and rewrites every local env file. One guard
    # call ahead of the vault read. Help exits 3 for the same reason: a dry run's
    # exit 0 reports a plan, which a probe must never answer with.
    "dev-google-client"      => :cli_arg_guard,
    # --- NEW SCRIPT, guarded at birth (/tasks/chrome-profile-order-sop) -------
    # Its mutations reach OUTSIDE this repo: `apply` QUITS THE OPERATOR'S BROWSER and rewrites
    # Chrome's `Local State`, `pin-dock` rewrites com.apple.dock and restarts the Dock,
    # `install-wrapper` writes into ~/Applications, `relaunch` restarts Chrome. Dictionary:
    # ChromeProfiles::Cli::COMMANDS. Help exits 1: `status` makes exit 0 an ASSERTION that an
    # SOP step gates on. It needs the GUARD_HELPER_CALLERS row below, because it wraps the
    # guard.
    # History: task chrome-profile-order-sop.
    "chrome-profiles"        => :cli_arg_guard,
    # Writes PNGs into app/assets/images and tmp/. OptionParser with a -h arm;
    # it also REFUSES a leftover positional, so `bin/workspace-icon logo.png`
    # cannot render the default badge while the path typed is silently ignored.
    "workspace-icon"         => :optparse,
    # Writes to the operator's Apple Contacts (create/update/photo), which syncs
    # to his iPhone — outside this repo, and not undone by `git checkout`. One
    # OptionParser with a -h arm serves every subcommand, an unknown subcommand
    # prints usage and exits 1, and a leftover positional REFUSES, so
    # `bin/apple-contact create card.json` cannot write while the path is ignored.
    "apple-contact"          => :optparse,
    # --- shell scripts, same sweep, same defect, different idiom --------------
    "setup-1pass-token"      => :own_guard,
    "ecosystem-build"        => :own_guard,
    # PATCHes the production hub's SECRET_KEY_BASE. The help scan and the refusal
    # run before HEROKU_API_KEY is read. Behavioural proof:
    # test/lib/secret_key_base_swap_script_test.rb.
    "secret-key-base-swap"   => :own_guard,
    # PATCHes a Heroku app's config with the value from stdin. OptionParser with a
    # -h arm that exits before stdin or the network is touched; a wrong argument
    # count exits 2. Behavioural proof: test/lib/heroku_secret_set_test.rb.
    "heroku-secret-set"      => :optparse,
    # Reads a Heroku token from 1Password and execs the command after `--` with it
    # in the child's environment; -h exits before any read, an unknown flag or a
    # wrong shape exits 2. Behavioural proof: test/commands/heroku_token_test.rb.
    "heroku-token"           => :optparse,
    # Rewrites ~/.zprofile and ~/.zprofile.admin. The parse, and its -h arm, run
    # before any profile is read; an unknown flag or a stray positional exits 2.
    # Behavioural proof against fixture profiles: test/commands/heroku_profile_migrate_test.rb.
    "heroku-profile-migrate" => :optparse,
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/docs-installer-help-publishes).
    # Both carry the shell idiom the three above use: a whole-line --help|-h scan plus an
    # explicit unrecognized-argument refusal, per
    # test_the_shell_scripts_answer_help_without_acting and
    # test_the_installer_refuses_before_it_publishes. Behavioural:
    # test/commands/install_agent_docs_help_guard_test.rb. NOT the shared
    # bin/lib/cli_arg_guard.rb: it is Ruby, and this bootstrap repairs Ruby.
    # History: task docs-installer-help-publishes.
    "install-agent-docs"     => :own_guard,
    "agent-runtime"          => :own_guard,
    # RECLASSIFIED, NOT DELETED (/tasks/credential-helper-help-mints). `get --help` ran the REAL
    # `get`, measured to mint a live installation token, write it to the shared store, and print
    # it. :subcommand carried no wiring assertion, so its claim was never checked against the
    # code. :own_guard is, by test_the_shell_scripts_answer_help_without_acting below.
    # History: task credential-helper-help-mints.
    "gh-app-git-credential"  => :own_guard,
    # --- the three prior fixes -----------------------------------------------
    "task"                   => :own_guard,
    "devops-shift"           => :own_guard,
    "ledger-guard"           => :own_guard,
    # Help anywhere prints usage; an argument it cannot place exits 2 before
    # `index --write`. test/lib/dream_cli_test.rb runs both.
    "dream"                  => :own_guard,
    # Read-only (it lists Playwright's suite and counts e2e/): `--help` prints usage
    # and an argument it cannot place aborts before anything runs.
    "e2e-census-check"       => :own_guard,
    # --- OptionParser ---------------------------------------------------------
    "submit"                 => :optparse,
    # submit-wait rescues OptionParser::ParseError to REFUSE with its usage banner and
    # exit code 3, not to step over it — and it parses before any side effect, so
    # `--help` and `--bogus` both act on nothing. The parser's refusal is intact.
    "submit-wait"            => :optparse,
    "rotate-heroku-ci-key"   => :optparse,
    "dor-check"              => :optparse,
    "fast-check"             => :optparse,
    # Both corpus scripts parse before touching anything and then REFUSE a leftover
    # positional, because OptionParser alone would have let `bin/hormozi-prep
    # ./captions` run a full re-clean against the default root while the operator
    # watched a path they named be ignored.
    "hormozi-prep"           => :optparse,
    "hormozi-bundle"         => :optparse,
    "pr-review"              => :optparse,
    "session-preflight"      => :optparse,
    "reviewer-select"        => :optparse,
    "qa-intake"              => :optparse,
    # The Gmail READ credential's one-time refresh-token mint. OptionParser with a
    # -h arm that exits before anything opens, and an unknown flag raises
    # InvalidOption unrescued. Nothing durable to precede: it writes no file and
    # calls no API until a human has approved a consent screen in a browser, and
    # its whole output is a JSON object printed to stdout for the operator to
    # paste into 1Password. The abort for a missing --client-id is reached only
    # AFTER the help arm has already exited.
    "gmail-oauth-mint"       => :optparse,
    "devops-cycle"           => :optparse,
    "devops-tests"           => :optparse,
    "devops-reconcile"       => :optparse,
    "register-satellite"     => :optparse,
    "review-autopilot"       => :optparse,
    "verify-review-hop"      => :optparse,
    "measure-client-surface" => :optparse,
    # Exactly one URL; a second positional aborts before any download.
    "digest-video"           => :optparse,
    "find-clips"             => :optparse,
    # Exactly one slug; --help and an unknown flag exit before the API is read.
    "stitch-video"           => :optparse,
    # Exactly one slug and one of --extract or --apply; --help and an unknown flag
    # exit before the API is read, a frame stilled or anything uploaded.
    "clip-references"        => :optparse,
    # Exactly one clip slug, or --whoami; --help and an unknown flag exit before
    # the API is read, and a production draft also needs --yes.
    "tiktok-draft"           => :optparse,
    # One subject, or a fact slug with --supersede or --retire; --help and an
    # unknown flag exit before a session token is read or the hub is called.
    "fact"                   => :optparse,
    # Read-only: every verb is a read through one `heroku run`. The verb is
    # shifted first, then OptionParser owns the rest, so `desk 5 --help` prints
    # help and exits before any run; an unknown flag raises unrescued.
    "mail"                   => :optparse,
    # Writes (intake, classify, close) through one `heroku run`. The verb is shifted
    # first, then OptionParser owns the rest, so `close studio 2026-10 --help` prints
    # help and exits before any run; an unknown flag raises unrescued, and
    # BooksCli.build_request refuses a stray positional for every verb.
    "books"                  => :optparse,
    # bin/agent-setup: OptionParser answers --help/-h with usage and exits before
    # any run (no heroku, no op read); an unknown flag exits 2; and
    # AgentSetupCli refuses a stray positional for every verb before it acts.
    "agent-setup"            => :optparse,
    # bin/keep-awake: a bare or unknown command prints usage and exits; OptionParser
    # answers -h/--help after any subcommand before it acts, an unknown flag exits 2,
    # and a stray positional refuses before the store is touched.
    "keep-awake"             => :optparse,
    # --- subcommand dispatch that falls through to usage (BARE form) ----------
    # Read the legend above first: this bucket says what the BARE probe does, nothing about
    # `<cmd> --help`. KNOWN DILUTION: ci-shard, op-reads, measure-test-timings, gh-auth-refresh,
    # gh-token, prod-smoke, e2e-executed-set-check, rails-executed-set-check and secret are
    # single-level flag loops, closer to :own_guard. They are safe. Re-judge them in the next
    # sweep, from this written set.
    # History: task release-subcommand-drops-help.
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
    "ship"                   => :delegates, # sh alias: execs bin/submit, which owns --help
    "ship-wait"              => :delegates, # sh alias: execs bin/submit-wait, which owns --help
    # RECLASSIFIED FROM :subcommand_gap, NOT DELETED (/tasks/atomic-event-help-mutates). An
    # 8-line shim that `load`s bin/atomic-event and calls the SAME AgentActivityCli#run, so the
    # guard is INSIDE `run`, not under `$PROGRAM_NAME == __FILE__`: ONE call guards both names.
    # test_the_in_repo_delegating_stubs_reach_a_guarded_script asserts the delegation; the
    # refusal is proven by real execution with a control in test/lib/atomic_event_cli_test.rb.
    # History: task atomic-event-help-mutates.
    "agent-activity"         => :delegates, # 8-line shim: loads bin/atomic-event, which owns --help
    "rails"                  => :delegates,
    "rake"                   => :delegates,
    "bundle"                 => :delegates,
    "rubocop"                => :delegates,
    "brakeman"               => :delegates,
    "importmap"              => :delegates,
    "jobs"                   => :delegates,
    "dev"                    => :delegates,
    "island-background"      => :delegates,
    "test-js"                => :delegates, # execs `node --test`, which owns --help; runs tests, mutates nothing
    # --- CONFIRMED subcommand-position gaps, each with a filed task -----------
    # A gap dispatches on a subcommand and drops the rest, so its named probe RUNS THE REAL
    # ACTION; a `:subcommand` label does not mean safe to probe. THE BUCKET IS NOW EMPTY, the
    # finished state: each entry was reclassified above with its record kept. `refute_empty
    # gaps` was retired DELIBERATELY; `assert_empty plain & gaps` stays. THE BUCKET ITSELF
    # STAYS, armed: test_every_subcommand_gap_carries_a_probe_and_a_filed_task enforces any
    # future entry and anchors on the section headers below.
    # History: task release-subcommand-drops-help.

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
    "merge-permit"           => :accepted_gap, # read-only: GETs the task, its scout reports and the PR; never merges
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

  # Source with whole-line comments removed. EVERY position assertion below runs on THIS, not on
  # the raw file: doctrinal headers NAME the calls being located (`ControlReplay.partition` in
  # bin/control-check, `pbpaste` in bin/setup-1pass-token), so raw text finds the PROSE and
  # concludes the guard runs after the mutation. A substring that can match a comment asserts
  # about documentation, not code.
  # History: task archive-docs-help-mutates.
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

  # A HASH LITERAL WITH ONE KEY TWICE KEEPS THE LAST, SILENTLY, so a duplicate is invisible to
  # every other test here: MANIFEST.keys has already collapsed it. This one reads the SOURCE.
  # The trap: git can merge a reclassification and a gap entry for one script with no conflict,
  # the LATER entry wins, the change is discarded, and nothing goes red.
  # History: task credential-helper-help-mints.
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
    "client-bundle"       => "ClientAppBundle",
    "static-downgrade"    => "StaticCloudflare.downgrade_target",
    "program-drift"       => "ProgramDrift.readings",
    "archive-docs"        => "DocsArchive.roll_ledger!",
    "clean-artifacts"     => "ArtifactSweep",
    "control-check"       => "ControlReplay.partition",
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
    # Every write (rewrite, fix) and every Heroku read (scan) is reached through
    # `case command`, so the guard has to precede that line.
    "dev-secret-key"      => "case command",
    # The vault read (an `op` process) is the first side effect, and the file
    # rewrite follows it in the same block, so the guard has to precede that call.
    "dev-google-client"   => "DevGoogleClient.read_from_vault",
    # Same reasoning once more. Every POST and marker write bin/atomic-event can perform is
    # reached through `case command` inside AgentActivityCli#run, so the guard has to precede
    # that line. Unlike the three above, it wraps the guard in NO helper: the only
    # `CliArgGuard.guard!` in the file IS the call site, so it needs no GUARD_HELPER_CALLERS
    # entry. Behavioural proof: test/lib/atomic_event_cli_test.rb asserts a POST RECEIPT, each
    # probe paired with a control.
    # History: task atomic-event-help-mutates.
    "atomic-event"        => "case command",
    # The newest member, and the only one here that was never a defect. Its mutations —
    # ScratchBackup.save writing a blob, ScratchBackup.restore overwriting a file in the
    # working tree — are all reached through `case command`, so that dispatcher is the
    # seam. Anchored on it rather than on either call so a fifth subcommand cannot be
    # added below the guard without this staying true.
    "scratch-backup"      => "case command",
    # The dispatcher again, and the first one whose arms mutate state this repo does
    # not own: Chrome's Local State, com.apple.dock, ~/Applications, and the running
    # browser itself. Anchored on `case ARGV.first` rather than on any one call so a
    # sixth subcommand cannot be added below the guard without this staying true.
    "chrome-profiles"     => "case ARGV.first",
    # Anchored on the INSTALL call rather than on the `case options[:mode]`
    # dispatcher above it, because that dispatcher's other two arms print and exit
    # — this is the one line that writes to disk, and the guard has to precede it.
    "install-git-credential-helper" => "CredentialHelperInstall.install!",
    # The claim, the complete and the release all happen inside Heartbeat#run, and
    # nothing before the Heartbeat is built touches the board.
    "heartbeat"           => "AgentMailbox::Heartbeat.new",
    # Every subcommand is guarded before the dispatch; install (launchctl, a
    # ~/Library/LaunchAgents write) is the first arm that writes anything, and the
    # run loop's claims come after it.
    "dispatcher"          => "AgentMailbox::LaunchAgent.new",
    # The same shape: install is the first arm that writes, and run's claims come after it.
    "client-build-launcher" => "ClientBuildLauncher::LaunchAgent.new",
    # The first 1Password read; every Cloudflare and Heroku write follows it.
    "domain-cutover"      => "DomainCutover::Credentials.cloudflare",
    # The first 1Password read; the domain-check and the registration POST follow it.
    "domain-register"     => "DomainRegister::Credentials.cloudflare"
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

  # The binstubs whose TARGET lives in this same bin/, mapped to the script that owns `--help`
  # for them. The other :delegates entries (rails, rake, bundle, rubocop, …) hand off to a gem
  # outside this repo, which this file cannot assert about. Without this, the label's claim that
  # "the underlying tool owns --help" rests on prose. Prose does not fail CI. This does.
  # History: task atomic-event-help-mutates.
  IN_REPO_DELEGATES = {
    "release"        => "release.rb",
    "agent-activity" => "atomic-event",
    "ship"           => "submit",
    "ship-wait"      => "submit-wait"
  }.freeze

  # A target owns a REAL guard when it calls the shared guard or leaves an
  # OptionParser refusal intact (test_optparse_scripts_leave_the_parsers_refusal_intact).
  REAL_GUARDS = %i[cli_arg_guard optparse].freeze

  def test_the_in_repo_delegating_stubs_reach_a_guarded_script
    IN_REPO_DELEGATES.each do |stub, target|
      assert_equal :delegates, MANIFEST[stub], "bin/#{stub} is no longer a delegating stub"
      assert_includes REAL_GUARDS, MANIFEST[target],
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

  # The scripts that wrap the shared guard in a helper, mapped to the SEAM that reads the
  # subcommand: the line the helper's call has to precede. A table, not a bare array against
  # `ARGV.shift`: bin/chrome-profiles uses `case ARGV.first` and never shifts, so a hardcoded
  # seam makes `shift_at` nil and fires `refute_nil`, and the only green would be exempting the
  # script.
  # History: task chrome-profile-order-sop.
  GUARD_HELPER_CALLERS = {
    "qa-server"       => "ARGV.shift",
    "agent-worktree"  => "ARGV.shift",
    "chrome-profiles" => "case ARGV.first"
  }.freeze

  # ANCHORED ON THE CALL SITE, NEVER THE DEFINITION.
  # test_the_guard_runs_before_the_first_mutation indexes `CliArgGuard.guard!`; in a wrapping
  # script its first hit is inside `def guard_argv!`, called or not. The regex matches the
  # INVOCATION: bare `guard_argv!`, `guard_argv!(ARGV)`, or `PARSED = guard_argv!`. It cannot
  # match `def guard_argv!(argv = ARGV, out: …)`: the anchor requires the call to END there.
  # Runtime: test/integration/agent_worktree_argv_guard_test.rb,
  # test/integration/qa_server_argv_guard_test.rb.
  # History: task worktree-subcommand-drops-help.
  def test_the_dispatcher_calls_its_guard_rather_than_merely_defining_it
    GUARD_HELPER_CALLERS.each do |name, seam|
      src = code_only(name)
      call_at = src.index(/^\s*(?:[A-Z][A-Z0-9_]*\s*=\s*)?guard_argv!(\(ARGV\))?\s*$/)
      seam_at = src.index(seam)

      refute_nil call_at,
                 "bin/#{name} DEFINES guard_argv! but never CALLS it — a defined-and-uncalled " \
                 "guard passes every other assertion in this file on a fully unguarded script"
      refute_nil seam_at, "bin/#{name} no longer reads its subcommand with `#{seam}` — re-anchor this test"
      assert_operator call_at, :<, seam_at,
                      "bin/#{name} reads its subcommand BEFORE calling its guard — the rest of " \
                      "the line is then on the floor, which IS the defect this family closes"
    end
  end

  def test_the_shell_scripts_answer_help_without_acting
    {
      "setup-1pass-token"     => "INSTALLS NOTHING",
      "ecosystem-build"       => "BUILDS NOTHING",
      "gh-app-git-credential" => "MINTS NOTHING",
      "install-agent-docs"    => "PUBLISHES NOTHING",
      "agent-runtime"         => "INSTALLS NOTHING",
      "secret-key-base-swap"  => "TOUCHES NOTHING"
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

  # The docs installer's targets are the SHARED roots every session reads: the projects root
  # AGENTS.md/CLAUDE.md, ~/.claude/skills, ~/.codex/skills, ~/.claude/settings.json and
  # ~/.zprofile. So the refusal has to come before the first COPY. ANCHORED ON CALL SITES, NEVER
  # DEFINITIONS: `install_pair` and `guard_no_arguments` are FUNCTIONS near the top, so indexing
  # `install_pair() {` fails on correct code and passes a guard that runs after the copy loop.
  # The pairs below are invocations: the copy loop, the `rm -rf` of a retired skill, and the
  # exec to the installer.
  # History: task docs-installer-help-publishes.
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
  # The bucket only claims something about the BARE form, so this must NOT assert `<cmd> --help`
  # is safe: that overclaims. It requires only this: a script reaching a durable,
  # outside-the-process mutation must account for an argument it does not recognize SOMEWHERE in
  # its code. Three spellings satisfy that: the shared guard, an explicit help-flag arm, or an
  # explicit unknown-argument refusal.
  # History: task qa-server-help-provisions.

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
