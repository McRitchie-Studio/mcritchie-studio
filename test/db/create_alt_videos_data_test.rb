# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s
require Rails.root.join("db/migrate/20261006190000_create_alt_videos.rb").to_s

# [integration] The data step of CreateAltVideos: piece 3's takes and piece 4's
# stitches move onto an "alt video 1" per source that has any, with the
# source's swaps as its snapshot; every take becomes a version (same number,
# same object, same primary), every stitch points at it, chunk flags ride
# along, nothing is deleted, and a second run changes nothing.
class CreateAltVideosDataTest < ActiveSupport::TestCase
  Take = CreateAltVideos::Take

  setup do
    # Before the migration video_stitches had no alt_video_slug. Postgres DDL is
    # transactional, so the test's rollback puts the NOT NULL back.
    ActiveRecord::Base.connection.change_column_null(:video_stitches, :alt_video_slug, true)
    @video = TiledVideo.seed!
    @athlete = RecastVideo.athlete!
    @look = @athlete.appearances.live.find_by!(descriptor: "Home Blue")
    @video.video_performers.find_by!(ordinal: 1)
          .update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @look.slug, recast_keep: false)
    @chunks = @video.video_chunks.to_a
    # Piece 3's rows, as StoreTake wrote them: chunk 2 has take 1 and take 2,
    # with take 1 put back in front; chunk 3 is flagged.
    take!(@chunks.second, 1, current_since: 1.minute.ago)
    take!(@chunks.second, 2, current_since: 2.minutes.ago)
    take!(@chunks.first, 1, current_since: 3.minutes.ago)
    @chunks.third.update_columns(regenerate_requested_at: Time.current, regenerate_note: "the jersey flickers")
    # Piece 4's stitch, as RequestStitch wrote it before alt videos.
    VideoStitch.insert_all!([{ music_video_slug: @video.slug, alt_video_slug: nil, number: 1, state: "failed",
                               object_key: MusicVideos::ObjectKeys.stitched(source_key: @video.source_object_key, number: 1),
                               takes: [{ "ordinal" => 1, "start_ms" => 0, "end_ms" => 25_000, "take" => 1 }],
                               failure_reason: "the Mac slept", created_at: Time.current, updated_at: Time.current }])
  end

  def take!(chunk, number, current_since:)
    Take.create!(music_video_slug: @video.slug, chunk_ordinal: chunk.ordinal, start_ms: chunk.start_ms, end_ms: chunk.end_ms,
                 number:, byte_size: 1_000 + number, original_filename: "take_#{number}.mp4", current_since:,
                 object_key: MusicVideos::ObjectKeys.take(source_key: @video.source_object_key, ordinal: chunk.ordinal,
                                                          start_ms: chunk.start_ms, end_ms: chunk.end_ms, number:))
  end

  test "a source with no take and no stitch gets no alt video" do
    Take.delete_all
    VideoStitch.delete_all
    CreateAltVideos.move_takes_and_stitches!
    assert_equal 0, AltVideo.count
  end

  test "takes and stitches move onto alt video 1 without loss, and a second run changes nothing" do
    2.times { CreateAltVideos.move_takes_and_stitches! }

    alt = @video.reload.alt_videos.sole
    assert_equal ["test-artist-a-tiled-demo-alt-1", 1], [alt.slug, alt.number]
    assert_equal "Test Athlete Alpha > Home Blue", alt.swaps_summary
    assert_equal [1, 2, 3, 4], alt.clips.map(&:chunk_ordinal)

    two = alt.clips.second
    assert_equal [1, 2], two.versions.map(&:number)
    assert_equal 1, two.primary_version.number, "take 1 was in front, so version 1 is primary"
    assert_equal Take.where(chunk_ordinal: 2).order(:number).pluck(:object_key, :byte_size, :original_filename),
                 two.versions.map { |v| [v.object_key, v.byte_size, v.original_filename] }
    assert_equal 3, AltVideoClipVersion.count
    assert_equal 3, Take.count, "the old rows are kept"

    assert alt.clips.third.regenerate_requested?
    assert_equal "the jersey flickers", alt.clips.third.regenerate_note

    stitch = VideoStitch.sole
    assert_equal [alt.slug, "failed", "the Mac slept"], stitch.attributes.values_at("alt_video_slug", "state", "failure_reason")
    assert_equal two.alt_video.clips.first.versions.sole.object_key, stitch.as_request["takes"].sole["object_key"],
                 "the stitch resolves its take to the moved version's object"
    assert stitch.valid?, "a moved stitch keeps its old object key and stays valid"
  end
end
