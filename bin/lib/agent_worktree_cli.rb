# frozen_string_literal: true

# AgentWorktreeCli — the argument DICTIONARY bin/agent-worktree's `--help`/unknown-
# argument guard is built from. Pure, IO-free and Rails-free (bin/agent-worktree
# `require_relative`s it directly, so it must load standalone), which is what lets
# every verdict below be proven in a unit test WITHOUT running the script.
#
# THE DEFECT IT CLOSES (/tasks/worktree-subcommand-drops-help), and it is the
# WIDEST surface the class has produced — twenty subcommands, sixteen of which
# reach a durable write. The dispatcher did `cmd = ARGV.shift || "help"` and no arm
# validated what was left, so:
#
#     bin/agent-worktree new <app> <task> --help
#
# CREATED A REAL DESK. The `new` arm destructures
# `app_name, raw_task, maybe_type, *rest = ARGV` and then decides the branch type
# with `maybe_type&.start_with?("--") ? "feat" : ...` — so `--help` landed in
# `maybe_type`, was RECOGNISED as flag-shaped, and was thrown away on purpose;
# `*rest` was never inspected by anything. The probe then ran the whole bringup:
# `git worktree add -b`, a port + Redis DB allocation written to `.env.agent-stack`,
# the `.agent-context.json` marker, and a Postgres database via prepare_test_env.
#
# It was not the only reachable arm. Measured at source on the same sweep:
#
#   bind-task <app> <task> <slug> --help   writes the stack env + context marker
#   up <app> <task> --help                 STARTS the stack and writes the marker
#   status <app> <task> --help             writes the context marker
#   scale out --help                       GROWS the persisted Redis band
#
# and `remove` / `cleanup --reclaim` / `sweep-orphan-dbs` / `snapshot --write` were
# safe only because each gates on an explicit `--yes`/`--write` — safe by luck, not
# by design. Bare `bin/agent-worktree --help` fell through to usage, which is
# exactly why the manifest once classified this script as safe: the label was true
# about the BARE form and the reader's conclusion was false.
#
# This is the seventh instance of the class (PR #974 review claim, PR #980 release
# claim, bin/devops-shift, bin/archive-docs, bin/release, bin/qa-server,
# bin/install-agent-docs + bin/agent-runtime) and it is fixed with the SHARED guard
# (bin/lib/cli_arg_guard.rb) reading the shared dictionary below, exactly as
# bin/release and bin/qa-server do — not a private parser, because a private parser
# is why the earlier ones each had to be discovered the hard way.
module AgentWorktreeCli
  module_function

  # WHY HELP EXITS 1 AND NEVER 0 — the load-bearing decision in this file, and not
  # the shared guard's default.
  #
  # Exit 0 from bin/agent-worktree is read as a FACT by four callers, and in every
  # one of them the fact is something a probe never established:
  #
  #   bin/task:1869-1889   `begin_step!` runs `new <app> <slug>` then
  #                        `bind-task <app> <slug> <task>`, and `die!`s on non-zero.
  #                        Exit 0 means "THE WORKTREE WAS CREATED" and "the task is
  #                        bound" — so a help probe answering 0 would let
  #                        `bin/task begin` march on to the claim, the preflight and
  #                        a printed worktree path for a desk that does not exist.
  #   bin/qa-intake:56     `snapshot --write` under capture_status; exit 0 means
  #                        "the registry was refreshed", and the very next call
  #                        reads that registry to build the conductor queue. A
  #                        zero-exit probe hands it a STALE registry it believes is
  #                        fresh.
  #   bin/release.rb:6999  `restore-primary <repo>`; the arm already exits 1 to mean
  #                        "REFUSED, primary left as-is", which the ship reports as a
  #                        warning. Exit 0 there asserts the primary was returned to
  #                        a clean `main`.
  #   bin/release.rb:7047  `cleanup --reclaim [--yes]`; exit 0 means the reclaim ran,
  #                        and the ship parses its output for a reclaimed count.
  #
  # There is a fifth reader that is not a script: `shell-hook zsh` is consumed as
  # `eval "$(bin/agent-worktree shell-hook zsh)"` from the login shell. Usage
  # therefore goes to STDERR and never stdout — CliArgGuard.guard! routes a
  # non-zero help there for exactly this reason — so a probe can never be eval'd
  # into the operator's shell.
  #
  # 1 is also what `usage` has always returned here, so nothing that already reads
  # this CLI's exit codes changes behaviour. The refusal exits 2, the shared guard's
  # fixed code, matching bin/release, bin/qa-server and the guarded shell scripts.
  HELP_EXIT = 1

  # The whole-CLI usage text. It lives HERE, not in bin/agent-worktree, so the
  # dispatcher's fall-through and every per-subcommand `--help` print the SAME text
  # from one place — the property that let bin/qa-server's usage stay honest.
  USAGE = <<~TEXT.freeze
    bin/agent-worktree - hidden worktrees + isolated local stacks

      apps
      list [app]
      plan <app> <task-slug> [type]
      new <app> <task-slug> [type] [--start]
      bind-task <app> <task-slug> <task-record-slug-or-url>
      whereami [app task-slug] [--json|--shell]
      shell-hook zsh
      env <app> <task-slug>
      up <app> <task-slug>
      test <app> <task-slug> [-- rails-test-args]
      status <app> <task-slug>
      finish <app> <task-slug> [--push] [--pr]
      restore-primary <app> [--dry-run]
      doctor [app]
      snapshot [app] [--write]
      cleanup [app] [--write]
      cleanup [app] --reclaim [--yes]
      sweep-orphan-dbs [--yes]
      remove <app> <task-slug> [--force] [--yes]
      down <app> <task-slug>

      remove --force: override the content-on-<base> guard ONLY for a
        merge-verified branch (a merged PR on GitHub). Never overrides
        the dirty or not-git-registered guards.
      sweep-orphan-dbs: DRY RUN by default. Lists desk-shaped databases with
        no live desk; --yes drops them, skipping any with open connections.
      scale [status|out|in]
      scale --provision [--yes]

    Environment:
      AGENT_REDIS_MIN_DB         first Redis DB in the worktree band (default 9)
      AGENT_REDIS_MAX_DB         override the band's top DB (default: derived from band size)
      AGENT_REDIS_FLOOR          steady-state band size in slots (default 20)
      AGENT_REDIS_STEP           grow/shrink increment in slots (default 10)
      AGENT_REDIS_PHYSICAL_TARGET  Redis `databases` target for --provision (default 64)
      AGENT_REDIS_CONF           brew redis.conf path for --provision (default <brew>/etc/redis.conf)

    Examples:
      bin/agent-worktree plan turf-monster button-color
      bin/agent-worktree new turf-monster button-color
      bin/agent-worktree up turf-monster button-color
  TEXT

  # THE DICTIONARY. One entry per subcommand, in dispatcher order:
  #
  #   :synopsis     — the usage line `--help` answers with.
  #   :consequence  — what the caller is left with on a refusal. Always the honest
  #                   "it did not happen": after a refusal the reader's real
  #                   question is whether the desk, the database or the branch was
  #                   created, and a generic sentence would be vague in the
  #                   dangerous direction.
  #   :bool/:value  — the flags that subcommand ACTUALLY reads, taken from the arm
  #                   itself. Anything else REFUSES rather than being dropped.
  #   :allow_positional — whether bare tokens mean something (an app slug, a task
  #                   slug, a branch type, a scale verb). Where they do not, a stray
  #                   word refuses instead of being silently ignored.
  #   :passthrough  — see below. Exactly one arm has it.
  #
  # A flag is listed ONLY on the arms that read it. `bin/agent-worktree up <app>
  # <task> --yes` now refuses instead of quietly accepting a flag that was never
  # going to do anything — the same silent no-op the release and QA fixes closed one
  # seam over.
  COMMANDS = {
    "apps" => {
      synopsis: "bin/agent-worktree apps",
      consequence: "nothing was read and no desk, port, database or Redis slot was touched",
      bool: [], value: [], allow_positional: false
    },
    "list" => {
      synopsis: "bin/agent-worktree list [app]",
      consequence: "nothing was listed and no desk was touched",
      bool: [], value: [], allow_positional: true
    },
    "plan" => {
      synopsis: "bin/agent-worktree plan <app> <task-slug> [type]",
      consequence: "no plan was printed and NOTHING was allocated — no worktree, port, Redis DB or Postgres DB",
      bool: [], value: [], allow_positional: true
    },
    "sweep-orphan-dbs" => {
      synopsis: "bin/agent-worktree sweep-orphan-dbs [--yes]",
      consequence: "NO database was dropped",
      bool: ["--yes"], value: [], allow_positional: false
    },
    "new" => {
      synopsis: "bin/agent-worktree new <app> <task-slug> [type] [--start]",
      consequence: "NO worktree, branch, port, Redis DB, Postgres database, stack env or context marker was created",
      bool: ["--start"], value: [], allow_positional: true
    },
    "env" => {
      synopsis: "bin/agent-worktree env <app> <task-slug>",
      consequence: "nothing was printed and no desk was touched",
      bool: [], value: [], allow_positional: true
    },
    "bind-task" => {
      synopsis: "bin/agent-worktree bind-task <app> <task-slug> <task-record-slug-or-url>",
      consequence: "the task was NOT bound — no stack env and no context marker was written",
      bool: [], value: [], allow_positional: true
    },
    "up" => {
      synopsis: "bin/agent-worktree up <app> <task-slug>",
      consequence: "NO stack was started and no context marker was written",
      bool: [], value: [], allow_positional: true
    },
    # THE ONE FORWARDING ARM — see PASSTHROUGH_NOTE below.
    "test" => {
      synopsis: "bin/agent-worktree test <app> <task-slug> [-- rails-test-args]",
      consequence: "NO test database was prepared, no asset was built and no test ran",
      bool: [], value: [], allow_positional: true, passthrough: true
    },
    "status" => {
      synopsis: "bin/agent-worktree status <app> <task-slug>",
      consequence: "nothing was reported and NO context marker was written",
      bool: [], value: [], allow_positional: true
    },
    "whereami" => {
      synopsis: "bin/agent-worktree whereami [app task-slug] [--json|--shell]",
      consequence: "nothing was reported and no desk was touched",
      bool: ["--json", "--shell"], value: [], allow_positional: true
    },
    "shell-hook" => {
      synopsis: "bin/agent-worktree shell-hook zsh",
      consequence: "no hook was printed, so nothing was eval'd into the shell",
      bool: [], value: [], allow_positional: true
    },
    "finish" => {
      synopsis: "bin/agent-worktree finish <app> <task-slug> [--push] [--pr]",
      consequence: "NOTHING was pushed and no PR was opened",
      bool: ["--push", "--pr"], value: [], allow_positional: true
    },
    "restore-primary" => {
      synopsis: "bin/agent-worktree restore-primary <app> [--dry-run]",
      consequence: "the primary checkout was NOT touched",
      bool: ["--dry-run"], value: [], allow_positional: true
    },
    "doctor" => {
      synopsis: "bin/agent-worktree doctor [app]",
      consequence: "no desk was inspected and nothing was changed",
      bool: [], value: [], allow_positional: true
    },
    "snapshot" => {
      synopsis: "bin/agent-worktree snapshot [app] [--write]",
      consequence: "the worktree registry was NOT refreshed",
      bool: ["--write"], value: [], allow_positional: true
    },
    "cleanup" => {
      synopsis: "bin/agent-worktree cleanup [app] [--write] | cleanup [app] --reclaim [--yes]",
      consequence: "NO desk was filed, removed or reclaimed, and no Redis slot was released",
      bool: ["--reclaim", "--yes", "--write"], value: [], allow_positional: true
    },
    "remove" => {
      synopsis: "bin/agent-worktree remove <app> <task-slug> [--force] [--yes]",
      consequence: "the desk still exists — no stack was stopped, no worktree or branch removed, no database dropped",
      bool: ["--yes", "--force"], value: [], allow_positional: true
    },
    "down" => {
      synopsis: "bin/agent-worktree down <app> <task-slug>",
      consequence: "NO stack was stopped",
      bool: [], value: [], allow_positional: true
    },
    "scale" => {
      synopsis: "bin/agent-worktree scale [status|out|in] | scale --provision [--yes]",
      consequence: "the persisted Redis band was NOT changed and Redis was not restarted",
      bool: ["--provision", "--yes"], value: [], allow_positional: true
    }
  }.freeze

  # WHY `test` FORWARDS AND EVERY OTHER ARM DOES NOT.
  #
  # `test <app> <task-slug> [-- rails-test-args]` is a DECLARED pass-through: the arm
  # destructures `app_name, raw_task, *rest = ARGV` and hands `rest` to
  # `sh("bin/rails", "test", *rest)`. Those tokens are not this script's to account
  # for — they are minitest's — and both spellings are in real use: bare paths
  # (`test <app> <task> test/models/x_test.rb`, which bin/agent-worktree's own
  # prepare_test_env header and test/lib/agent_worktree_test.rb:1135 both quote) and
  # flags after `--`. A dictionary check over that tail would refuse `-n /pattern/`
  # and `--` itself, wedging the documented form — a top-level guard wearing a
  # per-arm guard's clothes, which is the mistake bin/agent-runtime's `codex-update`
  # arm exists to avoid.
  #
  # So this arm gets the OTHER half of the guard and only that half: the whole-line
  # help scan. That is precisely the defect here — `test <app> <task> --help` reached
  # `clear_orphan_test_procs` (which SIGKILLs matching processes) and
  # `prepare_test_env` (which creates the desk's Postgres test database and builds
  # the Tailwind bundle) before shelling `bin/rails test --help`. Answering the probe
  # costs the operator nothing: `bin/rails test --help` is one command away inside
  # the desk, and needs none of the hermetic env this wrapper exists to provide.
  PASSTHROUGH_NOTE = "help-scan only; the tail belongs to bin/rails test"

  # True when the named subcommand forwards its tail to another tool, so the caller
  # must scan for help and then hand the line on UNTOUCHED rather than classify it.
  # Read from COMMANDS so there is exactly one dictionary and no second list to
  # drift out of step with it.
  def passthrough?(command)
    COMMANDS.fetch(command.to_s, {})[:passthrough] == true
  end

  # The keyword set bin/agent-worktree hands CliArgGuard.guard! for `command` — nil
  # when the token is not a subcommand at all (a bare `--help`, a typo, an empty
  # line), which the dispatcher's own `else` already answers with usage and exit 1.
  #
  # Returned as ONE hash so the guard call in bin/agent-worktree and the tests that
  # exercise it are the SAME call, with no second copy of the dictionary to drift.
  def guard_args(command)
    spec = COMMANDS[command.to_s]
    return nil unless spec

    # The consequence rides the USAGE TEXT, not only the refusal line, because the
    # shared guard prints `consequence` only when it REFUSES — and help is not a
    # refusal, it is an answer. Without this, someone who typed `new <app> <task>
    # --help`, watched it exit non-zero and read a bare synopsis still does not know
    # whether the desk got created, which is the exact question this defect plants.
    {
      program: "bin/agent-worktree #{command}",
      usage: "usage: #{spec[:synopsis]}\n       NOT RUN — #{spec[:consequence]}.\n\n#{USAGE}",
      consequence: spec[:consequence],
      bool: spec[:bool],
      value: spec[:value],
      allow_positional: spec[:allow_positional],
      help_exit: HELP_EXIT
    }
  end
end
