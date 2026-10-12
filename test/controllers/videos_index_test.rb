# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [integration] GET /videos: admin only, every source video newest first
# with its people, A/B/C frames and alt video chips, the empty state, the back
# link on the source page, and a page whose query count does not grow with the
# videos on it. Wholly synthetic people.
class VideosIndexTest < ActionDispatch::IntegrationTest
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
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get videos_path }
    assert_response :success
    count
  end

  test "visitors are sent to log in and non-admins are refused" do
    get videos_path
    assert_redirected_to "/login"

    log_in_as users(:viewer)
    get videos_path
    assert_redirected_to root_path
  end

  test "with no source video the page says how to digest one" do
    log_in_as users(:alex)
    get videos_path

    assert_response :success
    assert_select "[data-test='videos-empty']", "No videos yet. Digest one with bin/digest-video."
    assert_select "[data-test='video-row']", 0
  end

  test "an admin sees every source video newest first, with people, frames and alt videos" do
    tiled, lettered = seed_two
    alt = lettered.alt_videos.sole
    TiledVideo.version!(alt.clips.first, number: 1)
    log_in_as users(:alex)
    get videos_path

    assert_response :success
    assert_equal [lettered.slug, tiled.slug], css_select("[data-test='video-row']").map { |r| r["data-slug"] }

    assert_select "[data-test='video-row'][data-slug='#{lettered.slug}']" do
      assert_select "[data-test='video-link'][href='#{video_path(lettered)}']", lettered.title
      assert_select "[data-test='video-row-kind']", "Cinematic"
      assert_select "[data-test='video-length']", "1:12"
      assert_select "[data-test='video-row-stage']", "Cast confirmed"
      assert_select "a[href=?]", lettered.source_url, "Watch source"
      assert_select "[data-test='video-people']", "3 carded · 2 swapped"
      assert_select "[data-test='video-frames']", /\A\d+ clips? missing A\/B\/C frames\z/
      assert_select "[data-test='video-alt-link'][href='#{video_alt_video_path(lettered, alt)}']",
                    "Alt 1 · Epsilon, Zeta"
      assert_select "[data-test='video-alt-progress']", "1/#{alt.clips.size} clips"
      assert_select "[data-test='video-alt-drafts']", 0, "no zero drafts count"
    end
    assert_select "[data-test='video-row'][data-slug='#{tiled.slug}']" do
      assert_select "[data-test='video-people']", "2 carded · 0 swapped"
      assert_select "[data-test='video-no-alts']", "None yet"
    end
  end

  test "a video whose clips all carry frames says so" do
    _, lettered = seed_two
    framed = lettered.video_chunks.find_by!(ordinal: 3).reference_frames
    lettered.video_chunks.each { |c| c.update_columns(reference_frames: framed) }
    log_in_as users(:alex)
    get videos_path

    assert_select "[data-test='video-row'][data-slug='#{lettered.slug}'] [data-test='video-frames']",
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
    assert_equal [3, 3], [Video.count, AltVideo.count]
    assert_equal one, page_queries
  end

  test "a chip counts the drafts TikTok delivered on the progress line, and only when there are some" do
    _, lettered = seed_two
    clip = lettered.alt_videos.sole.clips.first
    TiktokDraft.create!(clip:, version_number: 1, version_object_key: "k1", caption: "c", state: TiktokDraft::DELIVERED)
    log_in_as users(:alex)
    get videos_path

    assert_select "[data-test='video-row'][data-slug='#{lettered.slug}'] [data-test='video-alt-progress']",
                  /\A0\/\d+ clips · 1 TikTok draft sent\z/
  end

  test "a row with a cast still shows it as a signed thumbnail" do
    tiled, = seed_two
    key = "music_videos/test_artist_a/tiled_demo/stills/person_01_0003.jpg"
    tiled.video_performers.find_by!(ordinal: 1).update!(still_object_keys: [key])
    log_in_as users(:alex)
    get videos_path

    assert_select "[data-test='video-row'][data-slug='#{tiled.slug}'] [data-test='video-still']" do |el|
      assert_includes el.sole["style"], key
      assert_includes el.sole["style"], "X-Amz-Signature"
    end
  end

  test "the source page links back to all videos" do
    tiled, = seed_two
    log_in_as users(:alex)
    get video_path(tiled)

    assert_select "[data-test='all-videos-link'][href='#{videos_path}']", /All videos/
  end
end
