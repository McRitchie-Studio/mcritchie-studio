require "test_helper"

# [unit] The agent lease. Without it, two sessions draining the same queue both
# script the same game and produce two different takes for one card.
class ContentAgentClaimTest < ActiveSupport::TestCase
  setup do
    Content.delete_all
    @a = Content.create!(title: "Bills Beat Dolphins 24-17", stage: "idea", workflow: "game_recap", game_slug: "g-a")
    @b = Content.create!(title: "Jets Beat Patriots 20-17", stage: "idea", workflow: "game_recap", game_slug: "g-b")
  end

  test "claims an unclaimed content and stamps the holder" do
    result = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster")

    assert result.claimed?
    assert_equal "turf-monster", result.content.claimed_by
    assert_equal "sess-1", result.content.claim_session
    assert result.content.claimed_at.present?
  end

  # The property the whole lease exists for.
  test "two sessions draining the queue never get the same content" do
    first  = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster")
    second = Content.claim_next_for_agent(session: "sess-2", agent: "mason")

    assert first.claimed?
    assert second.claimed?
    assert_not_equal first.content.slug, second.content.slug
  end

  test "an empty queue is a normal outcome, not an error" do
    Content.update_all(claimed_at: Time.current, claim_session: "someone-else")

    result = Content.claim_next_for_agent(session: "sess-1")

    assert_not result.claimed?
    assert_nil result.content
    assert_equal "none_claimable", result.reason
  end

  test "a held content is not offered to another session" do
    held = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content
    # Park whichever card was NOT claimed, so `held` is the only candidate left.
    # (`ordered` is position-descending, so which one gets claimed is not the
    # order they were created in.)
    Content.where.not(slug: held.slug).update_all(stage: "script")

    result = Content.claim_next_for_agent(session: "sess-2", agent: "mason")

    assert_not result.claimed?, "sess-2 was handed a card sess-1 still holds"
  end

  # A session that dies mid-SOP must not strand the card forever.
  test "an expired lease is reclaimable" do
    @a.update!(claimed_by: "turf-monster", claim_session: "dead", claimed_at: 2.hours.ago)
    @b.update!(stage: "script") # leave @a as the only idea-stage card

    result = Content.claim_next_for_agent(session: "sess-2", agent: "mason")

    assert result.claimed?
    assert_equal @a.slug, result.content.slug
    assert_equal "mason", result.content.claimed_by
  end

  test "a fresh lease is not expired" do
    @a.update!(claimed_at: Time.current)

    assert @a.claim_held?
    assert_not @a.claim_expired?
  end

  test "filters by stage and workflow" do
    @a.update!(workflow: "video")

    result = Content.claim_next_for_agent(session: "s", workflow: "game_recap")

    assert_equal @b.slug, result.content.slug
  end

  test "releasing clears the lease" do
    claimed = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content

    claimed.release_claim!(session: "sess-1")

    assert_nil claimed.reload.claimed_at
    assert_nil claimed.claimed_by
  end

  # Letting a stranger release would re-open a card someone is still writing.
  test "a stranger cannot release a live claim" do
    claimed = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content

    assert_raises ArgumentError do
      claimed.release_claim!(session: "sess-2")
    end
  end

  test "an expired claim can be released by anyone" do
    @a.update!(claimed_by: "x", claim_session: "dead", claimed_at: 2.hours.ago)

    assert_nothing_raised { @a.release_claim!(session: "sess-2") }
  end

  # THE FAIL-OPEN. The old guard led with `session.present?`, so the check was
  # bypassed by OMITTING the thing being checked: the same stranger who was
  # refused with a session force-released the claim without one. The control
  # below is the half that already passed — both must hold, or this proves
  # nothing about the missing-value case.
  test "a stranger who sends NO session cannot release a live claim" do
    claimed = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content

    assert_raises(ArgumentError) { claimed.release_claim!(session: nil) }
    assert_raises(ArgumentError) { claimed.release_claim!(session: "") }
    assert_raises(ArgumentError) { claimed.release_claim!(session: "   ") }
    assert_raises(ArgumentError) { claimed.release_claim!(session: "sess-2") } # the control

    assert claimed.reload.claim_held?, "the claim must survive every refused release"
  end

  # --- the WRITE guard ---------------------------------------------------
  #
  # Release is harmless and was guarded; update is destructive and was not.
  # These pin the asymmetry closed.

  test "the live holder may write" do
    claimed = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content

    assert_nil claimed.claim_write_refusal(session: "sess-1")
    assert claimed.claim_holder?(session: "sess-1")
  end

  test "a non-holder may not write" do
    claimed = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content

    refusal = claimed.claim_write_refusal(session: "sess-2")

    assert_equal "CLAIM_HELD", refusal.code
    assert_not claimed.claim_holder?(session: "sess-2")
  end

  test "a caller who sends no session may not write a claimed card" do
    claimed = Content.claim_next_for_agent(session: "sess-1", agent: "turf-monster").content

    [nil, "", "  "].each do |given|
      assert_equal "CLAIM_REQUIRED", claimed.claim_write_refusal(session: given)&.code,
                   "session #{given.inspect} must not be able to write"
    end
  end

  test "an unclaimed card may not be written at all" do
    assert_equal "CLAIM_REQUIRED", @a.claim_write_refusal(session: "sess-1")&.code
  end

  # The reachable collision this whole guard exists for: A claims, A's inference
  # runs past the lease, B legitimately claims the lapsed card, and A's write
  # must NOT land. "It was mine when I started" is not a right to write.
  test "a lapsed lease refuses its own original holder" do
    @a.update!(claimed_by: "turf-monster", claim_session: "sess-1",
               claimed_at: (Content::AGENT_CLAIM_LEASE + 1.minute).ago)

    refusal = @a.claim_write_refusal(session: "sess-1")

    assert_equal "CLAIM_LAPSED", refusal.code
    assert_match(/claim it again/, refusal.message)
  end

  # A claim nobody can prove belongs to them is a claim nobody may write
  # through. It is bounded — the lease drops it within AGENT_CLAIM_LEASE.
  test "a sessionless claim cannot be written through by anyone" do
    @a.update!(claimed_by: "turf-monster", claim_session: nil, claimed_at: Time.current)

    assert_equal "CLAIM_REQUIRED", @a.claim_write_refusal(session: "sess-1")&.code
    assert_equal "CLAIM_REQUIRED", @a.claim_write_refusal(session: nil)&.code
  end

  # --- THE SESSION MUST IDENTIFY A SOUL, NOT A CHECKOUT ---------------------
  #
  # THE DEFECT (found at PR 1498's review, verified 2026-09-22). `bin/content`
  # derived its session from `tmp/content-session` — ONE FILE PER CHECKOUT — while
  # the content-build SOP sends every soul to the hub primary. Two souls therefore
  # presented the SAME string, and the guard is only ever as good as that string.
  #
  # The model was never wrong. These pin what it does at each side of the seam, so
  # a future caller that reintroduces a shared id fails HERE and not in a video.

  # The exact sequence the lease exists to prevent, driven end to end.
  test "the lapsed-reclaim collision is refused when the two souls differ" do
    @b.update!(stage: "script") # leave @a the only candidate
    a = Content.claim_next_for_agent(session: "soul-a", agent: "turf-monster").content
    assert_equal "soul-a", a.claim_session

    # A's lease lapses mid-inference; B legitimately reclaims the freed card.
    a.update!(claimed_at: 2.hours.ago)
    b = Content.claim_next_for_agent(session: "soul-b", agent: "mason")
    assert b.claimed?, "the lapsed card must be reclaimable — that half is correct"

    # A, still mid-inference, writes. It must be refused.
    refusal = b.content.reload.claim_write_refusal(session: "soul-a")

    assert_not_nil refusal, "A wrote on top of B's claim"
    assert_equal "CLAIM_HELD", refusal.code
  end

  # THE CONTROL, and the reason the case above is not vacuous: run the IDENTICAL
  # sequence with ONE session string for both souls — which is exactly what one
  # `tmp/content-session` per checkout produced — and the write is PERMITTED.
  # The refusal above comes from the sessions differing, not from the sequence.
  test "the same sequence under one shared session is permitted" do
    @b.update!(stage: "script")
    a = Content.claim_next_for_agent(session: "shared", agent: "turf-monster").content
    a.update!(claimed_at: 2.hours.ago)
    b = Content.claim_next_for_agent(session: "shared", agent: "mason")

    assert b.claimed?
    assert_nil b.content.reload.claim_write_refusal(session: "shared"),
               "this IS the bug: one string, two souls, and the guard cannot see it"
  end

  # --- normalization runs on BOTH sides of the seam now ---------------------
  #
  # It used to run on the READ side only: the claim stored `claim_session` raw, so
  # a padded session was compared against its own stripped self and CLAIM_HELD
  # locked the holder out of write AND release for the full lease.

  test "a padded session is stored stripped" do
    result = Content.claim_next_for_agent(session: "  sess-1  ", agent: "turf-monster")

    assert_equal "sess-1", result.content.claim_session
  end

  test "a padded session does not lock its own holder out of writing" do
    held = Content.claim_next_for_agent(session: "  sess-1  ", agent: "turf-monster").content

    assert_nil held.claim_write_refusal(session: "  sess-1  "),
               "the holder was refused its own claim"
    assert_nil held.claim_write_refusal(session: "sess-1"),
               "and the same session unpadded is the same session"
  end

  test "a padded session does not lock its own holder out of releasing" do
    held = Content.claim_next_for_agent(session: "  sess-1  ", agent: "turf-monster").content

    assert_nothing_raised { held.release_claim!(session: "  sess-1  ") }
    assert_nil held.reload.claim_session
  end

  # A stranger is still refused — the fix must not have been bought by loosening
  # the comparison.
  test "a padded claim still refuses a different session" do
    held = Content.claim_next_for_agent(session: "  sess-1  ", agent: "turf-monster").content

    assert_equal "CLAIM_HELD", held.claim_write_refusal(session: "sess-2").code
  end

  # --- a claim nobody can prove is not a claim ------------------------------
  #
  # A blank session used to be ACCEPTED: the row was stamped `claim_session: nil`
  # and `claim_write_refusal` then answered CLAIM_REQUIRED to everyone — including
  # the caller that had just taken it — for the full 30-minute lease. A blank
  # session bought a denial of service against a card nobody could write.

  test "a session-less claim is refused rather than taken" do

    [nil, "", "   "].each do |blank|
      result = Content.claim_next_for_agent(session: blank, agent: "turf-monster")

      assert_not result.claimed?, "a claim nobody can prove was taken for #{blank.inspect}"
      assert_equal "session_required", result.reason
    end
  end

  test "a refused session-less claim leaves the queue untouched" do
    Content.claim_next_for_agent(session: nil, agent: "turf-monster")

    assert_equal 0, Content.where.not(claimed_at: nil).count,
                 "the refusal must not park a card nobody can ever write"
  end
end
