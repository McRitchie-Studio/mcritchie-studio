# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/clip_prompt"

# [unit] The Higgsfield swap prompt: the proven prompt with its three blanks.
class MusicVideosClipPromptTest < Minitest::Test
  P = MusicVideos::ClipPrompt

  def test_fills_the_target_and_who_stays
    prompt = P.fill(target: "man in the leopard-print shirt", others: ["checkered glasses", "long-haired man"])

    assert prompt.start_with?("Replace the man in the leopard-print shirt in this music video with {athlete}, the football player.")
    assert_includes prompt, "mouthing all the mouth movements of the man in the leopard-print shirt."
    assert_includes prompt, "Please keep the person in the checkered glasses scenes and the long-haired man the same."
    refute_includes prompt, "{target_description}"
    refute_includes prompt, "{keep_others}"
  end

  def test_keeps_the_proven_prompt_body
    prompt = P.fill(target: nil)

    assert_equal "Replace the singer in this music video with {athlete}, the football player. The player should " \
                 "have his normal hair, athletic build and be in uniform, full pads with no helmet (like the model " \
                 "provided). He should also be mouthing all the mouth movements of the singer. Give him a diamond " \
                 "encrusted watch, necklace, rings, and some designer sunglasses. Please keep everyone else the " \
                 "same. Please give the video the same cinematic lighting as the music video.", prompt
  end

  def test_athlete_stays_a_placeholder_for_pipeline_four
    assert_equal 1, P.fill(target: "desk").scan(P::ATHLETE).size
  end

  def test_describe_reads_labels_as_people_or_scenes
    assert_equal "the long-haired man", P.describe("long-haired man")
    assert_equal "the person in the desk scenes", P.describe("desk")
    assert_equal "the supporting woman", P.describe("supporting woman (with Person 6)")
    assert_equal "the man at the desk", P.describe("the man at the desk")
    assert_equal "the singer", P.describe("  ")
  end

  def test_three_others_read_as_a_list_and_duplicates_collapse
    prompt = P.fill(target: "desk", others: ["couch", "armchair", "couch", "long-haired man"])
    assert_includes prompt, "keep the person in the couch scenes, the person in the armchair scenes and the long-haired man the same"
  end

  def test_background_people_are_everyone_else
    prompt = P.fill(target: "desk", others: ["long-haired man"], background: true)
    assert_includes prompt, "Please keep the long-haired man and everyone else the same."
  end
end
