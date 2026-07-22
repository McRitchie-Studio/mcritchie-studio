# frozen_string_literal: true

# Unit tests for ZapRevalidation.decide — the pure pre-merge decision that hosts
# reviewer-applied zaps (bin/pr-review). No gh, no CI, no subprocess: every branch is
# driven from a synthetic (reviewed_head, current_head, ci_state).
#
# Run directly:  ruby -Itest test/lib/zap_revalidation_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/zap_revalidation"

class ZapRevalidationTest < Minitest::Test
  HEAD = "aaaaaaa1111111111111111111111111111111111"
  ZAP  = "bbbbbbb2222222222222222222222222222222222"

  # The ordinary path: the head the reviewers approved is the head we would merge.
  def test_unchanged_head_merges
    assert_equal :merge, ZapRevalidation.decide(HEAD, HEAD, :green)
    assert_equal :merge, ZapRevalidation.decide(HEAD, HEAD, :red), "CI state is irrelevant when the head did not move"
  end

  # A gh read fault or an older run that captured no head must never START holding —
  # the revalidation only ADDS a hold, it never removes the pre-existing merge path.
  def test_unknowable_head_merges
    assert_equal :merge, ZapRevalidation.decide(nil, ZAP, :red), "no reviewed head captured -> merge as before"
    assert_equal :merge, ZapRevalidation.decide(HEAD, nil, :red), "could not read the current head -> merge as before"
  end

  # A reviewer zap advanced the head; its OWN CI is green, so the zapped content is
  # vouched for and it may merge.
  def test_advanced_head_with_green_ci_merges_after_zap
    assert_equal :merge_after_zap, ZapRevalidation.decide(HEAD, ZAP, :green)
  end

  # A head the reviewers did not see, on anything but a positive green, HOLDS — fail
  # closed across red, pending, none, unverified, and nil alike.
  def test_advanced_head_without_green_ci_holds_for_rereview
    [:red, :pending, :none, :unverified, :unreadable, nil].each do |state|
      assert_equal :hold_for_rereview, ZapRevalidation.decide(HEAD, ZAP, state),
                   "an advanced head with CI #{state.inspect} must hold, never merge unseen content"
    end
  end
end
