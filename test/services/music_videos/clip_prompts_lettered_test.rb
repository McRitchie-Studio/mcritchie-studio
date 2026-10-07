require "test_helper"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [unit] Prompt v2 as the hub builds it (piece 16): letters are fixed per
# source (Person N is the Nth letter in every clip and alt video), the prompt
# lists every swapped person seen in the window, leads and background, with
# the look's jersey number read live, sheets numbered in the card's order; a
# window that swaps nobody keeps the proven single-target prompt. Wholly
# synthetic people.
class MusicVideosClipPromptsLetteredTest < ActiveSupport::TestCase
  setup do
    @video = LetteredVideo.seed!
    @alt = @video.alt_videos.first
    @swaps = @alt.swap_set
  end

  def chunk(ordinal) = @video.video_chunks.reload.find { |c| c.ordinal == ordinal }

  def prompt(ordinal) = MusicVideos::ClipPrompts.for(chunk(ordinal), swaps: @swaps)

  test "letters are fixed per source: Person N is the Nth letter everywhere" do
    assert_equal %w[A B C], @video.video_performers.map(&:letter)
    rows = MusicVideos::ClipPrompts.lettered(chunk(3), swaps: @swaps)
    assert_equal %w[B C], rows.map(&:letter)
    assert_equal %w[B], MusicVideos::ClipPrompts.lettered(chunk(4), swaps: @swaps).map(&:letter),
                 "Person B is B in the next chunk too; C has left"
  end

  test "the prompt lists every swapped person in the window, lead and background, by letter and number" do
    text = prompt(3)

    assert text.start_with?("This clip is from a video. People are marked A, B, C... in the reference frames.")
    assert_includes text, "- Person B (lead) -> #4 Test Passer Epsilon, Home White (character sheet 1)"
    assert_includes text, "- Person C (background) -> #88 Test Receiver Zeta, Home White (character sheet 2)"
    assert_includes text, "#4 Test Passer Epsilon should also be mouthing all the mouth movements of Person B."
    assert_not_includes text, "mouth movements of Person C", "a background swap does not lip-sync"
    assert_not_includes text, "Person A", "Person A is kept and stays under 'everyone else'"
    assert_includes text, "Keep everyone else exactly as they are."
    assert text.end_with?("Please give the video the same cinematic lighting as the original video.")
  end

  test "sheet numbers follow the card's download order" do
    rows = MusicVideos::ClipPrompts.lettered(chunk(3), swaps: @swaps)
    assert_equal chunk(3).swapped_present(@swaps).map(&:performer_ordinal), rows.map { |r| MusicVideos::PersonLetters.ordinal(r.letter) }
    assert_equal [1, 2], rows.map(&:sheet)
  end

  test "a look without a jersey number falls back to the name; setting one later fixes the prompt" do
    look = Appearance.find_by!(slug: @swaps[2].appearance_slug)
    look.update!(jersey_number: nil)
    assert_includes prompt(3), "- Person B (lead) -> Test Passer Epsilon, Home White (character sheet 1)"

    look.update!(jersey_number: 7)
    assert_includes prompt(3), "- Person B (lead) -> #7 Test Passer Epsilon, Home White"
  end

  test "a chunk without lettered frames does not point at them" do
    text = prompt(2)
    assert text.start_with?("This clip is from a video.\n")
    assert_not_includes text, "reference frames"
  end

  test "a window that swaps nobody keeps the single-target prompt" do
    assert prompt(1).start_with?("Replace the "), "chunk 1 shows only Person A, who is kept"
    assert_includes prompt(1), "{athlete}"
  end

  test "a jersey change refills the stored prompts of every source that casts the look" do
    look = Appearance.find_by!(slug: @swaps[3].appearance_slug)
    look.update!(jersey_number: 11)

    assert_operator MusicVideos::ClipPrompts.refresh_casting!(look), :>, 0
    assert_includes chunk(3).prompt, "#11 Test Receiver Zeta"
  end
end
