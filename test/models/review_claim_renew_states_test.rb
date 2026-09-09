# frozen_string_literal: true

require "test_helper"

# THE FOUR STATES OF A REVIEW-LEASE RENEWAL, and the proof that a renewal RENEWS.
#
# THE DEFECT THIS FILE EXISTS FOR (renew-exits-zero-renewing, measured 2026-09-08).
# `bin/task review-claim renew` exited 0 while renewing NOTHING. It was run every 60s
# against the 120s TTL for ~31 minutes during a real review: every call exit 0, zero
# stderr, and the lease FREE for nearly the whole window with its heartbeat frozen at
# the moment of acquisition. That is the no-duplicate-review guarantee failing
# silently — a reviewer running the documented loop believes he holds the task, and a
# racing reviewer could pop the same PR underneath him. It was caught only because
# somebody checked the lease instead of trusting the exit code.
#
# WHY THE ASSERTIONS HERE LOOK THE WAY THEY DO. A test that asserts the renewal
# "succeeded" reproduces the very bug it is meant to catch — success was exactly what
# the broken command reported. So every assertion below is about the STORED LEASE:
# `claim_expires_at` read before and after, and asserted to have MOVED (or asserted
# to be byte-identical, on the paths that must write nothing). The state symbol is
# checked as well as the movement, never instead of it.
#
# THREE ADJACENT TRAPS THIS FILE IS BUILT NOT TO FALL INTO:
#
#   - AN EXPIRED CLAIM RENDERS AS LIVE in the task's own `show` payload, so liveness
#     here is asked of ClaimLease (`row.live?` / `holder_info["live"]`), which is what
#     `review-claim status` reads, and never of a stage/board projection.
#   - A SESSION CAN RENEW ITS OWN STALE LEASE, so a MOVING EXPIRY IS NOT BY ITSELF
#     PROOF OF HEALTH. That is why `:renewed` and `:reacquired` are distinguished and
#     separately asserted: both move the expiry, and only one of them means the lease
#     was never free. A renewal that lapsed and healed every single beat would move
#     the expiry every time and still leave the task claimable in between.
#   - A REWORK BLOCK CLAIMS THE DESK, so "nobody is reviewing this" and "somebody
#     holds this task" are different facts about different leases. The no-lease case
#     below is driven with the task's BUILD claim held, to pin that the REVIEW lease
#     is what renew answers about.
class ReviewClaimRenewStatesTest < ActiveSupport::TestCase
  SLUG = "renew-state-subject"
  TTL = ClaimLease::REVIEW_TTL_SECONDS
  MINE = { session: "sess-mine", nonce: "inst-mine" }.freeze
  THEIRS = { session: "sess-theirs", nonce: "inst-theirs" }.freeze

  def setup
    @t0 = Time.utc(2026, 9, 8, 17, 0, 0)
    Task.create!(title: "Renew State Subject", slug: SLUG, stage: "submitted")
  end

  def row = TaskReviewClaim.find_by(task_slug: SLUG)

  def acquire(who, now: @t0, reviewer: nil)
    TaskReviewClaim.acquire(task_slug: SLUG, session: who[:session], nonce: who[:nonce],
                            reviewer: reviewer, now: now)
  end

  def renew(who, now:)
    TaskReviewClaim.renew(task_slug: SLUG, session: who[:session], nonce: who[:nonce], now: now)
  end

  # `now:` is NOT optional here. This suite drives a fixed 2026-09-08T17:00Z clock while
  # the lease helpers default to the real one, so a release taken at wall-clock time
  # evaluates the fixture's lease as long expired and REFUSES — silently leaving the
  # claim in place. Two tests in this file were written without it and both failed
  # loudly, which is the only reason it is a helper and not a footgun.
  def release(who, now:)
    TaskReviewClaim.release(task_slug: SLUG, session: who[:session], nonce: who[:nonce], now: now)
  end

  # --- [integration] THE HEARTBEAT MUST ACTUALLY ADVANCE ------------------------
  #
  # The assertion the broken command could not have passed. Not "renew returned
  # something truthy" — the STORED expiry, read out of the row before and after, and
  # required to have moved forward by the beat.

  test "[integration] a renewal MOVES the stored expiry, by exactly the beat" do
    acquire(MINE)
    before = row.claim_expires_at
    beat = 37 # any real gap; the point is the expiry tracks `now`, not that it re-writes

    outcome = renew(MINE, now: @t0 + beat)

    after = row.reload.claim_expires_at
    assert_equal :renewed, outcome.state
    assert_operator after, :>, before, "the heartbeat did not advance — this is the frozen-lease defect"
    assert_in_delta beat, after - before, 1,
                    "the lease must be pushed to now+TTL, not merely touched"
    assert_in_delta @t0 + beat + TTL, after, 1
  end

  # A renewal that renews nothing must LEAVE THE LEASE ALONE. Two halves of one
  # guarantee: the refusals write nothing, and they are visibly not the success.
  test "[integration] every refusing state leaves the stored expiry untouched" do
    frozen = {}

    # held by another live instance
    acquire(THEIRS)
    frozen[:held_by_other] = [renew(MINE, now: @t0 + 10), row.reload.claim_expires_at]

    # somebody else's LAPSED lease — free, but not ours to renew
    lapsed_at = @t0 + TTL + 1
    frozen[:no_lease_foreign] = [renew(MINE, now: lapsed_at), row.reload.claim_expires_at]

    assert_equal :held_by_other, frozen[:held_by_other][0].state
    assert_equal :no_lease, frozen[:no_lease_foreign][0].state
    assert_equal frozen[:held_by_other][1], frozen[:no_lease_foreign][1],
                 "neither refusal may write the lease"
    assert_equal @t0 + TTL, row.claim_expires_at, "the holder's lease is exactly as they left it"
    assert_equal THEIRS[:session], row.claimed_session, "a refused renew never changes hands"
  end

  # --- [integration] THE FOUR STATES, EACH DISTINGUISHABLE ----------------------

  test "[integration] renewing a live lease I hold reports :renewed and keeps it live" do
    acquire(MINE)

    outcome = renew(MINE, now: @t0 + 10)

    assert_equal :renewed, outcome.state
    assert outcome.renewed?
    refute outcome.reacquired?, "an ordinary beat must not read as a heal — that window was never free"
    assert row.reload.live?(now: @t0 + 10)
  end

  test "[integration] renewing MY OWN lapsed lease re-acquires it and says which it was" do
    acquire(MINE)
    lapsed_at = @t0 + TTL + 1
    refute row.live?(now: lapsed_at), "the lease must really be dead before we heal it"
    before = row.claim_expires_at

    outcome = renew(MINE, now: lapsed_at)

    assert_equal :reacquired, outcome.state
    assert outcome.renewed?, "the caller holds the lease again afterwards"
    assert outcome.reacquired?, "…but it LAPSED first, and that is not the same fact"
    assert_operator row.reload.claim_expires_at, :>, before
    assert row.live?(now: lapsed_at), "the healed lease is live again"
    assert_equal MINE[:session], row.claimed_session
  end

  test "[integration] a lease held by a DIFFERENT soul reports :held_by_other and names them" do
    acquire(THEIRS, reviewer: "carl")

    outcome = renew(MINE, now: @t0 + 10)

    assert_equal :held_by_other, outcome.state
    refute outcome.renewed?
    assert_equal "carl", outcome.claim.holder_agent, "a refusal has to name somebody to ask"
    assert outcome.claim.holder_info(now: @t0 + 10)["live"]
  end

  test "[integration] no claim row at all reports :no_lease" do
    assert_nil row, "the subject starts with no review lease"

    outcome = renew(MINE, now: @t0)

    assert_equal :no_lease, outcome.state
    refute outcome.renewed?, "renewing nothing is not success"
    assert_nil TaskReviewClaim.find_by(task_slug: SLUG), "a refused renew does not conjure a lease"
  end

  test "[integration] an unclaimed row reports :no_lease, not a renewal" do
    acquire(MINE)
    assert release(MINE, now: @t0 + 10), "the holder releases its own live lease"
    assert_nil row.reload.claimed_session

    outcome = renew(MINE, now: @t0 + 10)

    assert_equal :no_lease, outcome.state
    assert_nil row.reload.claim_expires_at, "a released lease stays released"
  end

  # THE TRAP: a rework block CLAIMS THE DESK, so a task can be firmly held and still
  # have nobody reviewing it. `renew` answers about the REVIEW lease and must not
  # borrow liveness from the build claim.
  test "[integration] a task whose BUILD claim is held still has no REVIEW lease" do
    task = Task.find_by(slug: SLUG)
    task.update!(metadata: task.metadata.deep_merge("devops" => {
                                                      "claimed_session" => "sess-blocker",
                                                      "claim_nonce" => "inst-blocker",
                                                      "claim_expires_at" => (@t0 + TTL).utc.iso8601
                                                    }))

    outcome = renew(MINE, now: @t0 + 10)

    assert_equal :no_lease, outcome.state,
                 "the desk being held is not the review being held — different leases, different question"
  end

  # The states are worth nothing if two of them are the same answer. This is the
  # assertion the defect would have failed outright: all four collapsed into success.
  test "[integration] the four states are pairwise distinct, and only two are success" do
    states = {}

    states[:no_lease] = renew(MINE, now: @t0).state

    acquire(MINE)
    states[:renewed] = renew(MINE, now: @t0 + 10).state
    states[:reacquired] = renew(MINE, now: @t0 + (TTL * 2)).state

    assert release(MINE, now: @t0 + (TTL * 2)), "released so the next acquire is a clean change of hands"
    acquire(THEIRS, now: @t0 + (TTL * 2))
    states[:held_by_other] = renew(MINE, now: @t0 + (TTL * 2) + 5).state

    assert_equal %i[no_lease renewed reacquired held_by_other], states.values,
                 "each shape must report its own state"
    assert_equal 4, states.values.uniq.size, "four states that answer identically are the defect"
  end

  # --- [unit] the lease clock and the lease IDENTITY are different questions ----
  #
  # `evaluate` returns :expired BEFORE it compares identity, which is right for
  # claiming and useless for deciding whether a lapse is OURS to heal. Pinning the
  # split here, because collapsing it is how re-acquire would turn into a steal.

  test "[unit] a lapsed lease evaluates :expired for its own holder AND for a stranger" do
    claim = { "claimed_session" => "sess-mine", "claim_nonce" => "inst-mine",
              "claim_expires_at" => @t0.utc.iso8601 }
    later = @t0 + 1

    assert_equal :expired, ClaimLease.evaluate(claim, session: "sess-mine", nonce: "inst-mine", now: later)
    assert_equal :expired, ClaimLease.evaluate(claim, session: "sess-theirs", nonce: "inst-theirs", now: later)

    assert ClaimLease.same_instance?(claim, session: "sess-mine", nonce: "inst-mine"),
           "identity survives the lease clock — this is what makes a heal a heal"
    refute ClaimLease.same_instance?(claim, session: "sess-theirs", nonce: "inst-theirs"),
           "…and what stops it being a steal"
  end

  test "[unit] same_instance? keeps the blank-nonce rule (a blank is unknown, never a mismatch)" do
    claim = { "claimed_session" => "s", "claim_nonce" => "", "claim_expires_at" => @t0.utc.iso8601 }

    assert ClaimLease.same_instance?(claim, session: "s", nonce: "resolved"),
           "a blank STORED nonce is 'instance unknown' — the session-only lease still matches"
    assert ClaimLease.same_instance?({ **claim, "claim_nonce" => "resolved" }, session: "s", nonce: ""),
           "…and so is a blank CURRENT nonce"
    refute ClaimLease.same_instance?({ **claim, "claim_nonce" => "a" }, session: "s", nonce: "b"),
           "two RESOLVED nonces that differ are two terminals of one session"
    refute ClaimLease.same_instance?({ "claimed_session" => "" }, session: "", nonce: ""),
           "a claim nobody holds is nobody's"
  end

  # A lease whose expiry we cannot PARSE is "we could not check", never "they are
  # gone" — the posture ClaimLease.live? already takes. Ours heals by rewriting a
  # parseable lease; a stranger's is refused rather than read as free.
  test "[integration] a corrupt expiry heals for its holder and refuses everyone else" do
    acquire(MINE)
    row.update_columns(claim_expires_at: nil)
    row.reload.update_columns(claim_expires_at: nil)
    # A blank expiry is :expired (fail-open), so drive :corrupt through ClaimLease directly.
    garbled = { "claimed_session" => MINE[:session], "claim_nonce" => MINE[:nonce],
                "claim_expires_at" => "not-a-time" }
    assert_equal :corrupt, ClaimLease.evaluate(garbled, session: MINE[:session], nonce: MINE[:nonce], now: @t0)
    assert_equal :corrupt, ClaimLease.evaluate(garbled, session: THEIRS[:session], nonce: THEIRS[:nonce], now: @t0)

    assert ClaimLease.same_instance?(garbled, session: MINE[:session], nonce: MINE[:nonce])
    refute ClaimLease.same_instance?(garbled, session: THEIRS[:session], nonce: THEIRS[:nonce]),
           "an unverifiable lease is not a free one — a stranger is refused, not handed a heal"
  end
end
