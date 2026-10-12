# frozen_string_literal: true

require "test_helper"

# [unit] Which chunks owe lettered reference frames: people on screen in the
# window (the cast's sightings) and no frames. Unsaved rows, no queries.
# Wholly synthetic people.
class MusicVideosMissingReferencesTest < ActiveSupport::TestCase
  MissingReferences = MusicVideos::MissingReferences

  def chunk(ordinal, start_s, end_s, frames: [])
    VideoClip.new(kind: "chunk", ordinal:, start_ms: start_s * 1000, end_ms: end_s * 1000, reference_frames: frames)
  end

  def performer(ordinal, *seconds)
    VideoPerformer.new(ordinal:, label: "person #{ordinal}",
                       sightings: seconds.map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } })
  end

  FRAME = [{ "object_key" => "k", "t_ms" => 5000, "letters" => %w[A] }].freeze

  setup do
    @framed = chunk(1, 0, 25, frames: FRAME)   # people, frames: owes nothing
    @bare = chunk(2, 20, 45)                    # people, no frames: missing
    @credits = chunk(3, 40, 65)                 # no sighting in the window: owes nothing
    @performers = [performer(1, 3, 12, 21), performer(2, 30, 36)]
  end

  test "a chunk with people and no frames is missing; one with frames or with nobody on screen is not" do
    assert_equal [2], MissingReferences.chunks([@credits, @bare, @framed], @performers).map(&:ordinal)
  end

  test "a sighting just outside the window still counts, as ClipCast reads it" do
    near = performer(3, 66) # 1 s after chunk 3 ends, inside ClipCast::TOLERANCE_MS
    assert_equal [2, 3], MissingReferences.chunks([@bare, @credits], @performers + [near]).map(&:ordinal)
  end

  test "no cast yet means nothing is missing, and a re-tiled nil chunk is skipped" do
    assert_empty MissingReferences.chunks([@bare, nil], [])
  end

  test "the warning counts the missing chunks out of the total, and says nothing when none are missing" do
    assert_equal "3 of 13 clips have no A/B/C frames yet. Higgsfield works best with them: " \
                 "ask the agent to run lettered references.", MissingReferences.warning(3, 13)
    assert_match(/\A1 of 1 clip has no A\/B\/C frames yet\./, MissingReferences.warning(1, 1))
    assert_nil MissingReferences.warning(0, 13)
  end
end
