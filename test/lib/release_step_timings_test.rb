# frozen_string_literal: true

# Per-step durations for one bin/release act (task release-sub-hour-pipeline).
#   ruby -Itest test/lib/release_step_timings_test.rb

require "minitest/autorun"
require "json"
require_relative "../../bin/lib/release_step_timings"
require_relative "../../bin/lib/release_cycle"

class ReleaseStepTimingsTest < Minitest::Test
  def clock(times)
    ticks = times.dup
    ReleaseStepTimings::Clock.new(now: -> { ticks.size > 1 ? ticks.shift : ticks.first })
  end

  def test_each_phase_ends_when_the_next_starts_and_a_repeat_adds_up
    c = clock([0, 184, 844, 944])
    c.mark("sweep").mark("ci_gate").mark("sweep").close
    assert_equal({ "sweep" => 184 + 100, "ci_gate" => 660 }, c.seconds)
  end

  def test_the_lines_the_cycle_reads
    c = clock([0, 184, 844])
    c.mark("sweep").mark("ci_gate").close
    assert_equal %(RELEASE_STEP_TIMINGS {"sweep":184,"ci_gate":660}), c.machine_line
    assert_equal "⏱ step durations: sweep 3m 4s · ci gate 11m 0s", c.human_line
    assert_equal({ "sweep" => 184, "ci_gate" => 660 }, ReleaseCycle.step_timings_from("x\n#{c.machine_line}\ny\n"))
  end

  def test_an_empty_clock_reports_nothing
    refute ReleaseStepTimings::Clock.new.any?
  end
end
