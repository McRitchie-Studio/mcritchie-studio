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
# THE THIRD HALF, added after it cost two days of GitHub auth (2026-08-29 and again
# 2026-08-30). The two conditions above answer "is my HOLDER still here?" and
# "do I still HOLD it?". Neither answers "is the thing I am protecting still a
# thing?" — and for a lease scoped to a unit of WORK (a task review) rather than to
# a lane, that is the condition that actually ends the job. A long-lived agent
# session that reviewed four tasks accumulated four renewers; all four kept polling
# the board every 30s long after their tasks had SHIPPED TO PRODUCTION, because
# their anchor was alive and legitimately working and their claims were still
# technically held. Five such loops were found running at 05:25Z on 2026-08-30 with
# the 1Password account read_write cap fully spent; the outage presented as
# "1Password is down", which is why it went undiagnosed for a day.
#
# So a renewer now also asks whether its work is DONE, and a renewal on finished
# work is treated as meaningless by definition rather than as merely harmless.
#
# Every uncertainty resolves toward STOPPING — with ONE deliberate exception. A
# renewer that cannot confirm its anchor gives the lane up; the cost is a lapsed
# lease (recoverable, and no worse than today's behavior), whereas the cost of
# guessing the other way is an immortal phantom holder that no one can clear. The
# exception is `finished`, which must resolve toward CONTINUING when it cannot get
# an answer: an unreachable board is not evidence that work completed, and stopping
# on a network blip would drop a LIVE review's lease and let a second reviewer take
# the task — reintroducing the collision this whole file exists to prevent. That
# asymmetry is deliberate: a wrong "dead" costs a delay, a wrong "finished" costs a
# duplicated review.
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

  # Run until one of the four stop conditions. Returns the reason:
  #   :anchor_gone    — the holder's process is gone (crash or clean exit)
  #   :work_finished  — the thing being protected is DONE, so the lease is moot
  #   :lease_lost     — the board says we no longer hold it (released, or changed hands)
  #   :max_lifetime   — the safety cap
  #
  # ORDER IS THE CONTRACT, not an implementation detail. `finished` is asked BEFORE
  # `renew`, so a renewer whose work has completed exits having polled the board
  # ZERO further times. Asking after — or inferring completion from the renew's own
  # response — would still spend one poll per loop to learn a fact that is already
  # true, which is the exact cost this stop condition exists to stop paying.
  #
  # All three checks run BEFORE the first sleep, so a renewer that is born obsolete
  # (dead anchor, or work already finished) renews nothing at all.
  #
  # `finished` defaults to "never" so a caller with no completion signal — the
  # devops-shift ROLE lease, which protects a LANE and not a unit of work — keeps
  # exactly its previous behavior.
  def run(alive:, renew:, sleeper:, clock:, finished: -> { false },
          interval: INTERVAL_SECONDS, max_lifetime: MAX_LIFETIME_SECONDS)
    started_at = clock.call
    loop do
      return :anchor_gone unless alive.call
      return :max_lifetime if clock.call - started_at >= max_lifetime
      return :work_finished if finished.call
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
