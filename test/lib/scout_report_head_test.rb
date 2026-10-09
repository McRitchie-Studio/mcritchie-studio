# frozen_string_literal: true

# A scout report can name the PR head it judged (`--head`), which is what lets
# bin/merge-permit tell a verdict on this tree from a verdict on an earlier one.
# Driven through the real script in --dry-run, so nothing is written to a board.
#
# Run directly:  ruby -Itest test/lib/scout_report_head_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

class ScoutReportHeadTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/devops-cycle", __dir__)
  HEAD = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

  def record(*extra)
    Open3.capture3(RbConfig.ruby, SCRIPT, "--record-scout-report", "tidy-the-sop", "--scout-agent", "xan",
                   "--outcome", "merge-ready", "--summary", "Prose only.", "--dry-run", "--json", *extra)
  end

  def test_the_head_is_recorded_on_the_report
    out, err, status = record("--head", HEAD.upcase)

    assert status.success?, err
    assert_equal HEAD, JSON.parse(out).dig("activity", "metadata", "head")
  end

  def test_a_report_without_a_head_carries_no_head_key
    out, err, status = record

    assert status.success?, err
    refute JSON.parse(out).dig("activity", "metadata").key?("head")
  end

  def test_a_short_or_malformed_head_is_refused
    ["a1b2c3d", "#{HEAD}0", "not-a-sha"].each do |bad|
      _out, err, status = record("--head", bad)

      refute status.success?, "--head #{bad} must be refused"
      assert_match(/full 40-character head sha/, err)
    end
  end
end
