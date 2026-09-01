# frozen_string_literal: true

# [unit] bin/qa-server's ARGUMENT GUARD — the decision table under the fix for
# /tasks/qa-server-help-provisions.
#
# THE DEFECT. The old dispatcher deleted `--yes` to set assume_yes and then called
# `run_provision(ARGV[0])`. `--help` was never inspected, so
#
#     bin/qa-server provision <app> --yes --help
#
# dropped the flag and PROVISIONED A QA SERVER FOR REAL — heroku create, billable
# add-ons, domains, ACM, and a config-var PATCH carrying real secrets — with the
# confirmation already suppressed by the `--yes` sitting beside it.
#
# WHY NOTHING HERE RUNS bin/qa-server. The thing under test creates billable
# infrastructure when probed, so "run it and see" is the one experiment that must
# never be performed: if the guard has regressed, the probe IS the outage. This
# file drives the shared guard against the PRODUCTION dictionary
# (QaServerCli::COMMANDS) with an injected exiter, so every verdict is proven with
# the dispatcher never reached. The one real execution — of the read-only `list` —
# lives in test/integration/qa_server_argv_guard_test.rb.
#
# THE HALF THAT IS EASY TO GET WRONG. A guard that refuses everything is
# indistinguishable from a guard that works, and it fails silently and expensively:
# refuse `deploy <app> origin/release --yes` and Avi's whole QA sweep aborts, since
# bin/release.rb:3198 shells exactly that line. So the DISPATCH cases below — every
# distinct invocation shape found in a sweep of the repos and docs — carry as much
# weight as the refusals.
#
#   ruby -Itest test/lib/qa_server_cli_test.rb

require "minitest/autorun"
require "stringio"
require_relative "../../bin/lib/cli_arg_guard"
require_relative "../../bin/lib/qa_server_cli"

