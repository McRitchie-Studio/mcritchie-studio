# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../../../lib/hormozi/bundler"

# [unit] THE RANKING IS THE WHOLE POINT — and it counts SOURCES, not items.
#
# THE SHAPE OF THE DEFECT. Ranking by item count lets one talkative extraction
# agent crown a framework: an hour-long video where he explains the same idea
# six times yields six items and outranks an idea he returns to across forty
# different videos. That inverts exactly the signal we are buying — what he
# repeats ACROSS the corpus is his doctrine; what he repeats WITHIN one video is
# just a long explanation.
#
# THE SECOND DEFECT. Dozens of agents name the same idea a dozen ways ("the
# Value Equation", "Value Equation:", "value-equation"). Bundling on the raw
# string scatters one framework across a dozen cards, and the ranking then sees
# a dozen rare ideas instead of one common one.
class BundlerTest < Minitest::Test
  def test_ranks_by_distinct_sources_not_by_item_count
    bundles = build(
      "items" => [
        item(name: "Rule of 100", source_id: "v1"),
        item(name: "Rule of 100", source_id: "v1"),
        item(name: "Rule of 100", source_id: "v1"),
        item(name: "Core Four", source_id: "v7"),
        item(name: "Core Four", source_id: "v8")
      ]
    )

    assert_equal "Core Four", bundles.first.name
    assert_equal 2, bundles.first.source_count
    assert_equal 3, bundles.last.item_count, "the talkative video still keeps its items"
    assert_equal 1, bundles.last.source_count
  end

  def test_spelling_variants_collapse_into_one_bundle
    bundles = build(
      "items" => [
        item(name: "the Value Equation", source_id: "v1"),
        item(name: "Value Equation:", source_id: "v2"),
        item(name: "value-equation", source_id: "v3")
      ]
    )

    assert_equal 1, bundles.length
    assert_equal 3, bundles.first.source_count
    assert_equal "value-equation", bundles.first.slug
  end

  def test_items_missing_a_source_or_a_claim_are_dropped
    bundles = build(
      "items" => [
        item(name: "Grand Slam Offer", source_id: "v1"),
        item(name: "Ghost", source_id: ""),
        item(name: "Ghost Two", claim: ""),
        { "kind" => "vibe", "name" => "Not A Kind", "claim" => "c", "source_id" => "v9" }
      ]
    )

    assert_equal [ "Grand Slam Offer" ], bundles.map(&:name)
  end

  def test_one_truncated_batch_does_not_take_down_the_synthesis
    Dir.mktmpdir do |dir|
      good = File.join(dir, "good.json")
      bad = File.join(dir, "bad.json")
      File.write(good, JSON.generate("items" => [ item(name: "CLOSER", source_id: "v1") ]))
      File.write(bad, '{"items": [{"kind": "framework", "name": "trunc')

      bundles = nil
      _out, err = capture_io { bundles = Hormozi::Bundler.build([ good, bad ]) }

      assert_equal [ "CLOSER" ], bundles.map(&:name)
      assert_match(/skipping unreadable/, err)
    end
  end

  private

  def item(name:, source_id: "v1", claim: "a claim", kind: "framework")
    { "kind" => kind, "name" => name, "claim" => claim, "source_id" => source_id }
  end

  def build(payload)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "batch.json")
      File.write(path, JSON.generate(payload))
      Hormozi::Bundler.build([ path ])
    end
  end
end
