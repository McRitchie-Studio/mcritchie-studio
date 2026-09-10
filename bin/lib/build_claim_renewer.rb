# frozen_string_literal: true

require_relative "shift_renewer"

# BuildClaimRenewer — the loop that keeps a BUILD claim alive for as long as its
# builder is actually building, and not one beat longer.
#
# WHY IT EXISTS. `lib/claim_lease.rb` leases the build claim for
# DEFAULT_TTL_SECONDS (120), and the only thing that renewed it was `bin/statusline`,
# which runs when Claude Code PAINTS A STATUS LINE. That made the lease a property of
# the UI rather than of the run, and the two are not the same population: A HEADLESS
# AGENT SHELL PAINTS NOTHING. So any `begin → work → ship` sequence longer than two
# minutes ran UNCLAIMED for almost all of its length, and the free lease could be
# adopted by another session — fail-open, by design, with nobody doing anything wrong.
#
# Measured 2026-09-09: `task-prints-bare-ship-path` was claimed at 04:04, lapsed ~2
# minutes later, was adopted by a different session, and `bin/ship` correctly refused
# nine minutes on; its builder re-claimed FOUR times in one sitting.
# `gem-wiring-ledger-stale` was found with a claim that had lapsed 8.6 HOURS earlier
# while its PR sat open and green. And a cold `bin/ship` now runs ~12 minutes BY
# DESIGN (`gate-submit-on-green-ci` waits for CI), so the DEFAULT successful path for
# every agent build is six times longer than the lease it runs under.
#
# THIS IS THE REVIEW LANE'S FIX, ONE LANE OVER. `TaskReviewClaim` hit the identical
# wall and answered it with a detached, timer-driven renewer anchored to the agent
# process (bin/lib/shift_renewer.rb, bin/lib/review_claim_cli.rb#renew_loop). The
# machinery is reused rather than re-derived — one beat, one anchor rule, one safety
# cap — so the two lanes cannot drift into two different answers to one question.
#
# WHY NOT SIMPLY RAISE THE TTL. Because the TTL is not only the live-holder's
# coverage; it is ALSO the bound on reclaiming a DEAD builder's task, and those two
# want opposite numbers. A TTL long enough to cover a 12-minute ship — let alone the
# 8.6-hour case above — is a TTL that strands a crashed builder's task for the same
# span, and a lease that outlives a dead holder is the worse bug: it leaves a
# `building` task that no sweep can distinguish from live work. A renewer separates
# the two facts, so the TTL stays 120s and MEANS "the builder has been gone for two
# minutes". The review lane's own TTL rise was affordable only because it rode a
# MEASURED corpus of review windows; a "build" has no such bounded corpus — it runs
# from minutes to days.
#
# THE FOUR CONDITIONS, and why renewal needs all of them. The beat is supplied by the
# caller (bin/task's #renew_build_claim), so this file owns the CONTROL and bin/task
# owns the I/O:
#
#   1. ANCHOR ALIVE      — SessionIdentity.process_alive?(pid, start) on the long-lived
#                          `claude`/`codex` process, pid PLUS start time so a reused
#                          pid is never a false positive. Deliberately the SAME process
#                          the live-instance nonce is derived from, so the lease's
#                          IDENTITY and its LIFETIME answer to one fact. Anchor gone ⇒
#                          stop at once ⇒ the ordinary 120s TTL frees the task.
#   2. STILL `building`  — the work a build claim protects must still exist. A ship, a
#                          block or an archive ends the loop, so a session that builds
#                          many tasks does not accumulate one immortal renewer per
#                          task. That accumulation is not hypothetical: five of them
#                          were found polling the board for SHIPPED work on 2026-08-30,
#                          and they spent the account-wide 1Password budget.
#   3. NOT ABANDONED     — the beat runs the SAME `heartbeat_abandoned?` gate the status
#                          line's heartbeat runs (desk mtimes, gate-in-flight,
#                          awaiting-approval, holder-scoped board progress). An open
#                          terminal whose builder walked away stops renewing after
#                          DESK_IDLE_SECONDS even though its anchor is alive. Without
#                          this, a detached renewer would be a lease that never
#                          expires — the 2026-08-13 stall rebuilt on a timer.
#   4. MAX LIFETIME      — ShiftRenewer's 12h belt-and-braces cap, unchanged.
#
# EVERY UNCERTAINTY RESOLVES TOWARD CONTINUING, with one exception, and the asymmetry
# is deliberate. An unreachable board, a declined beat, a lease we could not read: none
# of those is evidence the builder is gone, and stopping on a network blip would drop a
# LIVE build's lease and hand the task to the next session — the collision this file
# exists to prevent. The exception is the ANCHOR, which resolves toward STOPPING: a
# renewer that cannot confirm its holder gives the claim up, because a wrong "dead"
# costs a delay while a wrong "alive" costs a phantom holder nobody can clear.
#
# A DECLINED BEAT DOES NOT END THE LOOP, and that is not an oversight. Declining is
# how condition 3 works, and it is self-healing by design: the holder's lease lapses,
# and when the desk goes warm again the very next beat re-adopts it (bin/task's
# #heartbeat_may_claim? lets a session sitting at the task's BOUND desk take a free
# lease). A loop that exited on the first decline would remove the recovery path and
# leave a working builder permanently unclaimed.
#
# Pure and injectable — nothing here reads the clock, the process table, or the
# network, so the control is tested as arithmetic rather than by waiting on wall time.
module BuildClaimRenewer
  # The outcomes one beat can report. bin/task#renew_build_claim returns exactly one.
  #   :renewed       — the lease was extended (or legitimately re-adopted at our desk)
  #   :declined      — nothing was written, but the task is still ours to try again
  #                    (holder judged abandoned, or this session may not acquire)
  #   :cant_run      — we could not tell (no session, board unreachable, error)
  #   :held_by_other — a DIFFERENT live instance holds it
  #   :not_building  — the task has left `building`; a build claim on it means nothing
  OUTCOMES = %i[renewed declined cant_run held_by_other not_building].freeze

  # The ONE outcome that stops the loop through `renew`. See the header: everything
  # else, uncertainty included, keeps beating.
  LOST = :held_by_other

  # The ONE outcome that stops the loop through `finished`.
  FINISHED = :not_building

  # HOW LONG A RENEWER KEEPS TRYING AGAINST A BOARD IT CANNOT REACH. An unreachable
  # board is an uncertainty, and this file's rule is that uncertainties keep beating —
  # but "keep beating" cannot mean "forever", or a board that goes away for good
  # (a torn-down stack, a test's throwaway sink) leaves a process polling a dead
  # endpoint until its anchor dies. Two of those were produced by this feature's own
  # first cut, on the machine that wrote it.
  #
  # PAST ONE TTL OF FAILED RENEWALS THERE IS NO LEASE LEFT TO PROTECT: a renewal that
  # cannot reach the board writes nothing, so the lease has already lapsed on the
  # ordinary TTL and everything after that is RECOVERY — re-adopting the claim if the
  # board comes back. Recovery deserves a generous window, not an unbounded one.
  #
  # And giving up is cheaper here than it looks, because A BOARD NOBODY CAN REACH IS
  # A BOARD NOBODY CAN CLAIM FROM. Claiming is a board write, so for as long as the
  # outage lasts the no-two-builders property is held by the outage itself; the only
  # exposure is the window after the board returns, where `bin/ship`'s own ownership
  # guard still refuses a live foreign claim.
  #
  # 30 minutes is a JUDGMENT, stated rather than dressed as a derivation: it rides out
  # any board deploy, restart or slept laptop this house has measured, and it is two
  # orders short of the 12h safety cap that would otherwise bound this.
  UNREACHABLE_GRACE_SECONDS = 30 * 60

  # HOW LONG A RENEWER WITH NO DESK MAY RUN. The abandonment check's decisive evidence
  # is the desk, and with none it answers "unknown" — which, by this house's rule, never
  # frees a claim. So a desk-less renewer used to run for ShiftRenewer's full 12h cap on a
  # builder it could not see: a dead subagent inside a living session held its task for
  # half a day.
  #
  # The bound is ClaimLease::PROGRESS_QUIET_SECONDS (3h07m30s), not a new number: it is
  # the house's own derived ceiling on how long HEALTHY work goes without a durable
  # artifact (the quietest measured healthy window, cleared by half again). Holding a
  # claim we cannot observe for longer than healthy work is ever observed to go quiet
  # asserts more than the evidence carries. A dead desk-less builder's task is now
  # freed within ~3h10m instead of ~12h.
  #
  # WHAT IT COSTS, stated: a LIVE build that resolves no desk and runs past that ceiling
  # loses its lease, and headless, nothing re-adopts it. That is the rare case now —
  # multi-repo tasks resolve their desk under any repo — and it is the cost of refusing
  # to hold a claim on no evidence at all.
  DESKLESS_LIFETIME_SECONDS = ClaimLease::PROGRESS_QUIET_SECONDS

  module_function

  # The renewer's lifetime cap: ShiftRenewer's full cap when a desk can vouch for the
  # holder, the desk-less bound when nothing can.
  def lifetime_for(desk:)
    desk.to_s.strip.empty? ? DESKLESS_LIFETIME_SECONDS : ShiftRenewer::MAX_LIFETIME_SECONDS
  end

  # Keep beating? Only a different LIVE instance taking the claim says no.
  def continue?(outcome)
    outcome != LOST
  end

  # Is the thing this lease protects gone?
  def finished?(outcome)
    outcome == FINISHED
  end

  # Run until a stop condition, returning its reason — ShiftRenewer's four
  # (:anchor_gone · :work_finished · :lease_lost · :max_lifetime) plus this file's
  # own :board_unreachable, which is reported honestly rather than folded into
  # :lease_lost. "We could not ask" is not "we were told no", and a reader debugging
  # a claim that vanished needs those two apart.
  #
  # `beat` performs ONE renewal attempt and returns an outcome above. It is asked
  # exactly once per cycle, and BOTH loop questions are answered from that single
  # answer — the beat already reads the task to renew it, so asking the board a second
  # time to learn the stage would double this loop's traffic to learn a fact it is
  # holding. The cost of folding them is one wasted SLEEP (never a poll) after the task
  # leaves `building`: the beat that observes the stage change returns :not_building,
  # and `finished` sees it on the NEXT turn, before any further board call.
  def run(alive:, beat:, sleeper:, clock:,
          interval: ShiftRenewer::INTERVAL_SECONDS,
          max_lifetime: ShiftRenewer::MAX_LIFETIME_SECONDS,
          unreachable_grace: UNREACHABLE_GRACE_SECONDS)
    last = nil
    # CONSECUTIVE, and reset by any answer at all: a board that replies once has not
    # been unreachable for the window, so an intermittent connection keeps its claim.
    # Only a SUSTAINED silence exhausts the grace.
    misses = 0
    gave_up = false
    outcome = ShiftRenewer.run(
      alive: alive,
      finished: -> { finished?(last) },
      renew: lambda {
        last = beat.call
        misses = last == :cant_run ? misses + 1 : 0
        gave_up = misses * interval >= unreachable_grace
        continue?(last) && !gave_up
      },
      sleeper: sleeper,
      clock: clock,
      interval: interval,
      max_lifetime: max_lifetime
    )
    gave_up && outcome == :lease_lost ? :board_unreachable : outcome
  end
end