class QaServerCliTest < Minitest::Test
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

  # Drive the REAL guard for a full command line, exactly as bin/qa-server's
  # guard_argv! does: resolve the subcommand in the production dictionary, then hand
  # the REST of the line to the shared guard.
  def guard(argv)
    spec = QaServerCli.guard_args(argv.first)
    return :not_a_subcommand unless spec

    CliArgGuard.guard!(argv.drop(1), out: @out, err: @err,
                                     exiter: ->(code) { raise Exited, code }, **spec)
  end

  def refusal(argv)
    guard(argv)
    flunk "#{argv.inspect} was ACCEPTED — it must refuse"
  rescue Exited => e
    e.code
  end

  # --- the regression itself -------------------------------------------------

  # THE bug. Both flags together, in the order an operator would type them.
  def test_provision_yes_help_refuses_and_provisions_nothing
    assert_equal 1, refusal(%w[provision turf-monster --yes --help])

    assert_match(/provision <app>/, @err.string, "the refusal must print the usage it was asked for")
    assert_empty @out.string, "help must not go to stdout here — exit 1 means this is not a success"
  end

  # The consequence line is the reader's actual question after a refusal: did the
  # Heroku write happen? A vague answer is wrong in the dangerous direction.
  def test_the_provision_consequence_names_every_side_effect_that_did_not_happen
    consequence = QaServerCli::COMMANDS.fetch("provision").fetch(:consequence)

    assert_match(/NO Heroku app, add-on, domain, certificate or config var/, consequence)
  end

  # `--help` is answered from ANY position, including ahead of the app name — a
  # guard that only checked the last token hands the mutation to the other spelling.
  def test_help_is_answered_from_every_position_and_in_both_spellings
    [
      %w[provision --help turf-monster --yes],
      %w[provision --help],
      %w[provision -h turf-monster],
      %w[deploy turf-monster origin/main --yes --help],
      %w[deploy -h],
      %w[plan --help],
      %w[status --help],
      %w[list --help]
    ].each { |argv| assert_equal 1, refusal(argv), "#{argv.inspect} must answer help without acting" }
  end

  # EXIT 0 IS THE ONE ANSWER THIS SCRIPT MUST NEVER GIVE, and it is not the shared
  # guard's default. bin/release.rb:3198 shells `bin/qa-server deploy <app>
  # origin/release --yes` and reads system()'s boolean into `qa_ok`, which gates the
  # /up smoke and whether the RC's members flip `reviewed → assembled`. A help or a
  # refusal exiting 0 would hand the sweep a green QA deploy it never performed.
  def test_help_and_refusal_never_exit_zero
    assert_equal 1, QaServerCli::HELP_EXIT, "help must not answer with the success code"

    QaServerCli::COMMANDS.each_key do |cmd|
      assert_equal 1, refusal([cmd, "--help"]), "#{cmd} --help must exit 1"
      refute_equal 0, refusal([cmd, "--frobnicate"]), "#{cmd} must not refuse with the success code"
      assert_equal 2, refusal([cmd, "--frobnicate"]), "an unaccounted-for argument exits 2"
    end
  end

  # An argument no subcommand accounts for REFUSES rather than being dropped — the
  # generalisation of the bug, not just the `--help` spelling of it.
  def test_an_unaccounted_for_argument_refuses_rather_than_being_dropped
    assert_equal 2, refusal(%w[provision turf-monster --force])
    assert_match(/unrecognized argument "--force"/, @err.string)
    assert_match(/NO Heroku app/, @err.string, "the refusal must say the provision did not happen")
  end

  # `--yes` is a real flag on exactly two subcommands. On the other three it was
  # always a silent no-op, and a silent no-op is the same class one seam over.
  def test_yes_is_accounted_for_only_where_it_is_actually_read
    %w[provision deploy].each do |cmd|
      parsed = guard([cmd, "app", "--yes"])

      assert parsed.bool?("--yes"), "bin/qa-server #{cmd} reads --yes; the guard must accept it"
    end

    %w[list plan status].each do |cmd|
      assert_equal 2, refusal([cmd, "--yes"]),
                   "bin/qa-server #{cmd} never reads --yes — accepting it would be a silent no-op"
    end
  end

  # --- the other half: everything real MUST still dispatch -------------------

  # Every distinct invocation shape found by sweeping both repos and all agent docs
  # for `bin/qa-server …` (57 occurrences, 22 distinct shapes, 2026-08-31). A
  # dictionary that is too strict does not fail loudly — it wedges the QA lane,
  # because bin/release shells the `deploy` line on every prepare.
  DOCUMENTED_INVOCATIONS = [
    %w[list],
    %w[plan],
    %w[plan turf-monster],
    %w[plan mcritchie-studio],
    %w[provision turf-monster --yes],
    %w[provision mcritchie-studio --yes],
    %w[provision rolio --yes],
    %w[status],
    %w[status mcritchie-studio],
    %w[status turf-monster],
    %w[status rolio],
    %w[deploy turf-monster origin/main --yes],
    %w[deploy rolio origin/release --yes],
    %w[deploy mcritchie-studio origin/release --yes],
    # The retry hint bin/release prints on a failed QA deploy — no --yes on it.
    %w[deploy mcritchie-studio origin/release],
    %w[deploy turf-monster origin/release]
  ].freeze

  def test_every_documented_invocation_still_dispatches
    DOCUMENTED_INVOCATIONS.each do |argv|
      parsed = guard(argv)

      refute_equal :not_a_subcommand, parsed, "bin/qa-server #{argv.join(' ')} is a real documented call"
      assert_instance_of CliArgGuard::Parsed, parsed,
                         "bin/qa-server #{argv.join(' ')} is a REAL invocation and must still run — " \
                         "a guard that refuses it wedges the QA lane on every bin/release prepare"
    end
  end

  # The exact line bin/release.rb:3198 shells, kept as its own case because it is
  # the one invocation no human is watching when it runs.
  def test_the_release_sweeps_own_deploy_line_dispatches
    parsed = guard(%w[deploy mcritchie-studio origin/release --yes])

    assert parsed.bool?("--yes")
    assert_equal %w[mcritchie-studio origin/release], parsed.positionals
  end

  # A token that is not a subcommand at all (a bare `--help`, a typo) is NOT the
  # guard's to answer — the dispatcher's `else` prints usage and exits 1, exactly as
  # it always did. Asserted so a later "improvement" doesn't silently swallow it.
  def test_a_non_subcommand_falls_through_to_the_dispatcher
    assert_equal :not_a_subcommand, guard(%w[--help])
    assert_equal :not_a_subcommand, guard(%w[provisionn turf-monster])
    assert_equal :not_a_subcommand, guard([])
  end

  # --- the dictionary describes the script it guards -------------------------

  # A dictionary that named a subcommand the script cannot dispatch (or missed one
  # it can) would guard a CLI that does not exist. Read from the script's own
  # `when` arms rather than restated here.
  def test_the_dictionary_covers_exactly_the_scripts_subcommands
    src = File.read(File.expand_path("../../bin/qa-server", __dir__))
    dispatcher = src[/^if __FILE__ == \$PROGRAM_NAME.*\z/m]
    refute_nil dispatcher, "the dispatcher moved — re-anchor this test"

    dispatched = dispatcher.scan(/^\s*when "([a-z-]+)"/).flatten.sort

    assert_equal dispatched, QaServerCli::COMMANDS.keys.sort,
                 "the guard's dictionary and the dispatcher's `when` arms must name the same set — " \
                 "a subcommand missing from the dictionary is dispatched UNGUARDED"
  end

  def test_every_entry_carries_a_synopsis_and_an_honest_consequence
    QaServerCli::COMMANDS.each do |cmd, spec|
      assert_match(/\Abin\/qa-server #{cmd}/, spec[:synopsis], "#{cmd}'s synopsis must name its own line")
      refute_empty spec[:consequence].to_s, "#{cmd} must say what did NOT happen on a refusal"
    end
  end
end
