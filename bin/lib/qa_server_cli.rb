# frozen_string_literal: true

# QaServerCli — the argument DICTIONARY bin/qa-server's `--help`/unknown-argument
# guard is built from. Pure, IO-free and Rails-free (bin/qa-server
# `require_relative`s it directly, so it must load standalone), which is what lets
# every verdict below be proven in a unit test WITHOUT running the script.
#
# THE DEFECT IT CLOSES, and it is the most expensive shape this class has produced
# on a per-probe basis:
#
#     bin/qa-server provision <app> --yes --help
#
# PROVISIONED A QA SERVER FOR REAL. The old dispatcher did `ARGV.delete("--yes")`
# to set assume_yes and then called `run_provision(ARGV[0])`; `--help` matched
# nothing, was never inspected, and simply fell off the end of the line. So the
# universal safe probe ran `heroku create`, `heroku addons:create` (billable
# add-ons), `heroku domains:add`, `certs:auto:enable` and a config-var PATCH
# carrying real secrets — with the confirmation ALREADY SUPPRESSED by the `--yes`
# sitting next to it. The two flags together are worse than either alone: `--yes`
# removed the one thing that would have stopped it.
#
# `deploy` carried the same shape one argument over: `bin/qa-server deploy <app>
# origin/main --yes --help` force-pushed to the QA app's Heroku remote and scaled
# its dynos, because `--help` was neither app_name nor ref and nothing looked at it.
#
# This is the sixth instance of the class (PR #974 review claim, PR #980 release
# claim, bin/devops-shift, bin/archive-docs, bin/release) and the FIRST one caught
# by reading a manifest rather than by an operator watching a command act. It is
# fixed with the SHARED guard (bin/lib/cli_arg_guard.rb) reading the shared
# dictionary below, exactly as bin/release does — not a private parser, because a
# private parser is why the previous five each had to be discovered the hard way.
module QaServerCli
  module_function

  # WHY EXIT 1 AND NEVER 0 — this is the load-bearing decision in the file, and it
  # is not the shared guard's default.
  #
  # bin/qa-server is not only run by hand. bin/release.rb:3198 shells it:
  #
  #     _, qa_ok = sh("bin/qa-server", "deploy", qa_app, "origin/release", "--yes")
  #
  # and `sh` returns `system(...)`'s boolean — so a ZERO exit from this script is
  # read by the release sweep as "the QA deploy SUCCEEDED". `qa_ok` then gates the
  # /up smoke, the qa_smoke release event, and ultimately whether the RC's members
  # flip `reviewed → assembled`. A `--help` or a refusal that exited 0 would hand
  # the sweep a green QA deploy it never performed, and the /up poll would happily
  # confirm it against the PREVIOUSLY deployed code — assembling a release on a
  # deploy that did not happen. That is strictly worse than the guard refusing
  # loudly, so help exits 1 and an unaccounted-for argument exits 2 (the shared
  # guard's fixed code). Neither is ever 0.
  #
  # 1 is also what `usage` has always returned here, so nothing that already reads
  # this CLI's exit codes changes behaviour.
  HELP_EXIT = 1

  # The whole-CLI usage text — printed for a bare `bin/qa-server`, an unknown
  # subcommand, and appended to every per-subcommand `--help`, so there is exactly
  # one copy of it.
  USAGE = <<~TEXT.freeze
    bin/qa-server - stable QA server conductor helper

      list
      plan [app]
      provision <app> [--yes]
      status [app]
      deploy <app> [git-ref] [--yes]

    Examples:
      bin/qa-server list
      bin/qa-server plan turf-monster
      bin/qa-server provision turf-monster --yes
      bin/qa-server status mcritchie-studio
      bin/qa-server deploy turf-monster origin/main --yes
  TEXT

  # THE DICTIONARY. One entry per subcommand:
  #
  #   :synopsis     — the usage line `--help` answers with.
  #   :consequence  — what the caller is left with on a refusal. Always the honest
  #                   "it did not happen": the reader's real question after a
  #                   refusal is whether the Heroku write ran, and a generic
  #                   sentence would be vague in the dangerous direction.
  #   :bool/:value  — the flags that subcommand actually reads. Anything else
  #                   REFUSES rather than being guessed at or dropped.
  #   :allow_positional — whether bare tokens mean something (an app slug, a git
  #                   ref). Where they do not, a stray word refuses instead of
  #                   being silently ignored.
  #
  # `--yes` is listed on the two subcommands that read it, and NOT on the three
  # that do not: `bin/qa-server status foo --yes` now refuses instead of quietly
  # accepting a flag that was never going to do anything, which is the same
  # silent-no-op the release fix filed one seam over.
  COMMANDS = {
    "list" => {
      synopsis: "bin/qa-server list",
      consequence: "nothing was read and no QA app was touched",
      bool: [], value: [], allow_positional: false
    },
    "plan" => {
      synopsis: "bin/qa-server plan [app]",
      consequence: "no plan was printed and NOTHING was provisioned",
      bool: [], value: [], allow_positional: true
    },
    "provision" => {
      synopsis: "bin/qa-server provision <app> [--yes]",
      consequence: "NO Heroku app, add-on, domain, certificate or config var was created or changed",
      bool: ["--yes"], value: [], allow_positional: true
    },
    "status" => {
      synopsis: "bin/qa-server status [app]",
      consequence: "nothing was read and no QA app was touched",
      bool: [], value: [], allow_positional: true
    },
    "deploy" => {
      synopsis: "bin/qa-server deploy <app> [git-ref] [--yes]",
      consequence: "NOTHING was pushed to the QA app, no dyno was scaled, and no deploy was announced",
      bool: ["--yes"], value: [], allow_positional: true
    }
  }.freeze

  # The keyword set bin/qa-server hands CliArgGuard.guard! for `command` — nil when
  # the token is not a subcommand at all (a bare `--help`, a typo, an empty line),
  # which the dispatcher's own `else` already answers with usage + exit 1.
  #
  # Returned as ONE hash so the guard call in bin/qa-server and the tests that
  # exercise it are the SAME call, with no second copy of the dictionary to drift.
  def guard_args(command)
    spec = COMMANDS[command.to_s]
    return nil unless spec

    # The consequence rides the USAGE TEXT, not only the refusal line, because the
    # shared guard prints `consequence` only when it REFUSES an argument — and help
    # is not a refusal, it is an answer. That left the exact question this defect
    # plants in an operator's head unanswered: someone who typed `provision --yes
    # --help`, watched it exit non-zero and read a bare synopsis still does not know
    # whether the QA app got created. Saying it in both places costs one line and a
    # little repetition on the refusal path; leaving it out is vague in the dangerous
    # direction, which is the whole reason this task exists.
    {
      program: "bin/qa-server #{command}",
      usage: "usage: #{spec[:synopsis]}\n       NOT RUN — #{spec[:consequence]}.\n\n#{USAGE}",
      consequence: spec[:consequence],
      bool: spec[:bool],
      value: spec[:value],
      allow_positional: spec[:allow_positional],
      help_exit: HELP_EXIT
    }
  end
end
