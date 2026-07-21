# frozen_string_literal: true

require_relative "../../lib/claim_lease"

# ShiftRenewer — the loop that keeps a devops SHIFT lease alive for as long as its
# holder is actually working.
#
# WHY IT EXISTS. Renewal used to live in exactly one place: bin/statusline, which
# runs when Claude Code PAINTS A STATUS LINE. That made the lease a property of the
# UI rather than of the run, and the two are not the same population. A headless
# session — a background agent run, and critically the AUTONOMOUS HEARTBEAT — paints
# nothing, so it renewed nothing, so its lease lapsed one TTL (120s) after
# acquisition. `bin/devops-shift acquire` then truthfully reported the lane FREE to
# the next session while the first was still mid-review. On 2026-07-20 that is
# precisely what happened: two Avi review supervisors ran concurrently and duplicated
# four reviewer lanes on PR #601 — the collision the lease exists to prevent. The
# guard reported protection it did not provide.
#
# WHAT ANCHORS IT INSTEAD. The renewer runs detached and renews on its own cadence
# while its ANCHOR PROCESS is alive. The anchor is the long-lived `claude`/`codex`
# process — deliberately the SAME process the live-instance nonce is already derived
# from (bin/lib/session_identity.rb#nonce), so the lease's IDENTITY and the lease's
# LIFETIME answer to one fact instead of two that can drift apart.
#
# THE TWO HALVES OF THE GUARANTEE, and why neither may be dropped:
#
#   anchor ALIVE ⇒ keep renewing, headless or not. A holder retains the lane for the
#     duration of its work, and a second acquire in that window is REFUSED.
#   anchor GONE  ⇒ STOP renewing, immediately. The lease then lapses on the ordinary
#     TTL and the lane is reclaimable. This is why the fix is a renewer and not a
#     fail-closed acquire: making acquire refuse whenever it cannot PROVE the holder
#     dead would invert ClaimLease's fail-open posture and let one crashed conductor
#     wedge a lane indefinitely. A crash must degrade to a delay, never to a deadlock.
#
# Every uncertainty resolves toward STOPPING. A renewer that cannot confirm its
# anchor gives the lane up; the cost is a lapsed lease (recoverable, and no worse
# than today's behavior), whereas the cost of guessing the other way is an immortal
# phantom holder that no one can clear.
#
# Pure and injectable — nothing here reads the clock, the process table, or the
# network, so the loop is tested as arithmetic rather than by waiting on wall time.
module ShiftRenewer
  # Renew four times per lease. The guarantee rests on INTERVAL < TTL, and the margin
  # is what makes a single missed beat survivable, so the cadence is DERIVED from the
  # TTL rather than typed next to it — two constants in two files drift, and this one
  # drifting reintroduces the exact bug above.
  INTERVAL_SECONDS = ClaimLease::DEFAULT_TTL_SECONDS / 4

  # The ceiling for an operator/test override. Anything at or above half the TTL
  # removes the survive-one-missed-beat margin, so overrides are clamped, not trusted.
  MAX_INTERVAL_SECONDS = ClaimLease::DEFAULT_TTL_SECONDS / 2

  # Belt and braces. If liveness probing were ever wrong — a PID we cannot read, a
  # platform whose `ps` answers differently — a renewer must still not hold a lane
  # forever. Twelve hours is far longer than any real conductor act and far shorter
  # than "forever".
  MAX_LIFETIME_SECONDS = 12 * 60 * 60

  module_function

  # Run until one of the three stop conditions. Returns the reason:
  #   :anchor_gone   — the holder's process is gone (crash or clean exit)
  #   :lease_lost    — the board says we no longer hold it (released, or changed hands)
  #   :max_lifetime  — the safety cap
  #
  # `alive` and `renew` are called in that order and BEFORE the first sleep, so a
  # renewer whose anchor is already dead renews nothing at all.
  def run(alive:, renew:, sleeper:, clock:,
          interval: INTERVAL_SECONDS, max_lifetime: MAX_LIFETIME_SECONDS)
    started_at = clock.call
    loop do
      return :anchor_gone unless alive.call
      return :max_lifetime if clock.call - started_at >= max_lifetime
      return :lease_lost unless renew.call

      sleeper.call(interval)
    end
  end

  # Resolve a configured interval, clamped into (0, MAX_INTERVAL_SECONDS]. A blank or
  # unparseable value falls back to the derived default; 0 or negative would busy-spin;
  # an over-long one would let the lease lapse mid-work, which is the bug itself.
  def interval_from(value)
    text = value.to_s.strip
    return INTERVAL_SECONDS if text.empty? || !text.match?(/\A-?\d+\z/)

    seconds = text.to_i
    return 1 if seconds < 1

    [seconds, MAX_INTERVAL_SECONDS].min
  end
end
