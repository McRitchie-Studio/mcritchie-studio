# frozen_string_literal: true

# [unit] E2eSpecCensus.listed: the census as Playwright's own `--list` counts it,
# which bin/e2e-census-check holds against the source scan the CI gate reads.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/e2e_spec_census"

class E2eSpecCensusListedTest < Minitest::Test
  def runner(lane:, held:, lane_ok: true)
    calls = []
    fake = lambda do |argv, _root|
      calls << argv
      argv.include?("--grep-invert") ? [lane, lane_ok] : [held, !held.include?("No tests found")]
    end
    [fake, calls]
  end

  def test_it_reads_playwrights_totals_for_the_lane_and_the_quarantine
    fake, calls = runner(lane: "  [chromium] › a.spec.js:1:1 › a\nTotal: 267 tests in 107 files\n",
                         held: "Total: 10 tests in 7 files\n")
    census, why = E2eSpecCensus.listed("/repo", quarantine_tag: "@quarantine", bin: "/pw", runner: fake)

    assert_nil why
    assert_equal [277, 10, 107, 267], [census.total, census.quarantined, census.lane_files, census.executed]
    assert_equal [%w[/pw test --list --grep-invert @quarantine], %w[/pw test --list --grep @quarantine]], calls
  end

  def test_no_quarantined_spec_left_reads_as_zero
    fake, = runner(lane: "Total: 1 test in 1 file\n", held: "Error: No tests found\n")
    census, = E2eSpecCensus.listed("/repo", quarantine_tag: "@quarantine", bin: "/pw", runner: fake)

    assert_equal [1, 0], [census.executed, census.quarantined]
  end

  def test_a_list_that_fails_or_has_no_total_is_no_census
    [["SyntaxError in e2e/a.spec.js", false], ["Total: 3 tests in 1 file", false], ["no summary", true]].each do |out, ok|
      fake, = runner(lane: out, held: "", lane_ok: ok)
      census, why = E2eSpecCensus.listed("/repo", quarantine_tag: "@quarantine", bin: "/pw", runner: fake)

      assert_nil census, out
      assert_match(/did not list the suite/, why)
    end
  end

  def test_no_playwright_is_said_and_runs_nothing
    census, why = E2eSpecCensus.listed("/repo", quarantine_tag: "@quarantine", bin: nil,
                                                runner: ->(*) { flunk "nothing may run" })

    assert_nil census
    assert_match(/not installed/, why)
  end

  def test_the_runner_is_found_in_the_checkout_or_above_it
    Dir.mktmpdir do |dir|
      desk = File.join(dir, ".worktrees", "slug")
      FileUtils.mkdir_p(desk)
      assert_nil E2eSpecCensus.playwright_bin(desk)

      bin = File.join(dir, "node_modules", ".bin", "playwright")
      FileUtils.mkdir_p(File.dirname(bin))
      File.write(bin, "#!/bin/sh\n")
      File.chmod(0o755, bin)
      assert_equal bin, E2eSpecCensus.playwright_bin(desk), "a desk resolves the hub's, as Node does"
    end
  end
end
