# frozen_string_literal: true

require "json"

# Per-step durations for one `bin/release` act (task release-sub-hour-pipeline).
#
# prepare and ship mark each phase as they enter it (sweep, ci_gate, qa_deploy,
# record; ship_gate, deploy, record, post_ship). A phase ends when the next one starts
# or the act ends; a phase entered twice adds up. At exit the act prints one human
# line and one machine line,
#
#   ⏱ step durations: sweep 3m 4s · ci gate 11m 0s · qa deploy 12m 1s
#   RELEASE_STEP_TIMINGS {"sweep":184,"ci_gate":660,"qa_deploy":721}
#
# which `bin/release cycle` reads from the act's output (ReleaseCycle.step_timings_from)
# into the release's one RESULT summary. Timing is a report: nothing here can fail an act.
module ReleaseStepTimings
  TAG = "RELEASE_STEP_TIMINGS"

  class Clock
    def initialize(now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @now = now
      @seconds = {}
      @open = nil
      @opened_at = nil
    end

    # Close the open phase (if any) and open +name+.
    # One clock read: the instant the old phase ends is the instant the new one opens.
    def mark(name)
      at = @now.call
      close(at)
      @open = name.to_s
      @opened_at = at
      self
    end

    # Close the open phase. Idempotent.
    def close(at = nil)
      return self unless @open

      at ||= @now.call
      @seconds[@open] = @seconds.fetch(@open, 0) + (at - @opened_at)
      @open = nil
      self
    end

    # { phase => whole seconds }, the open phase counted up to now.
    def seconds
      totals = @seconds.dup
      totals[@open] = totals.fetch(@open, 0) + (@now.call - @opened_at) if @open
      totals.transform_values { |s| s.round }
    end

    def any? = !@seconds.empty? || !@open.nil?

    def machine_line = "#{TAG} #{JSON.generate(seconds)}"

    def human_line
      "⏱ step durations: " + seconds.map { |name, s| "#{name.tr('_', ' ')} #{ReleaseStepTimings.duration(s)}" }.join(" · ")
    end
  end

  module_function

  def duration(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60

    minutes, secs = seconds.divmod(60)
    "#{minutes}m #{secs}s"
  end
end
