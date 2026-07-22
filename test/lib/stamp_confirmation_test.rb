# frozen_string_literal: true

# Unit tests for StampConfirmation.confirmed? — the pure read-back decision behind
# `bin/task merged`'s persistence check. No board, no HTTP: every branch is driven from a
# synthetic read_back callable. The load-bearing case is that an UNREADABLE read-back (nil)
# is NOT a confirmation — the pre-fix verifier treated it as verified, which let a dropped
# stamp reach a `reviewed` member as merged:None under board load.
#
# Run directly:  ruby -Itest test/lib/stamp_confirmation_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/stamp_confirmation"

class StampConfirmationTest < Minitest::Test
  def test_confirms_only_on_an_exact_read_back_match
    assert StampConfirmation.confirmed?("accepted", read_back: -> { "accepted" })
  end

  # A dropped write reads back BLANK ("" — the null column) — never a confirmation.
  def test_a_blank_read_back_is_a_dropped_write_not_confirmed
    refute StampConfirmation.confirmed?("accepted", read_back: -> { "" }, attempts: 3)
  end

  # THE FIX: an UNREADABLE read-back (nil — the GET itself failed) is NOT a confirmation.
  # The pre-fix code returned OK on nil (absence of signal as success), so a drop that
  # coincided with a failed read-back sailed through to a reviewed member as merged:None.
  def test_an_unreadable_read_back_is_not_confirmed
    refute StampConfirmation.confirmed?("accepted", read_back: -> { nil }, attempts: 3),
           "nil (board unreadable) must never count as a confirmed stamp"
  end

  # A TRANSIENT miss (a blip, then the real value) still confirms — retries survive it
  # without accepting a genuine drop. Proves the retry is a real read loop, not a no-op.
  def test_a_transient_miss_then_the_value_confirms
    seq = [nil, "", "accepted"]
    assert StampConfirmation.confirmed?("accepted", read_back: -> { seq.shift }, attempts: 3)
  end

  # A persistently WRONG value across every attempt stays unconfirmed — retrying never
  # manufactures a false pass.
  def test_a_persistent_wrong_value_stays_unconfirmed
    refute StampConfirmation.confirmed?("accepted", read_back: -> { "release" }, attempts: 3)
  end

  # The sleeper spaces retries only BETWEEN attempts (attempts-1 pauses), and the happy path
  # never sleeps — so a confirmed stamp adds no latency and the loop is bounded.
  def test_sleeps_only_between_attempts_and_not_on_immediate_confirm
    pauses = []
    StampConfirmation.confirmed?("accepted", read_back: -> { "accepted" }, attempts: 3,
                                 sleeper: ->(s) { pauses << s })
    assert_empty pauses, "an immediate confirm must not sleep"

    pauses.clear
    StampConfirmation.confirmed?("accepted", read_back: -> { nil }, attempts: 3,
                                 sleeper: ->(s) { pauses << s })
    assert_equal 2, pauses.length, "three attempts pause twice (between, never after the last)"
  end
end
