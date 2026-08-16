class Release
  # The metronome behind a batch board flip: card 1 leaves one beat after card 0,
  # card 2 two beats after card 0 — every deadline measured from the moment the
  # FIRST card left, never from the previous one.
  #
  # Start it when card 0 actually leaves, not when the batch method is entered: the
  # query and the first write sit before that and would eat into the first gap
  # (measured 411ms against a 500ms beat when the clock started at method entry).
  #
  # WHY A DEADLINE AND NOT A SLEEP. Sleeping the full beat after each flip adds the
  # flip's own work to every gap, and the error accumulates: measured on the live
  # board, a 0.5s sleep produced gaps of 531, 549, 551, 534, 553ms, so the sixth
  # card landed a quarter-second late and the sweep visibly lost its rhythm. Waiting
  # until `start + n × beat` spends the write time INSIDE the beat instead of after
  # it, so the nth card leaves on the nth beat however long the writes take.
  #
  # A flip that overruns its beat (a slow write, a stalled connection) yields a
  # non-positive remainder: that beat is simply not waited on, and the schedule
  # picks the next one up rather than compounding the delay.
  #
  # A zero/negative beat is "no cadence at all" — every caller runs at full speed,
  # which is what tests and any programmatic caller want.
  class BeatClock
    def initialize(beat, now: monotonic_now)
      @beat = beat.to_f
      @started_at = now
    end

    def cadence?
      @beat.positive?
    end

    # Wait until beat number `index` is due, yielding the remaining seconds to the
    # caller's own pause seam (so a test can record the wait without sleeping).
    # Returns the seconds waited — 0 when there is nothing to wait for.
    def wait_for_beat(index, now: monotonic_now)
      return 0.0 unless cadence?
      return 0.0 if index.to_i <= 0

      remaining = (@started_at + (@beat * index.to_i)) - now
      return 0.0 unless remaining.positive?

      yield remaining if block_given?
      remaining
    end

    private

    # CLOCK_MONOTONIC: a schedule must not be moved by an NTP step or a DST change.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
