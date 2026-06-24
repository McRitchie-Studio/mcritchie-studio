# frozen_string_literal: true

# Unit test for the pure mascot resolution behind the per-session active-feature
# marker. The guarantee under test: a fallback chain that never downgrades a
# known mascot to blank, and that short-circuits so a costly later source (a
# board API read) is skipped once an earlier one is present.
#
#   ruby -Itest test/lib/feature_marker_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../lib/feature_marker"

class FeatureMarkerTest < Minitest::Test
  def test_first_present_source_wins
    assert_equal "alakazam", FeatureMarker.mascot("alakazam", "snorlax")
  end

  def test_blank_sources_are_skipped
    assert_equal "snorlax", FeatureMarker.mascot("", "snorlax")
    assert_equal "snorlax", FeatureMarker.mascot(nil, "  ", "snorlax")
  end

  def test_nil_when_every_source_is_blank
    assert_nil FeatureMarker.mascot("", nil, "   ")
    assert_nil FeatureMarker.mascot
  end

  # The no-downgrade guarantee: a present response keeps its mascot; later
  # sources (on-disk, board) only matter when the earlier ones are blank.
  def test_present_response_keeps_its_value_over_later_sources
    assert_equal "pikachu", FeatureMarker.mascot("pikachu", "ditto", "mew")
  end

  # Lazy: a later callable source (e.g. a board API read) is NEVER evaluated once
  # an earlier source is present — that's what keeps ordinary marker writes off
  # the network.
  def test_later_callable_sources_short_circuit
    assert_equal "pikachu", FeatureMarker.mascot("pikachu", -> { flunk "must not evaluate a later source" })
  end

  def test_callable_source_is_used_when_earlier_sources_blank
    assert_equal "eevee", FeatureMarker.mascot("", -> { "eevee" })
    assert_equal "zubat", FeatureMarker.mascot("", -> { "" }, -> { "zubat" })
  end
end
