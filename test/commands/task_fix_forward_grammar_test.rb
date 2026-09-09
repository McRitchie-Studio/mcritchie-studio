# frozen_string_literal: true

require "test_helper"
require "open3"

# [unit] `bin/task fix-forward`'s ARGUMENT GRAMMAR — the half that must refuse
# BEFORE it reaches the board.
#
# WHY A CLI GRAMMAR TEST FOR THIS COMMAND SPECIFICALLY. Every entry it writes is
# sorted downstream by ONE question — `Task.soul?` — and the two answers have
# opposite meanings: a soul joins the author set, anything else is the "a
# fix-forward happened and nobody can name who" marker that makes
# `bin/reviewer-select` REFUSE. So a typo does not degrade here, it INVERTS:
# `--agent Steffon` (capitalised) matches no soul, would land as an unnamed
# marker, and would read forever after as "a zap nobody could attribute" — with
# the value that caused it sitting on the record as if it were the marker. The
# same shape the operating model already refuses on `bin/task begin --agent`.
#
# EVERY ASSERTION HERE RUNS OFF-NETWORK by construction: each refusal happens in
# argument parsing, before the command GETs the task. TASK_API_BASE is pinned at a
# port nothing listens on, so a regression that defers a check until after the
# lookup fails loudly here instead of silently reaching prod.
class TaskFixForwardGrammarTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  # Loopback on a dead port: the connection is REFUSED immediately. An unroutable
  # address would blackhole and hang the suite instead.
  OFFLINE = { "TASK_API_BASE" => "http://127.0.0.1:1", "TASK_SKIP_MARKER" => "1" }.freeze

  def run_cli(*args)
    out, err, status = Open3.capture3(OFFLINE, BIN, "fix-forward", *args)
    [out + err, status.exitstatus]
  end

  def test_a_bare_line_names_neither_an_author_nor_the_absence_of_one
    output, code = run_cli("some-task")

    refute_equal 0, code
    assert_match(/--agent/, output)
    assert_match(/--unnamed/, output)
  end

  # The two flags are OPPOSITE claims. Resolving the line one way would lift or
  # impose a refusal by guess, which is exactly how a guard gets cleared by
  # accident.
  def test_agent_and_unnamed_together_are_refused
    output, code = run_cli("some-task", "--agent", "steffon", "--unnamed")

    refute_equal 0, code
    assert_match(/opposite claims/, output)
  end

  # THE INVERSION GUARD. A capitalised or underscored handle matches no soul, so
  # accepting it would silently convert a named fix-forward into an unattributable
  # one — a stricter state than the caller asked for, reached by a typo.
  def test_a_handle_that_is_not_a_soul_slug_is_refused_not_stored
    %w[Steffon turf_monster steffon@mcritchie.studio].each do |handle|
      output, code = run_cli("some-task", "--agent", handle)

      refute_equal 0, code, "#{handle} is not a soul slug and must be refused, never stored"
      assert_match(/not soul slugs/, output)
    end
  end

  def test_an_unknown_flag_is_refused
    output, code = run_cli("some-task", "--soul", "steffon")

    refute_equal 0, code
    assert_match(/--soul/, output)
  end

  # A well-formed line must get PAST parsing and fail only on the network — proof
  # that the refusals above are grammar, not a command that refuses everything.
  def test_a_well_formed_line_reaches_the_board
    output, code = run_cli("some-task", "--agent", "steffon,shannon")

    refute_equal 0, code, "the board is unreachable in this test, so it still fails"
    refute_match(/not soul slugs|opposite claims|usage:/, output,
                 "a valid line must fail on the NETWORK, never on the grammar")
  end
end
