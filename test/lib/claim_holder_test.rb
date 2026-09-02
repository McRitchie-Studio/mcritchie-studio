# frozen_string_literal: true

require "test_helper"
require "time"

# [unit] ClaimHolder — the role, the freshness, and the observation.
#
# THE DEFECT, restated as the two things this file asserts:
#
#   1. A refusal that describes EVERY holder as a rival builder, and offers
#      `--steal`. The holder is often a REVIEWER, and stealing mid-review voids
#      the no-self-review guarantee and strands the verdict.
#   2. A lease rendered as a BARE TIMESTAMP, so an expired claim and a live one
#      are the same picture. Measured: `expires 2026-09-02T04:12:26Z` printed at
#      04:14:28Z with no mark.
#
# The near-miss's own numbers are used as fixtures below, so the case that
# produced this file is the case the file demonstrably covers.
class ClaimHolderTest < ActiveSupport::TestCase
  # The measured moment: the reader was looking at 04:14:28Z, and the lease had
  # lapsed at 04:12:26Z — two minutes and two seconds earlier.
  MEASURED_NOW = Time.parse("2026-09-02T04:14:28Z")
  MEASURED_EXPIRY = "2026-09-02T04:12:26Z"

  HOLDER = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b"
  REVIEWER = "7c21d0aa-15be-4f0d-9a33-0b6e12c4d9c1"

  def claim(expires_at, session: HOLDER, nonce: "holder01")
    { "claimed_session" => session, "claim_nonce" => nonce, "claim_expires_at" => expires_at }
  end

  def live_claim(seconds_out = 47, **opts)
    claim((MEASURED_NOW + seconds_out).utc.iso8601, **opts)
  end

  # ── FRESHNESS: THE MEASURED RENDERING ───────────────────────────────────────

  test "[unit] the exact lease that misled the reader renders as EXPIRED" do
    rendered = ClaimHolder.render_lease(claim(MEASURED_EXPIRY), now: MEASURED_NOW)

    assert_includes rendered, "EXPIRED",
                    "this is the measured near-miss verbatim — the lease lapsed at " \
                    "#{MEASURED_EXPIRY} and was read at #{MEASURED_NOW.utc.iso8601}. Rendering it " \
                    "without a verdict is what let a dead claim read as a live one twice in a row"
    assert_includes rendered, "free to claim", "and it must say what that means for the reader"
  end

  test "[unit] a live lease and an expired one do not render alike" do
    live = ClaimHolder.render_lease(live_claim, now: MEASURED_NOW)
    dead = ClaimHolder.render_lease(claim(MEASURED_EXPIRY), now: MEASURED_NOW)

    # THE WHOLE BUG IN ONE ASSERTION. The old line printed `expires <ts>` for both,
    # so the two differed only in a timestamp the reader had to compare by hand.
    refute_equal live, dead, "an expired lease must not be the same picture as a live one"
    assert_includes live, "LIVE"
    assert_includes live, "lapses in 47s", "a live lease must state the time it has LEFT, " \
                                           "not merely the instant it dies"
  end

  test "[unit] the four lease states are told apart" do
    assert_equal ClaimHolder::LIVE, ClaimHolder.lease_state(live_claim, now: MEASURED_NOW)
    assert_equal ClaimHolder::EXPIRED, ClaimHolder.lease_state(claim(MEASURED_EXPIRY), now: MEASURED_NOW)
    assert_equal ClaimHolder::NONE, ClaimHolder.lease_state({}, now: MEASURED_NOW)
    assert_equal ClaimHolder::UNVERIFIABLE, ClaimHolder.lease_state(claim("not-a-time"), now: MEASURED_NOW)
  end

  test "[unit] a blank expiry reads as expired, never as live" do
    assert_equal ClaimHolder::EXPIRED, ClaimHolder.lease_state(claim(nil), now: MEASURED_NOW),
                 "the renewer always writes an expiry, so a blank one is a never-renewed relic — " \
                 "ClaimLease's own posture, and reading it as live would lock a task forever"
  end

  test "[unit] an unverifiable expiry says so rather than claiming the lease is dead" do
    rendered = ClaimHolder.render_lease(claim("garbage"), now: MEASURED_NOW)

    assert_includes rendered, "UNVERIFIABLE"
    refute_includes rendered, "free to claim",
                    "'we could not check' is not 'nobody holds it' — collapsing them is how a " \
                    "live desk reads as free"
  end

  # ── ROLE: THE ROUTING THIS FILE EXISTS FOR ──────────────────────────────────

  test "[unit] a live review makes the holder a REVIEWER, and REVIEWERS are not stealable" do
    role = ClaimHolder.role(review_in_progress: true, review_claim_live: true)

    assert_equal ClaimHolder::REVIEWING, role
    refute ClaimHolder.stealable?(role),
           "stealing mid-review voids the no-self-review guarantee and strands the verdict — " \
           "neither is recoverable by re-running anything"
  end

  test "[unit] no review in flight makes the holder a BUILDER, and --steal stays available" do
    role = ClaimHolder.role(review_in_progress: false, review_claim_live: false)

    assert_equal ClaimHolder::BUILDING, role
    assert ClaimHolder.stealable?(role),
           "--steal is the correct remedy for the builder case it was written for; removing it " \
           "would wedge every legitimate takeover"
  end

  # THE FAIL-CLOSED HALF. Both facts are tri-state, and a source that did not answer
  # must not be read as a source that said no.
  test "[unit] an unreported review is UNKNOWN, not BUILDING" do
    role = ClaimHolder.role(review_in_progress: nil, review_claim_live: nil)

    assert_equal ClaimHolder::UNKNOWN, role
    refute ClaimHolder.stealable?(role),
           "absence of a signal must never read as an affirmative negative — an unknown routed " \
           "to --steal is the original bug with an extra step"
  end

  # ── THE FOLD IS LOPSIDED: EITHER YES WINS, ONLY BOTH NO IS A BUILD ──────────
  #
  # Neither source is sufficient alone. `review_in_progress` is STAGE-SCOPED (false
  # unless the task is `submitted`), so a task bounced back to `building` under a
  # live review lease answers false while a reviewer holds it. The lease read, for
  # its part, can simply fail.

  test "[unit] a live review LEASE makes it a review even when the column says false" do
    assert_equal ClaimHolder::REVIEWING,
                 ClaimHolder.role(review_in_progress: false, review_claim_live: true),
                 "the column is scoped to `submitted`; a bounced task under a live lease is " \
                 "still a review whose verdict a steal would strand"
  end

  test "[unit] a live column makes it a review even when no lease is held" do
    assert_equal ClaimHolder::REVIEWING,
                 ClaimHolder.role(review_in_progress: true, review_claim_live: false),
                 "bin/reviewer-select records the review pair before any reviewer claims, and a " \
                 "hand-run review may never claim at all — absent evidence of a lease is not " \
                 "evidence of no review"
  end

  test "[unit] only BOTH sources saying no is a build" do
    assert_equal ClaimHolder::BUILDING,
                 ClaimHolder.role(review_in_progress: false, review_claim_live: false)
  end

  test "[unit] one source answering no while the other is silent is still UNKNOWN" do
    assert_equal ClaimHolder::UNKNOWN,
                 ClaimHolder.role(review_in_progress: false, review_claim_live: nil),
                 "a failed lease read beside a stage-scoped false is not two noes; treating it " \
                 "as one is how a board hiccup turns into a stolen review"
    assert_equal ClaimHolder::UNKNOWN,
                 ClaimHolder.role(review_in_progress: nil, review_claim_live: false)
  end

  # ── THE REFUSAL ─────────────────────────────────────────────────────────────

  test "[unit] a reviewer-held task refuses with the ASK remedy and no steal" do
    text = refusal_for(true, reviewer: "carl", reviewer_session: REVIEWER)

    assert_includes text, "REVIEWING it", "the refusal must NAME the role it is refusing on"
    assert_includes text, "bin/task review-claim release probe-task",
                     "the remedy for a live review is to ask the holder to release it"
    assert_includes text, "carl", "'ask them' is useless without a them"
    refute_includes text, "--steal",
                    "the steal path must not appear at all on this branch — the near-miss was a " \
                    "reader acting on the remedy line, and a --steal anywhere in it is the line " \
                    "they would have taken"
  end

  test "[unit] the reviewer refusal states what a steal would cost" do
    text = refusal_for(true, reviewer: "carl", reviewer_session: REVIEWER)

    assert_includes text, "NO-SELF-REVIEW",
                     "the argument is the point: a reader who knows only 'do not' will do it anyway " \
                     "the next time it is inconvenient"
    assert_includes text, "STRANDS THE REVIEWER'S VERDICT"
  end

  test "[unit] a builder-held task keeps the steal remedy" do
    text = refusal_for(false)

    assert_includes text, "BUILDING it"
    assert_includes text, "bin/task begin probe-task --steal",
                     "--steal is what this case was written for and must stay pasteable"
    refute_includes text, "review-claim release",
                     "there is no review to ask about; offering one would send the reader nowhere"
  end

  test "[unit] an undetermined role refuses BOTH ways and hands over the command that decides" do
    text = refusal_for(nil)

    assert_includes text, "UNDETERMINED"
    assert_includes text, "bin/task review-claim status probe-task",
                     "an unknown must route to the command that OBSERVES, not to a guess"
    assert_includes text, "DO NOT STEAL UNTIL YOU KNOW"
  end

  # The refusal fires only on a LIVE lease, and it must say how much of that lease
  # is left — "last heartbeat ~117s ago" alone is what read as a healthy holder
  # three seconds before it lapsed.
  test "[unit] the refusal states the lease's remaining life, not only its heartbeat age" do
    text = refusal_for(false, claim: live_claim(3))

    assert_includes text, "lapses in 3s",
                     "a holder three seconds from lapsing is a holder you wait for, not one you steal"
    assert_includes text, "last heartbeat",
                     "and when it last proved itself, which is the other half of the same number"
  end

  test "[unit] the refusal names which session holds what" do
    same = refusal_for(true, reviewer_session: HOLDER)
    other = refusal_for(true, reviewer_session: REVIEWER)

    assert_includes same, "SAME session that holds the build claim"
    assert_includes other, "DIFFERENT session from the build-claim holder"
  end

  # THE ROUTE IS ON THE TASK, NOT THE SESSION. Both shapes occur, and a steal
  # strands the verdict in both.
  test "[unit] a review by a different session still routes to ask" do
    text = refusal_for(true, reviewer_session: REVIEWER)

    refute_includes text, "--steal",
                    "whose session holds the build lease changes the FACTS the refusal states, " \
                    "never the route: the verdict is stranded either way"
  end

  # ── THE --steal OVERRIDE ────────────────────────────────────────────────────

  test "[unit] a steal over a live review names the guarantee it waives" do
    text = ClaimHolder.steal_override_warning("probe-task", reviewer: "carl",
                                                            reviewer_session: REVIEWER).join("\n")

    assert_includes text, "NO-SELF-REVIEW"
    assert_includes text, "carl"
    assert_includes text, "bin/task review-claim release probe-task",
                     "the override must still point at the clean path — it is an override, " \
                     "not an endorsement"
  end

  # ── THE OBSERVATION ─────────────────────────────────────────────────────────
  #
  # The fact two sessions independently failed to derive: DIFFERENCING two reads
  # answers what SAMPLING twice does not. Each case below is one of the states a
  # differenced pair can be in.

  test "[unit] an expiry that MOVED is a live holder renewing" do
    assert_equal ClaimHolder::RENEWING, observe(first_out: 60, second_out: 90, watched: 32)
  end

  test "[unit] an expiry unchanged past its own deadline is LAPSED" do
    assert_equal ClaimHolder::LAPSED, observe(first_out: 10, second_out: 10, watched: 15),
                 "we outlasted the lease and it never moved — that is not an inference, " \
                 "it is the definition of a dead lease"
  end

  test "[unit] an expiry unchanged across a full renewal cycle is NOT RENEWING" do
    assert_equal ClaimHolder::NOT_RENEWING, observe(first_out: 300, second_out: 300, watched: 45),
                 "nothing heartbeat it in longer than the cadence that would have"
  end

  # THE HONEST-IGNORANCE CASE, and the one a shorter window must never be allowed
  # to dress up as an answer.
  test "[unit] an expiry unchanged over too short a window is INCONCLUSIVE" do
    assert_equal ClaimHolder::INCONCLUSIVE, observe(first_out: 300, second_out: 300, watched: 10),
                 "ten seconds of a thirty-second cadence proves nothing either way, and reporting " \
                 "it as 'not renewing' is exactly the confident-wrong answer this replaces"
  end

  test "[unit] an already-lapsed lease is FREE from the first read, with no waiting" do
    assert_equal ClaimHolder::FREE, observe(first_out: -122, second_out: -122, watched: 0),
                 "the measured near-miss's claim was already dead when it was first read; " \
                 "making the caller wait to learn that would be the same bug, slower"
  end

  test "[unit] a released claim is FREE" do
    assert_equal ClaimHolder::FREE, observe(first_out: 300, second_out: nil, watched: 10)
  end

  # AN EXPIRY THAT WENT BACKWARDS is a change of HANDS, not evidence that the
  # holder we asked about is renewing.
  test "[unit] an expiry that moved backwards is not reported as renewing" do
    grade = observe(first_out: 300, second_out: 200, watched: 45)

    refute_equal ClaimHolder::RENEWING, grade,
                 "a release-and-retake is not this holder heartbeating, and reporting it as one " \
                 "would attest liveness nobody observed"
    assert_equal ClaimHolder::NOT_RENEWING, grade
  end

  test "[unit] only free and lapsed count as available" do
    assert ClaimHolder.observed_free?(ClaimHolder::FREE)
    assert ClaimHolder.observed_free?(ClaimHolder::LAPSED)
    [ClaimHolder::RENEWING, ClaimHolder::NOT_RENEWING,
     ClaimHolder::INCONCLUSIVE, ClaimHolder::UNOBSERVED].each do |grade|
      refute ClaimHolder.observed_free?(grade),
             "#{grade} is not proof the task is free — an allowlist keeps a grade added later " \
             "from inheriting availability by falling outside a blacklist"
    end
  end

  test "[unit] a single read reports itself as unobserved rather than as an answer" do
    text = ClaimHolder.render_observation(ClaimHolder::UNOBSERVED)

    assert_includes text, "single read cannot tell renewing from dying",
                     "74s into a 120s TTL looks identical either way — the command must say so " \
                     "instead of letting one sample pass for an observation"
  end

  private

  def refusal_for(review_in_progress, reviewer: nil, reviewer_session: nil, claim: nil)
    ClaimHolder.refusal(
      slug: "probe-task", claim: claim || live_claim,
      role: ClaimHolder.role(review_in_progress: review_in_progress,
                             review_claim_live: review_in_progress),
      steal_command: "bin/task begin probe-task --steal",
      retry_command: "bin/ship probe-task",
      reviewer: reviewer, reviewer_session: reviewer_session, now: MEASURED_NOW
    ).join("\n")
  end

  # `watched` seconds of wall time between the two reads, with both expiries stated
  # relative to the FIRST read. nil `second_out` means the claim row was released.
  def observe(first_out:, second_out:, watched:, renew_interval: 30)
    started = MEASURED_NOW
    ClaimHolder.observe(
      first_expires_at: (started + first_out).utc.iso8601,
      second_expires_at: second_out.nil? ? nil : (started + second_out).utc.iso8601,
      first_read_at: started, renew_interval: renew_interval, now: started + watched
    )
  end
end
