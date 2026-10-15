# frozen_string_literal: true

# [unit] DreamLayers: the layer keys a dream counts in, their budgets, and which
# approved dreams fill a layer.
#   ruby -Itest test/lib/dream_layers_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/dream_layers"

class DreamLayersTest < Minitest::Test
  def dream(slug, souls: [], status: "approved")
    DreamBank::Dream.new(slug: slug, home: souls.first || "platform", status: status, question: "Q?", answer: "A.",
                         why: "", tags: souls.empty? ? {} : { "soul" => souls }, source: "", story: "")
  end

  def test_unit_keys_name_the_platform_and_each_soul
    assert_equal [ "platform" ], DreamLayers.keys(dream("a"))
    assert_equal %w[soul/carl soul/xan], DreamLayers.keys(dream("b", souls: %w[carl alex]))
    assert_equal "soul/carl", DreamLayers.key(dream("b", souls: %w[carl xan]))
  end

  def test_unit_budgets_are_dream_banks
    assert_equal 15, DreamLayers.budget("platform")
    assert_equal 20, DreamLayers.budget("soul/carl")
    assert_equal 5, DreamLayers.budget("step/building-sop/begin")
    assert_same DreamBank::BUDGETS, DreamLayers.budgets
  end

  def test_unit_a_step_dream_counts_in_its_step_layer
    step = DreamBank::Dream.new(slug: "s", home: "sops/building-sop", status: "approved", question: "Q?", answer: "A.",
                                why: "", tags: { "sop" => [ "building-sop" ], "step" => [ "begin" ] }, source: "", story: "")
    assert_equal [ "step/building-sop/begin" ], DreamLayers.keys(step)
    assert_equal [ step ], DreamLayers.members([ step ], "step/building-sop/begin")
  end

  def test_unit_valid_keys
    %w[platform soul/carl step/building-sop/begin].each { |key| assert DreamLayers.valid?(key), key }
    [ "", "soul", "soul/", "soul/Carl", "step/a", "platform/x", "galaxy/x", "soul/../x" ].each do |key|
      refute DreamLayers.valid?(key), key
    end
  end

  def test_unit_members_are_the_approved_dreams_in_the_layer
    dreams = [ dream("a"), dream("b", souls: %w[carl]), dream("c", souls: %w[carl xan]),
               dream("d", souls: %w[carl], status: "proposed") ]

    assert_equal %w[b c], DreamLayers.members(dreams, "soul/carl").map(&:slug)
    assert_equal %w[c], DreamLayers.members(dreams, "soul/xan").map(&:slug)
    assert_equal %w[platform soul/carl soul/xan], DreamLayers.all(dreams)
    assert_equal "soul carl", DreamLayers.label("soul/carl")
    assert_equal "step building-sop · begin", DreamLayers.label("step/building-sop/begin")
  end
end
