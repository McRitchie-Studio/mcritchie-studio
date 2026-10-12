# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [integration] GET /music_videos: admin only, every source video newest first
# with its people, A/B/C frames and alt video chips, the empty state, the back
# link on the source page, and a page whose query count does not grow with the
# videos on it. Wholly synthetic people.
class MusicVideosIndexTest < ActionDispatch::IntegrationTest
  def seed_two
    tiled = TiledVideo.seed!
    lettered = LetteredVideo.seed!
    tiled.update_columns(created_at: 2.days.ago)
    lettered.update_columns(created_at: 1.day.ago)
    [tiled, lettered]
  end

  def page_queries
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get music_videos_path }
    assert_response :success
    count
  end

  test "visitors are sent to log in and non-admins are refused" do
    get music_videos_path
    assert_redirected_to "/login"

    log_in_as users(:viewer)
    get music_videos_path
    assert_redirected_to root_path
  end

  test "with no source video the page says how to digest one" do
    log_in_as users(:alex)
    get music_videos_path

    assert_response :success
    assert_select "[data-test='music-videos-empty']", "No source videos yet. Digest one with bin/digest-video."
    assert_select "[data-test='music-video-row']", 0
  end

  test "an admin sees every source video newest first, with people, frames and alt videos" do
    tiled, lettered = seed_two
    alt = lettered.alt_videos.sole
    TiledVideo.version!(alt.clips.first, number: 1)
    log_in_as users(:alex)
    get music_videos_path

    assert_response :success
    assert_equal [lettered.slug, tiled.slug], css_select("[data-test='music-video-row']").map { |r| r["data-slug"] }

    assert_select "[data-test='music-video-row'][data-slug='#{lettered.slug}']" do
      assert_select "[data-test='music-video-link'][href='#{music_video_path(lettered)}']", lettered.title
      assert_select "[data-test='music-video-kind']", "Cinematic video"
      assert_select "[data-test='music-video-length']", "1:12"
      assert_select "[data-test='music-video-stage']", "Cast confirmed"
      assert_select "a[href=?]", lettered.source_url, "Watch source"
      assert_select "[data-test='music-video-people']", "3 carded · 2 swapped"
      assert_select "[data-test='music-video-frames']", /\A\d+ clips? missing A\/B\/C frames\z/
      assert_select "[data-test='music-video-alt-link'][href='#{music_video_alt_video_path(lettered, alt)}']",
                    "Alt 1 · Epsilon, Zeta"
      assert_select "[data-test='music-video-alt-progress']", "1/#{alt.clips.size} clips"
      assert_select "[data-test='music-video-alt-drafts']", "0 TikTok drafts sent"
    end
    assert_select "[data-test='music-video-row'][data-slug='#{tiled.slug}']" do
      assert_select "[data-test='music-video-people']", "2 carded · 0 swapped"
      assert_select "[data-test='music-video-no-alts']", "None yet"
    end
  end

  test "a video whose clips all carry frames says so" do
    _, lettered = seed_two
    framed = lettered.video_chunks.find_by!(ordinal: 3).reference_frames
    lettered.video_chunks.each { |c| c.update_columns(reference_frames: framed) }
    log_in_as users(:alex)
    get music_videos_path

    assert_select "[data-test='music-video-row'][data-slug='#{lettered.slug}'] [data-test='music-video-frames']",
                  "All clips have A/B/C frames"
  end

  test "the page costs the same queries with one video as with three, each with alt videos" do
    log_in_as users(:alex)
    AltVideo.build_from!(TiledVideo.seed!)
    one = page_queries

    lettered = LetteredVideo.seed!
    AltVideo.build_from!(lettered.reload)
    TiledVideo.video!(slug: "test-artist-a-second-demo", source_id: "second-demo", title: "Test Artist A - Second Demo",
                      source: "music_videos/test_artist_a/second_demo/source/second.mp4")
    assert_equal [3, 3], [MusicVideo.count, AltVideo.count]
    assert_equal one, page_queries
  end

  test "a row with a cast still shows it as a signed thumbnail" do
    tiled, = seed_two
    key = "music_videos/test_artist_a/tiled_demo/stills/person_01_0003.jpg"
    tiled.video_performers.find_by!(ordinal: 1).update!(still_object_keys: [key])
    log_in_as users(:alex)
    get music_videos_path

    assert_select "[data-test='music-video-row'][data-slug='#{tiled.slug}'] [data-test='music-video-still']" do |el|
      assert_includes el.sole["style"], key
      assert_includes el.sole["style"], "X-Amz-Signature"
    end
  end

  test "the source page links back to all videos" do
    tiled, = seed_two
    log_in_as users(:alex)
    get music_video_path(tiled)

    assert_select "[data-test='all-videos-link'][href='#{music_videos_path}']", /All videos/
  end
end
