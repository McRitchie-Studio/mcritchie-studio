class Release
  # Pure ARGV-parsing helpers for the `bin/release` CLI. Like Release::GemfileRepin
  # and Release::ShipSequence this is deliberately IO-free and Rails-free: it takes
  # an args array in, mutates it (deleting the consumed flags), and returns the
  # parsed value out — so the flag-consumption logic lives in ONE unit-tested place
  # instead of being mirrored as a handful of top-level `def`s in the shell script.
  # (bin/release `require_relative`s this file directly, so it must load standalone
  # with no Rails dependency.)
  #
  # All three helpers MUTATE `args` (deleting what they consume), mirroring the old
  # in-place ARGV.delete / ARGV.delete_at parsing exactly — so a later subcommand
  # parser never re-sees a flag the dispatcher already handled.
  #
  # IT ALSO OWNS THE ARGUMENT DICTIONARY (COMMANDS below) that bin/release's
  # `--help`/unknown-argument guard is built from. That belongs here, next to the
  # parsers, because the dictionary and the parsers have to agree about what a flag
  # IS: a guard that blesses a spelling the parser then drops silently is the same
  # defect one seam over.
  module Cli
    module_function

    # A boolean flag: delete `flag` from `args`, return whether it was present.
    # Replaces the `ARGV.delete("--x") ? true : false` idiom.
    def take_flag(args, flag)
      !args.delete(flag).nil?
    end

    # The index of the FIRST token that spells `flag`, in either accepted form:
    # `--flag value` or `--flag=value`. Both forms, on purpose — see the note on
    # opt_value below.
    def flag_index(args, flag)
      args.index { |a| a.to_s == flag || a.to_s.start_with?("#{flag}=") }
    end

    # A single-value option: delete the FIRST `flag` and its value, returning that
    # value (nil if the flag is absent).
    #
    # BOTH `--flag value` AND `--flag=value` parse. The `=` form is not a
    # convenience — it is the price of the shared argument guard
    # (bin/lib/cli_arg_guard.rb), whose `classify` accepts both spellings for every
    # declared value flag. If this parser understood only `--slug rel-x`, then
    # `bin/release prepare --slug=rel-x` would pass the guard (accounted for!) and
    # then be SILENTLY DROPPED here — prepare would invent its own slug and promote
    # under it. One parser blessing what the other discards is exactly the
    # silent-substitution shape this whole change exists to close, so both
    # spellings resolve to the same value in one place.
    def opt_value(args, flag)
      return nil unless (i = flag_index(args, flag))

      token = args.delete_at(i)          # drop the flag (or the whole --flag=value token)
      return token.to_s.split("=", 2).last unless token.to_s == flag

      args.delete_at(i)                  # drop + return its value (now at the same index)
    end

    # A repeatable option: delete EVERY occurrence of `flag` + its value, returning
    # the collected values (nils compacted out). Same dual spelling as opt_value.
    def opt_values(args, flag)
      vals = []
      while (i = flag_index(args, flag))
        token = args.delete_at(i)
        vals << (token.to_s == flag ? args.delete_at(i) : token.to_s.split("=", 2).last)
      end
      vals.compact
    end

    # The positional (non-flag) tokens — the one-or-more task slugs `bin/release
    # merge` accepts. NON-mutating (unlike the flag parsers above): `merge` reads
    # nothing else from args afterward, so there's no consumed-flag to hide from a
    # later parser. Any `-`-prefixed token is treated as a flag and excluded, so a
    # stray flag never lands in the slug list.
    def positional_slugs(args)
      Array(args).reject { |a| a.to_s.start_with?("-") }
    end

    # ------------------------------------------------------------------------
    # THE ARGUMENT DICTIONARY — what bin/release's `--help`/unknown-arg guard
    # is built from.
    #
    # THE DEFECT IT CLOSES, and why it is the worst instance of its class.
    # bin/release dispatches with `case ARGV.shift`, and each subcommand then
    # hand-reads only the flags it knows (opt_value/opt_values/take_flag above).
    # An argument none of them recognise is not an error — it is nothing. So the
    # BARE form `bin/release --help` was safe (it shifts "--help", matches no
    # `when`, and prints usage), while
    #
    #     bin/release prepare --yes --help
    #
    # shifted "prepare", dispatched, and PROMOTED `accepted` onto `release` across
    # every repo, merged the batch PRs, recorded membership on the production
    # board and deployed QA — with ASSUME_YES set, so nothing stopped to ask. The
    # operator had typed the universal safe probe.
    #
    # That is the same class as PR #974 (review claim), PR #980 (release claim),
    # bin/devops-shift, and the six scripts swept onto bin/lib/cli_arg_guard.rb on
    # 2026-08-31 — but one rung worse than any of them, because the side effect is
    # not a local file or a lease: it is shared branch state in every repo, a
    # production board write, and (on `ship`) a RubyGems publish, whose version can
    # never be re-pushed.
    #
    # WHY A TABLE RATHER THAN A GUARD CALL PER SUBCOMMAND. The guard needs a
    # DICTIONARY — the exact set of flags each subcommand accounts for — and that
    # set is only discoverable by reading all 7,400 lines of bin/release.rb. Kept
    # here, beside the parsers that consume those same flags, the two can be
    # checked against each other and unit-tested without running a release.
    #
    #   :synopsis     — the per-subcommand usage line `--help` answers with.
    #   :consequence  — what the operator is left with on a refusal. Always the
    #                   honest "it did not happen": the reader's real question is
    #                   whether the mutation ran, and a generic sentence would be
    #                   vague in the dangerous direction.
    #   :bool/:value  — the flags that subcommand actually reads. Anything else is
    #                   REFUSED rather than guessed at.
    #   :allow_positional — whether bare tokens mean something (a task slug, a
    #                   release slug). Where they don't, a stray word refuses
    #                   instead of being silently ignored.
    #
    # NOT LISTED, on purpose: the five GLOBAL flags (--dry-run, --prod, --local,
    # --yes, --skip-test-gate). bin/release consumes those from ARGV at load time,
    # BEFORE the dispatcher runs, so by the time the guard reads the line they are
    # already gone and listing them here would describe a token the guard can never
    # see. (`--skip-test-gate` is read only by `ship`'s test gate; passing it to
    # another subcommand is still a silent no-op — a smaller instance of this same
    # class, filed rather than fixed here because closing it means moving the
    # global parse below the dispatch.)
    COMMANDS = {
      "init" => {
        synopsis: "bin/release init",
        consequence: "no ladder branch was created or pushed in any repo",
        bool: [], value: [], allow_positional: false
      },
      "merge" => {
        synopsis: "bin/release merge <task-slug> [<task-slug>...] [--override]",
        consequence: "nothing was promoted onto `release` and no membership was recorded",
        bool: ["--override"], value: [], allow_positional: true
      },
      "prepare" => {
        synopsis: "bin/release prepare [--task SLUG ...] [--slug rel-YYYY-MM-DD-name] [--expedite]",
        consequence: "NOTHING was promoted onto `release`, merged, recorded on the board, or deployed to QA",
        bool: ["--expedite"], value: ["--task", "--slug"], allow_positional: false
      },
      "eject" => {
        synopsis: "bin/release eject <task-slug> [--feedback \"…\"]",
        consequence: "no task was ejected from the candidate and no feedback was recorded",
        bool: [], value: ["--feedback"], allow_positional: true
      },
      "ship" => {
        synopsis: "bin/release ship [--finalize-only [<release>]] [--by NAME] [--slug REL] " \
                  "[--reason \"…\" (with the global --skip-test-gate)]",
        consequence: "NOTHING was pushed to `main`, deployed to production, or published to RubyGems",
        bool: ["--finalize-only"], value: ["--by", "--slug", "--reason"], allow_positional: true
      },
      "finalize" => {
        synopsis: "bin/release finalize [<release>] [--by NAME] [--slug REL]",
        consequence: "the release was not finalized and no task was flipped",
        bool: [], value: ["--by", "--slug"], allow_positional: true
      },
      "status" => {
        synopsis: "bin/release status [--clean-only] [--task SLUG]",
        # The sharpest one in the table. `status --clean-only` exits 0 to MEAN
        # "the accepted → release → main ladder is clean, the expedite may
        # proceed" — `deploy-with-task` reads that exit code as a gate. So this
        # refusal (and `--help`) must never exit 0, and must say plainly that it
        # is not a verdict.
        consequence: "nothing was read or written — and this is NOT a clean-ladder verdict",
        bool: ["--clean-only"], value: ["--task"], allow_positional: false
      },
      "archive" => {
        synopsis: "bin/release archive",
        consequence: "no task was archived, no worktree reclaimed, and no artifact swept",
        bool: [], value: [], allow_positional: false
      },
      "retro" => {
        synopsis: "bin/release retro [<release>] [--worked \"…\"] [--friction \"…\"] " \
                  "[--followup \"…\"] [--file-tasks]",
        consequence: "no retro was written and no follow-up was filed",
        bool: ["--file-tasks"], value: ["--worked", "--friction", "--followup"], allow_positional: true
      }
    }.freeze

    # The whole-CLI usage line — printed for a bare `bin/release`, an unknown
    # subcommand, and appended to every per-subcommand `--help`.
    USAGE = "usage: bin/release {init|merge <task-slug> [<task-slug>...]|prepare|eject <task-slug>|" \
            "ship [--finalize-only [<release>]]|finalize [<release>]|status|archive|retro} " \
            "[--task SLUG ...] [--slug REL] [--by NAME] [--feedback …] [--clean-only] [--expedite] " \
            "[--worked …] [--friction …] [--followup …] [--file-tasks] [--local] [--dry-run] [--yes]"

    # The global flags, consumed before the dispatcher — named in every
    # per-subcommand help so the guard's silence about them is not read as
    # "unsupported".
    GLOBAL_FLAGS = "[--dry-run] [--local] [--yes] [--skip-test-gate] (global — consumed before dispatch)"

    # `--help` and a refusal both exit 1, never 0.
    #
    # The shared guard defaults help to exit 0 because on most scripts 0 means only
    # "this ran". Not here: `bin/release status --clean-only` exits 0 to assert a
    # CLEAN LADDER, and `deploy-with-task` gates an expedite on it. A `--help` that
    # exited 0 would hand that act a green verdict it never computed. 1 is also what
    # the bare `bin/release --help` has always returned, so nothing that reads this
    # CLI's exit codes changes.
    HELP_EXIT = 1

    # The full keyword set bin/release hands CliArgGuard.guard! for `command` —
    # nil when the token is not a subcommand at all (a bare `--help`, a typo), which
    # the dispatcher's own `else` already answers with usage + exit 1.
    #
    # Returned as ONE hash so the guard call in bin/release.rb and the tests that
    # exercise it are the SAME call, with no second copy of the dictionary to drift.
    def guard_args(command)
      spec = COMMANDS[command.to_s]
      return nil unless spec

      {
        program: "bin/release #{command}",
        usage: "usage: #{spec[:synopsis]}\n       #{GLOBAL_FLAGS}\n\n#{USAGE}",
        consequence: spec[:consequence],
        bool: spec[:bool],
        value: spec[:value],
        allow_positional: spec[:allow_positional],
        help_exit: HELP_EXIT
      }
    end
  end
end
