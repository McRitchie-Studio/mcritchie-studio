# frozen_string_literal: true

# [unit] CliArgGuard — the shared "account for every argument" guard for flat bin/ scripts.
#
# The behavioural proof that this guard stops a real mutation lives one tier up, in
# test/lib/archive_docs_help_guard_test.rb, which spawns the real CLI against a real
# git repo and asserts the tree and index are byte-identical. THIS file pins the
# decision table underneath it: what counts as accounted-for, what refuses, and — the
# half that is easy to get wrong and expensive to get wrong — what must STILL DISPATCH.
#
# A guard that refuses everything is indistinguishable from a guard that works, and it
# fails silently and expensively: refuse bin/release's own line and the archive beat
# aborts every release. So the dispatch cases below carry as much weight as the
# refusals.
#
#   ruby -Itest test/lib/cli_arg_guard_test.rb

require "minitest/autorun"
require "stringio"
require_relative "../../bin/lib/cli_arg_guard"

class CliArgGuardTest < Minitest::Test
  # Stops execution the way `exit` would, so a test can assert on what the guard did
  # BEFORE it would have handed control back to a script that then mutates.
  class Exited < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super("exited #{code}")
    end
  end

  def setup
    @out = StringIO.new
    @err = StringIO.new
  end

  def guard(argv, **overrides)
    CliArgGuard.guard!(
      argv,
      program: "archive-docs",
      usage: "usage: bin/archive-docs [--repo <path>] [--dry-run]",
      consequence: "NOTHING was archived and the ledger was NOT rolled.",
      bool: %w[--dry-run --json],
      value: %w[--repo --ledger-cutoff],
      out: @out,
      err: @err,
      exiter: ->(code) { raise Exited, code },
      **overrides
    )
  end

  # --- help ------------------------------------------------------------------

  def test_help_exits_before_anything_can_act
    error = assert_raises(Exited) { guard(["--help"]) }

    assert_equal 0, error.code, "an explicit --help is a successful request"
    assert_includes @out.string, "usage: bin/archive-docs"
  end

  def test_short_h_is_the_same_probe
    error = assert_raises(Exited) { guard(["-h"]) }
    assert_equal 0, error.code
    assert_includes @out.string, "usage:"
  end

  # From ANY position. A parser that only inspects ARGV[0] hands the mutation to the
  # second spelling — and `--repo=x --help` is the natural way to ask what else a
  # command takes once you have already typed half the line.
  def test_help_is_honoured_from_any_position
    ["--repo=/tmp/x --help", "--dry-run -h", "--help --repo=/tmp/x"].each do |line|
      @out = StringIO.new
      error = assert_raises(Exited) { guard(line.split) }
      assert_equal 0, error.code, "help must win anywhere on the line: #{line}"
      assert_includes @out.string, "usage:", line
    end
  end

  # Help must be answerable on a line that is otherwise MALFORMED. Reporting the bad
  # flag instead of the usage would answer a question nobody asked, and the person
  # typing this is by definition the one who does not know the flags yet.
  def test_help_wins_over_an_unrecognized_flag_on_the_same_line
    error = assert_raises(Exited) { guard(["--bogus", "--help"]) }

    assert_equal 0, error.code
    assert_includes @out.string, "usage:"
    assert_empty @err.string, "a help request is not a refusal"
  end

  # Where exit 0 carries a meaning beyond "it ran" — bin/ledger-guard's 0 is a green
  # verdict, bin/devops-shift's 0 asserts "you are on shift" — help must not answer
  # with it, and its usage goes to stderr so it is never parsed as that channel's value.
  def test_a_script_whose_zero_means_a_verdict_can_refuse_the_help_exit_code
    error = assert_raises(Exited) { guard(["--help"], help_exit: 1) }

    assert_equal 1, error.code
    assert_includes @err.string, "usage:"
    assert_empty @out.string, "a non-zero help must not write to the verdict channel"
  end

  # --- refusal ---------------------------------------------------------------

  def test_an_unrecognized_flag_refuses
    error = assert_raises(Exited) { guard(["--dry-runn"]) }

    assert_equal 2, error.code
    assert_includes @err.string, "unrecognized argument"
    assert_includes @err.string, "--dry-runn"
    assert_includes @err.string, "NOTHING was archived", "the refusal names what the caller is left with"
    assert_includes @err.string, "usage:", "…and how to get it right"
  end

  # A single-dash token was the worse half of the original defect: hand-rolled parsers
  # that only ever looked at "--" did not even record it as ignored. It vanished,
  # side effect and all.
  def test_a_single_dash_token_is_not_invisible
    error = assert_raises(Exited) { guard(["-x"]) }

    assert_equal 2, error.code
    assert_includes @err.string, "-x"
  end

  def test_a_bare_positional_refuses_when_the_script_takes_none
    error = assert_raises(Exited) { guard(["accepted"]) }

    assert_equal 2, error.code
    assert_includes @err.string, "accepted"
  end

  def test_every_unaccounted_argument_is_named_not_just_the_first
    assert_raises(Exited) { guard(["--bogus", "--dry-run", "-q"]) }

    assert_includes @err.string, "--bogus"
    assert_includes @err.string, "-q"
    assert_includes @err.string, "arguments", "plural when there is more than one"
  end

  # A value flag that consumed nothing is a usage error, not a boolean. Storing `true`
  # is how bin/devops-shift once labelled a shift after a holder called "true", and how
  # a trailing `--repo` would sweep a repository named "true".
  def test_a_value_flag_with_nothing_to_consume_refuses
    error = assert_raises(Exited) { guard(["--repo"]) }

    assert_equal 2, error.code
    assert_includes @err.string, "--repo"
  end

  def test_a_value_flag_followed_by_another_flag_refuses
    assert_raises(Exited) { guard(["--repo", "--dry-run"]) }

    assert_includes @err.string, "--repo",
                    "--dry-run must not be swallowed as the repo path"
  end

  def test_an_unknown_flag_in_equals_form_refuses
    assert_raises(Exited) { guard(["--repoo=/tmp/x"]) }

    assert_includes @err.string, "--repoo=/tmp/x"
  end

  # --- dispatch: the half that must NOT refuse -------------------------------

  def test_a_clean_line_dispatches_with_its_values_intact
    parsed = guard(["--repo=/tmp/x", "--dry-run"])

    assert_equal "/tmp/x", parsed.first("--repo")
    assert parsed.bool?("--dry-run")
    refute parsed.bool?("--json")
    assert_empty @err.string
  end

  # Both spellings must reach the same place. A script whose own parser understood only
  # `--repo=x` SILENTLY IGNORED `--repo /path` and swept its default repo instead — the
  # same silent substitution as a dropped flag, and strictly worse, because it mutates
  # a tree the caller never named.
  def test_the_space_form_and_the_equals_form_agree
    assert_equal "/tmp/x", guard(["--repo", "/tmp/x"]).first("--repo")
    assert_equal "/tmp/x", guard(["--repo=/tmp/x"]).first("--repo")
  end

  def test_an_empty_line_dispatches
    parsed = guard([])

    assert_empty parsed.bools
    assert_nil parsed.first("--repo")
  end

  def test_a_value_containing_an_equals_sign_survives
    assert_equal "a=b=c", guard(["--repo=a=b=c"]).first("--repo")
  end

  def test_a_repeatable_flag_keeps_every_occurrence
    parsed = guard(["--repo=/one", "--repo=/two"])

    assert_equal ["/one", "/two"], parsed.all("--repo")
    assert_equal "/one", parsed.first("--repo"), "first() is the first occurrence"
  end

  def test_positionals_are_kept_when_the_script_allows_them
    parsed = guard(["acquire", "avi", "--dry-run"], allow_positional: true)

    assert_equal %w[acquire avi], parsed.positionals
    assert parsed.bool?("--dry-run")
  end

  # --- the pure core ---------------------------------------------------------

  def test_classify_reports_bad_arguments_without_any_side_effect
    parsed, bad = CliArgGuard.classify(
      ["--dry-run", "--nope", "--repo=/tmp/x"],
      bool: %w[--dry-run], value: %w[--repo]
    )

    assert_equal ["--nope"], bad
    assert_equal "/tmp/x", parsed.first("--repo")
    assert parsed.bool?("--dry-run"), "the accountable flags still parse alongside the bad one"
  end

  def test_help_predicate_matches_both_spellings_only
    assert CliArgGuard.help?(["--help"])
    assert CliArgGuard.help?(["--dry-run", "-h"])
    refute CliArgGuard.help?(["--helpful"])
    refute CliArgGuard.help?(["-help"])
    refute CliArgGuard.help?([])
  end
end
