# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/hormozi/triage"

# [unit] A CMO BUILT ON THE WHOLE ARCHIVE ANSWERS A HOOK QUESTION WITH AN
# ANECDOTE ABOUT FIRING SOMEONE.
#
# THE SHAPE OF THE DEFECT. The corpus is roughly 1,700 videos and most of them
# are not about marketing — hiring, operations, mindset, morning routines,
# personal stories. Rex is hired for one job: demand. Extracting evenly across
# the archive buys a general-purpose life coach at four times the price of the
# specialist we asked for.
#
# WHAT THIS PROTECTS. Tier 1 is what earns a deep extraction pass, so these
# assertions are the actual boundary of Rex's education. The negative cases
# matter most: a title can carry a commercial word like "sales" and still be an
# operations lesson, and it must not buy its way into tier 1 on that alone.
class TriageTest < Minitest::Test
  def test_a_marketing_title_reaches_tier_one
    verdict = Hormozi::Triage.score("How To Make Your Offer Irresistible")

    assert_equal 1, verdict.tier
    assert_includes verdict.matched, "offer"
  end

  def test_channel_and_creative_terms_stack
    verdict = Hormozi::Triage.score("3 Hooks That Get More Leads On Instagram")

    assert_equal 1, verdict.tier
    assert_equal %w[hooks instagram leads], verdict.matched
  end

  def test_an_operations_title_falls_to_tier_three
    verdict = Hormozi::Triage.score("How I Fire Employees Without Guilt")

    assert_equal 3, verdict.tier
    assert_empty verdict.matched
  end

  def test_a_commercial_word_inside_an_operations_lesson_does_not_buy_tier_one
    verdict = Hormozi::Triage.score("Why Your Sales Team Keeps Quitting")

    assert_equal 3, verdict.tier, "sales(+1) must not outweigh team(-2) and quitting's operations frame"
  end

  def test_an_adjacent_commercial_title_lands_in_tier_two
    verdict = Hormozi::Triage.score("The Pricing Change That Doubled Revenue")

    assert_equal 2, verdict.tier
  end

  # Measured against the real manifest on 2026-09-19: these three titles all
  # scored ZERO on nouns alone and sat in tier 3 beside the morning-routine
  # videos, which is where the case bank would have died.
  def test_a_live_teardown_reaches_tier_one_on_format_alone
    verdict = Hormozi::Triage.score("Building a $1,000,000 Business for a Stranger in 69 Minutes")

    assert_equal 1, verdict.tier
    assert_includes verdict.matched, "format:teardown"
    assert_includes verdict.matched, "format:timeboxed"
  end

  def test_a_starting_over_title_reaches_tier_one_on_format_alone
    verdict = Hormozi::Triage.score("If I Wanted to Create a Business That Runs Itself, Here's What I'd Do")

    assert_equal 1, verdict.tier
    assert_includes verdict.matched, "format:starting-over"
  end

  def test_a_plural_marketing_noun_still_matches
    verdict = Hormozi::Triage.score("How to 10x Your Business Overnight with Influencers")

    assert_equal 1, verdict.tier
    assert_includes verdict.matched, "influencers"
  end

  def test_a_token_is_counted_once_in_its_strongest_list
    verdict = Hormozi::Triage.score("Customers")

    assert_equal Hormozi::Triage::CORE_POINTS, verdict.score,
                 "customers is CORE and stems to ADJACENT customer — it must not score both"
  end

  def test_the_description_is_scored_when_the_title_is_thin
    bare = Hormozi::Triage.score("Ep 412")
    described = Hormozi::Triage.score("Ep 412", "A teardown of a paid ads funnel and its landing page copy")

    assert_equal 3, bare.tier
    assert_equal 1, described.tier
  end
end
