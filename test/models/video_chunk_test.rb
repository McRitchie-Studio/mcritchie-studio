# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] A chunk is a VideoClip of kind "chunk": no seam, on the 20 s stride,
# up to 25 s (the last one shorter), numbered apart from the seam candidates,
# with its own R2 key. The candidate rules are untouched by it.
class VideoChunkTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @chunks = @video.video_chunks.to_a
    @candidate = @video.clip_candidates.sole
  end

  test "the seeded tiling is four valid chunks with no seam, the last one short" do
    assert_equal [[1, 0, 25_000], [2, 20_000, 45_000], [3, 40_000, 65_000], [4, 60_000, 72_000]],
                 @chunks.map { |c| [c.ordinal, c.start_ms, c.end_ms] }
    @chunks.each do |chunk|
      assert chunk.valid?, chunk.errors.full_messages.to_sentence
      assert chunk.chunk?
      assert_nil chunk.seam
      assert_nil chunk.seam_ms
    end
    assert_equal 12_000, @chunks.last.duration_ms
    assert_equal "Chunk 4", @chunks.last.name
    assert_equal @video.duration_ms, @chunks.last.end_ms
  end

  test "a chunk and a candidate share an ordinal; two of one kind do not" do
    assert_equal 1, @candidate.ordinal
    assert_equal 1, @chunks.first.ordinal
    assert @candidate.valid?, @candidate.errors.full_messages.to_sentence

    twin = @chunks.first.dup
    assert_not twin.valid?
    assert twin.errors.key?(:ordinal)
    assert_raises(ActiveRecord::RecordNotUnique) { twin.save!(validate: false) }
  end

  test "the two kinds list apart, each in its own order" do
    assert_equal %w[candidate chunk chunk chunk chunk], @video.video_clips.map(&:kind)
    assert_equal [1, 2, 3, 4], @video.video_chunks.map(&:ordinal)
    assert_equal [@candidate], @video.clip_candidates.to_a
    assert_equal @chunks, VideoClip.chunks.where(music_video_slug: @video.slug).order(:ordinal).to_a
    assert_equal [@candidate], VideoClip.candidates.where(music_video_slug: @video.slug).to_a
  end

  test "a chunk may not carry a seam" do
    chunk = @chunks.first
    chunk.seam = "section_change"
    chunk.seam_ms = 12_000
    assert_not chunk.valid?
    assert_match "a chunk has no seam", chunk.errors[:seam].first
    assert chunk.errors.key?(:seam_ms)
  end

  test "a candidate still needs a seam, 24 to 26 seconds and its clip key" do
    @candidate.seam = nil
    assert_not @candidate.valid?
    assert @candidate.errors.key?(:seam)

    @candidate.reload.end_ms = @candidate.start_ms + 12_000
    assert_not @candidate.valid?
    assert_match "clips run 24 to 26 s", @candidate.errors[:end_ms].first

    @candidate.reload.object_key = @chunks.first.object_key
    assert_not @candidate.valid?
    assert_match "tiled_demo_clip_01_section_change_solo_plus_background_0030_0055.mp4", @candidate.errors[:object_key].first
  end

  test "a chunk starts where its ordinal puts it on the 20 s stride" do
    chunk = @chunks.second
    chunk.start_ms = 21_000
    assert_not chunk.valid?
    assert_match "must be 20000 for chunk 2", chunk.errors[:start_ms].first
  end

  test "a chunk runs up to 25 seconds, never more and never empty" do
    chunk = @chunks.first
    chunk.end_ms = 25_001
    assert_not chunk.valid?
    assert_match "chunks run up to 25 s", chunk.errors[:end_ms].first

    chunk.end_ms = 0
    assert_not chunk.valid?
    assert_match "chunks run up to 25 s", chunk.errors[:end_ms].first
  end

  test "a chunk may not run past the end of the video" do
    chunk = @chunks.last
    chunk.end_ms = 72_001
    assert_not chunk.valid?
    assert_includes chunk.errors[:end_ms], "is past the end of the video"
  end

  test "a chunk's key sits in the chunks folder and names its window" do
    chunk = @chunks.last
    assert_equal "music_videos/test_artist_a/tiled_demo/chunks/tiled_demo_chunk_04_0100_0112.mp4", chunk.object_key
    chunk.object_key = chunk.object_key.sub("/chunks/", "/clips/")
    assert_not chunk.valid?
    assert_match "tiled_demo_chunk_04_0100_0112.mp4", chunk.errors[:object_key].first
  end

  test "people must be the video's own performers" do
    chunk = @chunks.first
    chunk.performer_ordinals = [1, 9]
    assert_not chunk.valid?
    assert_match "no such person: 9", chunk.errors[:performer_ordinals].first
  end

  test "an unknown kind is refused" do
    @candidate.kind = "tile"
    assert_not @candidate.valid?
    assert @candidate.errors.key?(:kind)
  end

  test "an approved chunk never makes the video clips ready" do
    @chunks.first.update!(status: "approved")
    @video.sync_clip_stage!
    assert_equal "cast_confirmed", @video.reload.stage

    @candidate.update!(status: "approved")
    @video.sync_clip_stage!
    assert_equal "clips_ready", @video.reload.stage
  end

  test "bin/digest-video accepts exactly the kinds the model does" do
    require Rails.root.join("bin/lib/digest_video").to_s
    assert_equal MusicVideo::KINDS, DigestVideo::KINDS
  end

  test "a video is a music video unless it is typed cinematic" do
    assert_equal "cinematic", @video.kind
    assert_equal "Cinematic video", @video.kind_label
    assert_equal "music_video", MusicVideo.new.kind
    assert_equal "Music video", MusicVideo.new.kind_label
    @video.kind = "documentary"
    assert_not @video.valid?
    assert @video.errors.key?(:kind)
  end
end
