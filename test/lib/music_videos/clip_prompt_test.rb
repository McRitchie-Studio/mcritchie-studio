# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/clip_prompt"

# [unit] The Higgsfield swap prompt: the proven prompt with its blanks, the
# athlete and look a recast fills in, and the wording for a cinematic video.
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

  def test_athlete_stays_a_placeholder_until_the_target_is_recast
    assert_equal 1, P.fill(target: "desk").scan(P::ATHLETE).size
    assert_equal 1, P.fill(target: "desk", look: "Home Blue").scan(P::ATHLETE).size
    refute_includes P.fill(target: "desk", look: "Home Blue"), "Home Blue"
  end

  def test_a_recast_names_the_athlete_and_mentions_the_look
    prompt = P.fill(target: "long-haired man", athlete: "Test Athlete Alpha", look: "Home Blue")

    assert prompt.start_with?("Replace the long-haired man in this music video with Test Athlete Alpha, the football player.")
    assert_includes prompt, "no helmet (like the Home Blue model provided)."
    refute_includes prompt, "{"
  end

  def test_an_athlete_with_no_look_is_named_alone
    prompt = P.fill(target: "desk", athlete: "Test Athlete Alpha")

    assert_includes prompt, "with Test Athlete Alpha, the football player."
    assert_includes prompt, "(like the model provided)"
  end

  def test_names_are_flattened_so_they_cannot_open_a_blank
    prompt = P.fill(target: "desk", athlete: " Test\n{athlete} Alpha ", look: "Home {video} Blue")

    assert_includes prompt, "with Test athlete Alpha, the football player."
    assert_includes prompt, "like the Home video Blue model provided"
    refute_includes prompt, "{"
  end

  def test_a_cinematic_video_is_never_called_a_music_video
    prompt = P.fill(target: "man in the red jacket", athlete: "Test Athlete Alpha", look: "Away White", video_kind: "cinematic")

    assert prompt.start_with?("Replace the man in the red jacket in this video with Test Athlete Alpha, the football player.")
    assert prompt.end_with?("Please give the video the same cinematic lighting as the original video.")
    refute_includes prompt, "music video"
    refute_includes P.fill(target: nil, video_kind: "cinematic"), "music video"
    assert P.fill(target: nil, video_kind: "cinematic").start_with?("Replace the main person on screen in this video with {athlete}")
    refute_includes P.fill(target: nil, video_kind: "cinematic"), "singer"
  end

  def test_an_unknown_kind_reads_as_a_music_video
    assert_equal P.fill(target: "desk"), P.fill(target: "desk", video_kind: "short")
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
