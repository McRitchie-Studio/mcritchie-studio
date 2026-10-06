# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [unit] Build Clips: an alt video is the next number of its source, its swaps
# a snapshot of the cast card at that moment, with one clip per chunk; a later
# edit of the card changes neither its swaps nor its prompts. Clips hold
# numbered versions with exactly one primary. Wholly synthetic people.
class AltVideoTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @athlete = RecastVideo.athlete!
    @home, @away = @athlete.appearances.live.order(:descriptor).to_a.partition { |l| l.descriptor == "Home Blue" }.map(&:first)
  end

  def recast!(look)
    performer = @video.video_performers.find_by!(ordinal: 1)
    performer.update!(recast_person_slug: @athlete.slug, recast_appearance_slug: look&.slug, recast_keep: false)
    @video.video_performers.reset
  end

  def chunk(ordinal) = @video.reload.video_chunks.find { |c| c.ordinal == ordinal }

  test "an alt video snapshots the swaps and makes one clip per chunk, in order" do
    recast!(@home)
    alt = AltVideo.build_from!(@video)

    assert_equal [1, "test-artist-a-tiled-demo-alt-1", "Alt video 1"], [alt.number, alt.slug, alt.name]
    assert_equal [{ "performer_ordinal" => 1, "person_slug" => @athlete.slug, "appearance_slug" => @home.slug,
                    "person_name" => "Test Athlete Alpha", "look_name" => "Home Blue" }], alt.swaps
    assert_equal "Test Athlete Alpha > Home Blue", alt.swaps_summary
    assert_equal [[1, 0, 25_000], [2, 20_000, 45_000], [3, 40_000, 65_000], [4, 60_000, 72_000]],
                 alt.clips.map { |c| [c.chunk_ordinal, c.start_ms, c.end_ms] }
    assert_equal [0, 4], alt.progress
  end

  test "a person kept as filmed, or never swapped, is not in the snapshot" do
    recast!(@home)
    @video.video_performers.find_by!(ordinal: 1).update!(recast_keep: true)

    alt = AltVideo.build_from!(@video)
    assert_empty alt.swaps
    assert_equal "nobody swapped", alt.swaps_summary
  end

  test "each press numbers the next alt video of that source, each with its own swaps" do
    recast!(@home)
    first = AltVideo.build_from!(@video)
    recast!(@away)
    second = AltVideo.build_from!(@video)

    assert_equal [1, 2], [first.number, second.number]
    assert_equal ["Home Blue", "Away White"], [first, second].map { |a| a.reload.swap_set[1].look_name }
  end

  test "a later edit of the cast card changes neither the swaps nor the prompts" do
    recast!(@home)
    alt = AltVideo.build_from!(@video)
    before = MusicVideos::ClipPrompts.for(chunk(1), swaps: alt.swap_set)
    assert_includes before, "with Test Athlete Alpha, the football player"
    assert_includes before, "Home Blue model"

    recast!(@away)
    @video.video_performers.find_by!(ordinal: 1).update!(recast_keep: true)
    alt.reload

    assert_equal "Test Athlete Alpha > Home Blue", alt.swaps_summary
    assert_equal before, MusicVideos::ClipPrompts.for(chunk(1), swaps: alt.swap_set), "the snapshot, not the card"
    assert_includes MusicVideos::ClipPrompts.for(chunk(1)), "{athlete}", "the card itself now keeps person 1"
  end

  test "the snapshot is never rewritten" do
    alt = AltVideo.build_from!(@video)
    alt.swaps = [{ "performer_ordinal" => 1, "person_slug" => @athlete.slug, "appearance_slug" => nil,
                   "person_name" => "Test Athlete Alpha", "look_name" => nil }]

    assert_not alt.valid?
    assert_match(/snapshot/, alt.errors[:swaps].sole)
  end

  test "a malformed snapshot or a wrong slug is refused" do
    alt = @video.alt_videos.build(number: 1, slug: "wrong", swaps: [{ "performer_ordinal" => 1 }])

    assert_not alt.valid?
    assert alt.errors.key?(:slug)
    assert alt.errors.key?(:swaps)
  end

  test "Build Clips is refused until the cast is confirmed and the video is tiled" do
    @video.video_chunks.destroy_all
    error = assert_raises(AltVideo::NotReady) { AltVideo.build_from!(@video.reload) }
    assert_equal "the video is not tiled into chunks yet", error.message

    @video.update!(stage: "digested")
    assert_equal "confirm the cast first", @video.build_clips_blocker
    assert_equal 0, AltVideo.count
  end

  test "the swapped people in a window are whose sheets the clip offers" do
    recast!(@home)
    alt = AltVideo.build_from!(@video)

    assert_equal [1], chunk(1).swapped_present(alt.swap_set).map(&:performer_ordinal)
    assert_empty chunk(1).swapped_present(MusicVideos::SwapSet.new([]))
    assert_equal [@home.slug], alt.swap_set.appearance_slugs
  end

  test "a new version is primary, older ones are kept, and any can be put back in front" do
    alt = AltVideo.build_from!(@video)
    clip = alt.clips.second
    one = TiledVideo.version!(clip, number: 1)
    two = TiledVideo.version!(clip.reload, number: 2, at: 1.second.from_now)

    assert_equal two, clip.reload.primary_version
    one.make_primary!
    assert_equal one, clip.reload.primary_version
    assert_equal [true, false], clip.versions.map(&:primary?)
    two.make_primary!
    assert_equal [false, true], clip.reload.versions.map(&:primary?), "exactly one primary at a time"
    assert_equal [1, 4], alt.reload.progress
  end

  test "a version's object must sit under its alt video's clips folder" do
    alt = AltVideo.build_from!(@video)
    version = alt.clips.first.versions.build(number: 1, byte_size: 1, primary_since: Time.current,
                                             object_key: "music_videos/test_artist_a/tiled_demo/generated/x.mp4")

    assert_not version.valid?
    assert_match(%r{alt_videos/01/clips/tiled_demo_alt_01_chunk_01_0000_0025_v01\.mp4}, version.errors[:object_key].sole)
  end

  test "a clip keeps its window after a re-tile, and no longer finds a chunk there" do
    alt = AltVideo.build_from!(@video)
    MusicVideos::ReplaceClips.new(@video, TiledVideo.chunk_rows(@video, chunk_ms: 15_000, overlap_ms: 5_000),
                                  kind: "chunk", chunk_ms: 15_000, chunk_overlap_ms: 5_000).call

    clip = alt.clips.second
    assert_equal [20_000, 45_000], [clip.start_ms, clip.end_ms]
    assert_nil clip.chunk_in(@video.reload.video_chunks.to_a)
  end
end
