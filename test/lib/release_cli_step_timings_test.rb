# frozen_string_literal: true

# bin/release prints and records its per-step durations (task release-sub-hour-pipeline).
#   ruby -Itest test/lib/release_cli_step_timings_test.rb

require_relative "release_cli_harness"

class ReleaseCliStepTimingsTest < ReleaseCliHarness
  def test_an_act_prints_both_timing_lines_and_records_them_under_the_results_dir
    out = run_cli(["--yes"], call: <<~RUBY)
      time_step("sweep")
      time_step("ci_gate", release: "rel-t")
      report_step_timings
      puts("FILE " + File.read(File.join(release_results_dir, "steps.jsonl")))
    RUBY

    assert_match(/^⏱ step durations: sweep \d+s · ci gate \d+s$/, out)
    assert_match(/^RELEASE_STEP_TIMINGS \{"sweep":\d+,"ci_gate":\d+\}$/, out)
    # The results dir is shared by every act in the run: read this act's own line.
    lines = out.split("FILE ", 2).last.lines.map { |l| JSON.parse(l) rescue nil }.compact
    record = lines.reverse.find { |r| r["release"] == "rel-t" }
    refute_nil record, "no steps.jsonl line for rel-t: #{out}"
    assert_equal "rel-t", record["release"]
    assert_equal %w[sweep ci_gate], record["steps"].keys
  end

  def test_a_dry_run_times_nothing
    out = run_cli(["--dry-run"], call: %(time_step("sweep"); print($step_clock.inspect)))
    assert_equal "nil", out
  end
end
