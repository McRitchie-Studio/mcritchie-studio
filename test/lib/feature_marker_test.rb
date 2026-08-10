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

  # --- genesis: the write-once first-task fields -----------------------------

  SEED = {
    "genesis_slug" => "second-task", "genesis_feature" => "second-task",
    "genesis_url" => "https://mcritchie.studio/tasks/second-task",
    "genesis_at" => "2026-08-09T12:00:00Z"
  }.freeze

  def test_genesis_seeds_from_the_first_task_bearing_write
    assert_equal SEED, FeatureMarker.genesis(nil, SEED)
    assert_equal SEED, FeatureMarker.genesis({ "slug" => "second-task" }, SEED)
  end

  # Write-once: an on-disk genesis is carried forward VERBATIM — a later task's
  # seed never repoints it. This is the whole guarantee.
  def test_on_disk_genesis_wins_over_a_later_seed
    disk = {
      "slug" => "second-task", # the ACTIVE context has moved on…
      "genesis_slug" => "first-task", "genesis_feature" => "first-task",
      "genesis_url" => "https://mcritchie.studio/tasks/first-task",
      "genesis_at" => "2026-08-09T09:00:00Z"
    }
    kept = FeatureMarker.genesis(disk, SEED)
    assert_equal "first-task", kept["genesis_slug"], "…but the genesis never does"
    assert_equal "first-task", kept["genesis_feature"]
    assert_equal "https://mcritchie.studio/tasks/first-task", kept["genesis_url"]
    assert_equal "2026-08-09T09:00:00Z", kept["genesis_at"]
  end

  def test_genesis_returns_only_genesis_keys
    disk = { "slug" => "x", "mascot" => "snorlax", "genesis_slug" => "first-task" }
    assert_equal({ "genesis_slug" => "first-task" }, FeatureMarker.genesis(disk, SEED),
                 "non-genesis marker fields never ride along")
  end

  def test_blank_disk_genesis_does_not_block_the_seed
    disk = { "genesis_slug" => "  " }
    assert_equal SEED, FeatureMarker.genesis(disk, SEED)
  end

  def test_blank_seed_values_are_dropped
    seeded = FeatureMarker.genesis(nil, SEED.merge("genesis_url" => "", "genesis_at" => nil))
    assert_equal %w[genesis_slug genesis_feature], seeded.keys
  end
end
