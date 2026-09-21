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
end
