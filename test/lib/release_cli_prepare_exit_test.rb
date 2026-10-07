# frozen_string_literal: true

# [integration] bin/release prepare's exit status is its QA verdict (guard catalog
# row 7.5, guards-review-and-release). Drives the real prepare flow through the
# release CLI harness with the boot poll stubbed.
#
#   ruby -Itest test/lib/release_cli_prepare_exit_test.rb

require_relative "release_cli_harness"
require_relative "../../app/models/release/cli"

class ReleaseCliPrepareExitTest < ReleaseCliHarness
  # --- the exit status IS the QA verdict (guard catalog row 7.5) ---------------
  #
  # A NOT-green prepare used to return normally, so its wrapper printed exit 0 over a
  # release that assembled nothing (rel-20260907-14cff2). The dispatcher now exits
  # Release::Cli::PREPARE_QA_NOT_GREEN_EXIT, so the exit code cannot disagree with
  # the block.

  def test_prepare_exits_nonzero_when_qa_is_not_green
    setup = SWEEP_FLOW_STUB + %(\ndef wait_for_boot(_url) = false)
    out = run_cli(["--yes"], call: "begin; exit_after_prepare(prepare); puts 'EXIT=0'; " \
                                   "rescue SystemExit => e; puts \"EXIT=\#{e.status}\"; end", setup: setup)

    assert_includes out, "EXIT=#{Release::Cli::PREPARE_QA_NOT_GREEN_EXIT}",
                    "a QA-red prepare must exit nonzero, through the dispatcher's own helper"
    refute_includes out, "Prepare ABORTED partway",
                    "the exit lands outside prepare, so its abort report never fires"
  end

  def test_prepare_exits_zero_when_qa_is_green
    out = run_cli(["--yes"], call: "begin; exit_after_prepare(prepare); puts 'EXIT=0'; " \
                                   "rescue SystemExit => e; puts \"EXIT=\#{e.status}\"; end",
                  setup: SWEEP_FLOW_STUB)

    assert_includes out, "Assembled rel-sweep"
    assert_includes out, "EXIT=0"
  end

  def test_the_dispatcher_routes_prepare_through_the_exit_helper
    src = File.read(BIN)

    assert_includes src, %(when "prepare"  then exit_after_prepare(prepare)),
                    "the subcommand must exit with prepare's outcome, not return it"
  end
end
