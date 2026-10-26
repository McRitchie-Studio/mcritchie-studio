# frozen_string_literal: true

require "test_helper"
require Rails.root.join("bin/lib/dream_bank").to_s

# [component] /dreams shows Alex McRitchie's chat ruling beside the card it rules on: the
# quote and the session for a chat approval, retirement or drop, and nothing extra
# for his click (docs/agents/modules/dream.md, Act 3, "In chat").
class DreamsChatRulingPageTest < ActionDispatch::IntegrationTest
  BANK = Rails.root.join("test/fixtures/dreams").to_s
  PROPOSED = DreamBank::Dream.new(slug: "proposed-money-idea", home: "pokemon", status: "proposed")
  APPROVED = DreamBank::Dream.new(slug: "money-review-reads-the-ledger", home: "carl", status: "approved")

  setup do
    @previous_bank = ENV["DREAM_BANK_DIR"]
    ENV["DREAM_BANK_DIR"] = BANK
    log_in_as(users(:alex))
  end

  teardown { ENV["DREAM_BANK_DIR"] = @previous_bank }

  def rule(ruling, dream, words)
    DreamRuling.record!(ruling: ruling, dream: dream, clearance: words, session_id: "0f1e2d3c-chat-session")
  end

  test "[component] a chat approval shows his words and the session beside the approval note" do
    rule("approve", PROPOSED, "Approve it, refunds go through the ledger")

    get dreams_path

    assert_select "[data-dream='proposed-money-idea']" do
      assert_select "[data-test='dream-approved-pending-badge']"
      assert_select "[data-test='dream-approval-note']", text: /in chat/
      assert_select "[data-test='dream-clearance-quote']", text: "Approve it, refunds go through the ledger"
      assert_select "[data-test='dream-clearance'] code", text: "0f1e2d3c"
      assert_select "[data-test='dream-approve']", 0, "a ruled dream offers no second Approve"
    end
  end

  test "[component] a chat drop marks the proposed card dropped, with the quote" do
    rule("drop", PROPOSED, "drop that one, it is only a fact")

    get dreams_path

    assert_select "[data-dream='proposed-money-idea']" do
      assert_select "[data-test='dream-dropped-badge']"
      assert_select "[data-test='dream-retirement-note']", text: /Dropped .* in chat/m
      assert_select "[data-test='dream-clearance-quote']", text: "drop that one, it is only a fact"
      assert_select "[data-test='dream-approve']", 0
    end
  end

  test "[component] a chat retirement shows the quote; a click shows none" do
    rule("retire", APPROVED, "retire the ledger one now")
    DreamApproval.record!(PROPOSED, users(:alex))

    get dreams_path

    assert_select "[data-dream='money-review-reads-the-ledger'] [data-test='dream-clearance-quote']",
                  text: "retire the ledger one now"
    assert_select "[data-dream='proposed-money-idea'] [data-test='dream-approval-note']", text: /\AApproved [\d-]+\. /
    assert_select "[data-dream='proposed-money-idea'] [data-test='dream-clearance']", 0, "a click carries no quote"
  end
end
