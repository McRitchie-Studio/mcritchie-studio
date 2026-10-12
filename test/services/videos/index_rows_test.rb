# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [unit] The /videos row summary: people carded and swapped, the A/B/C
# frame state, each alt video's chip, primary progress and TikTok drafts sent,
# newest first, in a fixed number of queries. Wholly synthetic people.
class VideosIndexRowsTest < ActiveSupport::TestCase
  IndexRows = Videos::IndexRows

  setup do
    @tiled = TiledVideo.seed!       # 2 carded, none swapped, 4 chunks owing frames, no alt video
    @lettered = LetteredVideo.seed! # 3 carded, 2 swapped, chunk 3 framed, alt video 1
    @bare = Video.create!(slug: "test-artist-c-bare-demo", kind: "music_video", platform: "youtube",
                               source_url: "https://www.youtube.com/watch?v=bare-demo", source_id: "bare-demo",
                               title: "Test Artist C - Bare Demo",
                               source_object_key: "music_videos/test_artist_c/bare_demo/source/bare.mp4")
    @tiled.update_columns(created_at: 3.days.ago)
    @lettered.update_columns(created_at: 2.days.ago)
    @bare.update_columns(created_at: 1.day.ago)
  end

  def row(video) = IndexRows.call.find { |r| r.video.slug == video.slug }

  def count_queries
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "rows are newest first" do
    assert_equal [@bare.slug, @lettered.slug, @tiled.slug], IndexRows.call.map { |r| r.video.slug }
  end

  test "people count the cast cards and the live swaps" do
    assert_equal [2, 0], row(@tiled).then { |r| [r.carded, r.swapped] }
    assert_equal [3, 2], row(@lettered).then { |r| [r.carded, r.swapped] }
    assert_equal [0, 0], row(@bare).then { |r| [r.carded, r.swapped] }
  end

  test "frames: every chunk with people and no frames is missing; an untiled video has no clips to owe" do
    tiled = row(@tiled)
    assert_equal :missing, tiled.frames_state
    assert_equal tiled.chunks, tiled.frames_missing

    lettered = row(@lettered)
    assert_equal lettered.chunks - 1, lettered.frames_missing, "chunk 3 carries its frames"

    # The row reads only whether a chunk has frames, so the other chunks borrow chunk 3's.
    framed = @lettered.video_chunks.find_by!(ordinal: 3).reference_frames
    @lettered.video_chunks.each { |c| c.update_columns(reference_frames: framed) }
    assert_equal :complete, row(@lettered).frames_state
    assert_equal :untiled, row(@bare).frames_state
  end

  test "an alt video chip names the swapped surnames, its primary progress and the drafts TikTok delivered" do
    alt = @lettered.alt_videos.sole
    clips = alt.clips.to_a
    TiledVideo.version!(clips.first, number: 1)
    TiledVideo.version!(clips.first, number: 2)
    TiledVideo.version!(clips.second, number: 1)
    TiktokDraft.create!(clip: clips.first, version_number: 2, version_object_key: "k2", caption: "c", state: "delivered")
    TiktokDraft.create!(clip: clips.first, version_number: 1, version_object_key: "k1", caption: "c", state: "failed")

    chip = row(@lettered).alts.sole
    assert_equal "Alt 1 · Epsilon, Zeta", chip.label
    assert_equal [2, clips.size, 1], [chip.with_primary, chip.clips, chip.drafts_sent]
    assert_empty row(@tiled).alts
  end

  test "a chip trails off after three surnames and says when nobody is swapped" do
    names = ["Brock Purdy", "George Kittle", "Christian McCaffrey", "Odell Beckham Jr."]
    long = IndexRows::Alt.new(alt_video: AltVideo.new(number: 1), surnames: names.map { IndexRows.surname(_1) },
                              swap_count: 4, with_primary: 0, clips: 0, drafts_sent: 0)
    assert_equal "Alt 1 · Purdy, Kittle, McCaffrey…", long.label
    assert_equal "Beckham", IndexRows.surname("Odell Beckham Jr.")
    none = IndexRows::Alt.new(alt_video: AltVideo.new(number: 2), surnames: [], swap_count: 0, with_primary: 0, clips: 0,
                              drafts_sent: 0)
    assert_equal "Alt 2 · nobody swapped", none.label
  end

  test "the page loads in a fixed number of queries, however many videos and alt videos" do
    assert_equal IndexRows::QUERIES, count_queries { IndexRows.call.to_a }

    AltVideo.build_from!(@lettered.reload)
    AltVideo.build_from!(@tiled.reload)
    assert_equal IndexRows::QUERIES, count_queries { IndexRows.call.to_a }
  end

  test "no video at all is one query" do
    assert_equal 1, count_queries { assert_empty IndexRows.call(Video.where(slug: "no-such-video")) }
  end
end
