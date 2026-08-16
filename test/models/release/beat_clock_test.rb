require "test_helper"

# [unit] The metronome behind a batch board flip. Every case here injects `now`, so
# the schedule is asserted arithmetically — no sleeping, no wall clock.
class Release::BeatClockTest < ActiveSupport::TestCase
  test "[unit] the nth card is due n beats after the batch STARTED, not after the last card" do
    clock = Release::BeatClock.new(0.5, now: 100.0)

    # Each flip costs 0.05s of write time. A sleep-the-full-beat loop would push
    # card 3 out to 1.65s; the deadline keeps it on 1.5s.
    assert_in_delta 0.45, clock.wait_for_beat(1, now: 100.05), 0.0001
    assert_in_delta 0.40, clock.wait_for_beat(2, now: 100.60), 0.0001
    assert_in_delta 0.35, clock.wait_for_beat(3, now: 101.15), 0.0001
  end

  test "[unit] the first card never waits" do
    clock = Release::BeatClock.new(0.5, now: 0.0)

    assert_equal 0.0, clock.wait_for_beat(0, now: 0.0)
  end

  test "[unit] a beat already overrun is not waited on, and the batch does not compound the delay" do
    clock = Release::BeatClock.new(0.5, now: 0.0)

    # Card 1 took 2s of write time — its beat is long gone.
    assert_equal 0.0, clock.wait_for_beat(1, now: 2.0), "an overrun beat waits zero, never negative"
    # Card 5 is still due at 2.5s from the start, so the schedule picks itself back up.
    assert_in_delta 0.4, clock.wait_for_beat(5, now: 2.1), 0.0001
  end

  test "[unit] no cadence means no waiting at all" do
    [0, 0.0, -1].each do |beat|
      clock = Release::BeatClock.new(beat, now: 0.0)
      assert_not clock.cadence?
      assert_equal 0.0, clock.wait_for_beat(3, now: 0.0)
    end
  end

  test "[unit] the wait is yielded to the caller's own pause seam" do
    clock = Release::BeatClock.new(0.5, now: 0.0)
    waited = []

    clock.wait_for_beat(2, now: 0.25) { |seconds| waited << seconds }

    assert_equal 1, waited.size
    assert_in_delta 0.75, waited.first, 0.0001
  end
end
