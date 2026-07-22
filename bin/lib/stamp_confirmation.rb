# frozen_string_literal: true

# StampConfirmation — decide whether a git-location stamp (`bin/task merged`) actually LANDED,
# from repeated read-backs. A 200 on the write is NOT persistence: the value must be read back
# and CONFIRMED equal. Two non-confirmations are distinct, and BOTH must fail:
#
#   - a blank / other value → the write DROPPED (the classic dropped write), or
#   - nil                   → the board was UNREADABLE (the read-back GET itself failed).
#
# The pre-fix verifier passed silently on the SECOND — it treated a nil read-back as "verified"
# (absence of signal as success). Under board load (the 20-connection prod PG spiking to
# "too many connections") the merged PATCH drops AND the read-back GET fails TOGETHER, so a
# dropped stamp reached a `reviewed` member as merged:None — the sweep then leaves it behind as
# a HELD anomaly (2026-07-21: nine reviewed tasks stranded off every release candidate).
#
# Only an exact match confirms; a few retries survive a TRANSIENT read miss (a blip that clears)
# without ever accepting a genuine drop or an unreadable board. Pure and injectable — the read
# and the wait are passed in, so the decision is tested as data, not by hitting a live board.
module StampConfirmation
  module_function

  # read_back: a no-arg callable returning the persisted value — "" when the field is null,
  # nil when the board could not be read. Returns true ONLY when some attempt reads back
  # exactly `expected`; nil and blank both stay unconfirmed across all attempts.
  def confirmed?(expected, read_back:, attempts: 3, sleeper: ->(_seconds) { })
    tries = attempts.to_i
    tries = 1 if tries < 1

    tries.times do |i|
      return true if read_back.call == expected

      sleeper.call(RETRY_PAUSE_SECONDS) if i < tries - 1
    end
    false
  end

  RETRY_PAUSE_SECONDS = 0.25
end
