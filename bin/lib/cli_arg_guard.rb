# frozen_string_literal: true

# CliArgGuard — account for EVERY argument before a flat bin/ script acts.
#
# THE DEFECT CLASS THIS CLOSES, and it has now cost this ecosystem five times.
# A script hand-parses its flags with `ARGV.include?("--dry-run")` and
# `ARGV.grep(/\A--repo=/)`, scans for no help flag, and has no notion of an
# argument it does not recognize. So an unrecognized token — `--help` above all
# — matches nothing, is silently dropped, and the script RUNS ITS REAL ACTION on
# a command line nobody accounted for.
#
#   PR #974  bin/lib/review_claim_cli.rb   — `--help` took a real review claim
#   PR #980  bin/lib/release_claim_cli.rb  — same shape, release lane
#   PR #?    bin/devops-shift              — `acquire avi --help` TOOK THE SHIFT
#   2026-08-31  bin/archive-docs           — `--help` ROLLED THE DOCS LEDGER,
#               rewriting docs/agents/maintenance/delete-later.md by -41 lines and
#               staging a second file, for an operator who was asking what the
#               command does.
#   2026-08-31  bin/release                — `prepare --yes --help` PROMOTED
#               `accepted` onto `release` in EVERY repo, merged the batch PRs,
#               wrote membership to the PRODUCTION board and deployed QA.
#
# THE FIFTH ONE IS THE ONE TO READ, because it sat one POSITION over rather
# than one script over. bin/release dispatches with `case ARGV.shift`, so the
# BARE `bin/release --help` was safe — it matched no `when` and printed usage —
# and the record classified it safe on exactly that evidence. The flag only
# vanished once a subcommand had been shifted off the front. A guard that reads
# the WHOLE line closes both halves; a guard that reads ARGV[0] closes the half
# that was never dangerous. bin/release also shows the shape this retrofit takes
# on a multi-command script: a per-subcommand dictionary (Release::Cli::COMMANDS)
# fed to ONE guard! call placed ahead of the dispatcher.
#
# The first three were each fixed in place, bespoke, and the third was called
# "the third and last member of the family". It was not. The class kept costing
# because every fix was a private copy and the next script had no way to inherit
# it. This lib is that inheritance: a flat script gets the whole guard in one
# call, so the cheap thing and the safe thing are finally the same thing.
#
# WHY `--help` SPECIFICALLY IS THE DANGEROUS ONE. It is the universal safe probe.
# Every agent and operator reaches for it on an unfamiliar command PRECISELY
# because it is expected to do nothing. A mutating `--help` turns the safest
# available action into a destructive one — and when the target is docs, the loss
# is silent audit product with no reflog behind it.
#
# THE RULE: an argument this script cannot account for REFUSES. Refusing is
# strictly safer than guessing, because guessing means running a mutation against
# a line whose meaning was never established.
#
# WHAT THIS LIB DELIBERATELY DOES NOT DO. It does not retrofit the three claim CLIs
# above. Each carries its own usage text, its own per-subcommand
# REFUSAL_CONSEQUENCE table, and its own passing tests; rewriting them onto this
# would be churn with no safety gain. This serves the FLAT scripts — the ones
# with no class to hang a guard on, which is exactly where the remaining
# instances of the defect live.
#
# Unit tests: test/lib/cli_arg_guard_test.rb
module CliArgGuard
  # The two spellings honored everywhere in this bin/ — bin/task, bin/ledger-guard,
  # and the three claim CLIs. Someone probing a script has no way to know it is a
  # different parser, so every parser answers to the same two.
  HELP_FLAGS = %w[--help -h].freeze

  # A parsed command line. `values` maps each value-flag to its occurrences (an
  # array, so a repeatable flag keeps them all); `bools` lists the boolean flags
  # seen; `positionals` the bare tokens.
  Parsed = Struct.new(:values, :bools, :positionals, keyword_init: true) do
    def bool?(flag) = bools.include?(flag)
    def first(flag) = values.fetch(flag, []).first
    def all(flag)   = values.fetch(flag, [])
  end

  module_function

  # Is a help flag anywhere on the line? ANY position, on purpose: `--repo=x --help`
  # is the same request as `--help`, and a parser that only checks ARGV[0] hands the
  # mutation to the second spelling.
  def help?(argv)
    argv.any? { |arg| HELP_FLAGS.include?(arg) }
  end

  # The PURE core: split a command line against a flag dictionary.
  #
  # Both `--flag=value` and `--flag value` parse, matching bin/ledger-guard. That
  # dual form is a safety property, not a convenience: a script whose own parser
  # only understood `--repo=x` would SILENTLY IGNORE `--repo /path` and sweep its
  # default repo instead — the same silent-substitution bug one seam over. Parsing
  # here and having the caller read the parsed values means there is exactly one
  # parser and no second, laxer one to disagree with it.
  #
  # Returns [Parsed, bad] where `bad` is every token that could not be accounted
  # for: an unrecognized flag, a single-dash token, or a value-flag left with
  # nothing to consume (a trailing `--repo` would otherwise store `true`, and
  # `true.to_s` is the string "true" — that is how devops-shift once labelled a
  # shift after a holder called "true").
  def classify(argv, bool: [], value: [], allow_positional: false)
    values = Hash.new { |h, k| h[k] = [] }
    bools = []
    positionals = []
    bad = []

    rest = argv.dup
    until rest.empty?
      arg = rest.shift

      if arg.include?("=") && arg.start_with?("--")
        name, val = arg.split("=", 2)
        if value.include?(name)
          values[name] << val
        else
          bad << arg
        end
      elsif value.include?(arg)
        # A value flag must consume a token that is not itself a flag.
        nxt = rest.first
        if nxt.nil? || nxt.start_with?("-")
          bad << arg
        else
          values[arg] << rest.shift
        end
      elsif bool.include?(arg)
        bools << arg
      elsif arg.start_with?("-")
        bad << arg
      elsif allow_positional
        positionals << arg
      else
        bad << arg
      end
    end

    [Parsed.new(values: values, bools: bools, positionals: positionals), bad]
  end

  # The one call a flat script makes, BEFORE it does anything else.
  #
  # `help_exit` is a decision each script owns, and it is not always 0. Where exit 0
  # carries a MEANING beyond "the command ran" — bin/ledger-guard's 0 is a green
  # verdict, bin/devops-shift's 0 is the assertion "you are on shift" — help must
  # not answer with it. Where 0 means only "this ran", 0 is right and is what every
  # operator expects from an explicit `--help`.
  #
  # `consequence` names what the caller is left with on a refusal. One generic
  # sentence would be wrong in the dangerous direction: the reader needs to know
  # whether the side effect happened, and the honest answer is always "it did not".
  def guard!(argv, program:, usage:, consequence:, bool: [], value: [],
             allow_positional: false, help_exit: 0,
             out: $stdout, err: $stderr, exiter: nil)
    exiter ||= ->(code) { exit code }

    # HELP FIRST, ahead of even the dictionary check. A probe must be answerable on
    # a line that is otherwise malformed, and on a repo whose state would make the
    # real action refuse — `--help` has to work when everything else is broken.
    if help?(argv)
      help_exit.zero? ? out.puts(usage) : err.puts(usage)
      return exiter.call(help_exit)
    end

    parsed, bad = classify(argv, bool: bool, value: value, allow_positional: allow_positional)
    return parsed if bad.empty?

    noun = bad.length == 1 ? "argument" : "arguments"
    err.puts("#{program}: unrecognized #{noun} #{bad.map(&:inspect).join(', ')} — #{consequence}")
    err.puts
    err.puts(usage)
    exiter.call(2)
  end
end
