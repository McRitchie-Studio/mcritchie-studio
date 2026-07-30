# frozen_string_literal: true

# Unit tests for MergeCommand.args — the pure `gh pr merge` argument vector (bin/pr-review).
# No gh, no live PR: the --match-head-commit PIN and its blank-head fallback are driven from
# synthetic inputs. This is the seam that stops the supervisor merging a head it did not validate.
#
# Run directly:  ruby -Itest test/lib/merge_command_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/merge_command"

class MergeCommandTest < Minitest::Test
  URL  = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/1"
  HEAD = "abc1234def5678"

  # The PIN: a known revalidated head MUST become `--match-head-commit <head>`, so `gh pr merge`
  # refuses a head that advanced past the one the supervisor validated (a late zap / racing push).
  def test_pins_the_validated_head_with_match_head_commit
    argv = MergeCommand.args(URL, HEAD)

    assert_equal %w[pr merge], argv[0, 2]
    assert_includes argv, URL
    assert_includes argv, "--merge"
    idx = argv.index("--match-head-commit")
    refute_nil idx, "a known head must be pinned with --match-head-commit"
    assert_equal HEAD, argv[idx + 1], "the pin must carry the exact validated head"
  end

  # No known head (a gh read fault at capture time) → the documented UNPINNED fallback. A blank
  # head must never produce an empty `--match-head-commit` pin, which gh rejects and would stall
  # every merge. This pins the fallback in BOTH directions (pin present iff head present).
  def test_blank_head_falls_back_to_an_unpinned_merge
    [nil, "", "   "].each do |blank|
      argv = MergeCommand.args(URL, blank)
      refute_includes argv, "--match-head-commit", "a #{blank.inspect} head must not add an (empty) pin"
    end
    assert_equal ["pr", "merge", URL, "--merge"], MergeCommand.args(URL)
  end
end
