# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [integration] The clip builder end to end: Build Clips on the cast page makes
# an alt video and opens it; a dropped MP4 becomes a clip's primary version;
# an older version is put back in front; a clip is flagged; the full video is
# requested; the index shows the progress. Every page and endpoint is admin
# only. [component] The clip card's buttons, drop zone and versions list, the
# Watch full video timeline and the index row. Wholly synthetic people.
class AltVideosControllerTest < ActionDispatch::IntegrationTest
  Store = MusicVideos::StoreClipVersion

  setup do
    @video = TiledVideo.seed!
    @athlete = RecastVideo.athlete!
    @look = @athlete.appearances.live.find_by!(descriptor: "Home Blue")
    @video.video_performers.find_by!(ordinal: 1)
          .update!(recast_person_slug: @athlete.slug, recast_appearance_slug: @look.slug, recast_keep: false)
    @stored = []
    stored = @stored
    @real_store = Store.method(:store)
    Store.define_singleton_method(:store) { |key:, body:| stored << [key, body.read.bytesize] }
  end

  teardown { Store.define_singleton_method(:store, @real_store) }

  def mp4 = fixture_file_upload("stitch_demo.mp4", "video/mp4")

  def alt = @video.alt_videos.first

  def clip(ordinal) = alt.reload.clips.find { |c| c.chunk_ordinal == ordinal }

  def upload(ordinal) = post(music_video_alt_video_clip_versions_path(@video, alt, ordinal), params: { file: mp4 })

  def timeline = JSON.parse(css_select("[data-test='stitch-preview']").sole["data-timeline"])

  test "non-admins reach no page and change nothing" do
    built = AltVideo.build_from!(@video)
    TiledVideo.version!(built.clips.first, number: 1)
    log_in_as users(:viewer)

    get alt_videos_path
    assert_redirected_to root_path
    get music_video_alt_video_path(@video, built)
    assert_redirected_to root_path
    post music_video_alt_videos_path(@video)
    assert_redirected_to root_path
    post music_video_alt_video_clip_versions_path(@video, built, 1), params: { file: mp4 }
    assert_redirected_to root_path
    post primary_music_video_alt_video_clip_version_path(@video, built, 1, 1)
    assert_redirected_to root_path
    post music_video_alt_video_clip_regenerate_path(@video, built, 1)
    assert_redirected_to root_path
    delete music_video_alt_video_clip_regenerate_path(@video, built, 1)
    assert_redirected_to root_path
    post music_video_alt_video_stitches_path(@video, built)
    assert_redirected_to root_path
    get music_video_alt_video_stitch_path(@video, built, 1)
    assert_redirected_to root_path

    assert_equal 1, AltVideo.count
    assert_empty @stored
    assert_not clip(1).regenerate_requested?
  end

  test "Build Clips sits in the cast summary bar and opens the new alt video" do
    log_in_as users(:alex)
    get music_video_path(@video)
    assert_select "[data-test='cast-progress'] [data-test='build-clips-form'] button:not([disabled])", "Build Clips"
    assert_select "[data-test='source-alt-videos-none']"

    assert_difference -> { AltVideo.count }, 1 do
      post music_video_alt_videos_path(@video)
    end
    assert_redirected_to music_video_alt_video_path(@video, 1)
    assert_equal "Alt video 1 built: 4 clips, Test Athlete Alpha > Home Blue.", flash[:notice]

    follow_redirect!
    assert_response :ok
    assert_select "[data-test='alt-video-kicker']", /Source video · Alt video 1/
    assert_select "[data-test='alt-video-swap'][data-ordinal='1']", /Test Athlete Alpha > Home Blue/
    assert_select "[data-test='alt-clip']", 4
    assert_select "[data-test='alt-progress-count']", "0 of 4"

    get music_video_path(@video)
    assert_select "[data-test='source-alt-video'][data-number='1']", /Alt video 1/
  end

  test "Build Clips is off, and refused, before the cast is confirmed" do
    @video.update!(stage: "digested")
    log_in_as users(:alex)
    get music_video_path(@video)
    assert_select "[data-test='build-clips-form'] button[disabled]"

    assert_no_difference -> { AltVideo.count } do
      post music_video_alt_videos_path(@video)
    end
    assert_redirected_to music_video_path(@video)
    assert_equal "Not yet: confirm the cast first.", flash[:alert]
  end

  test "a clip card hands off the source clip, the swapped person's sheet and the snapshot's prompt" do
    AltVideo.build_from!(@video)
    # The card is edited after the build: the alt video keeps its own swap.
    @video.video_performers.find_by!(ordinal: 1).update!(recast_keep: true)
    log_in_as users(:alex)
    get music_video_alt_video_path(@video, alt)

    assert_select "[data-test='alt-clip'][data-ordinal='2']" do
      assert_select "[data-test='clip-window']", /0:20–0:45/
      assert_select "[data-test='clip-swap']", /Test Athlete Alpha > Home Blue/
      assert_select "[data-test='clip-prompt']", /with Test Athlete Alpha, the football player/
      assert_select "[data-test='clip-copy']", "Copy prompt"
      assert_select "[data-test='clip-chunk-download'][download='tiled_demo_chunk_02_0020_0045.mp4']", "Download 25 s clip"
      assert_select "[data-test='clip-sheet-missing'][data-ordinal='1']", /No character sheet for Test Athlete Alpha > Home Blue/
      assert_select "[data-test='clip-drop-form'][data-max-bytes='#{Store::MAX_BYTES}']" do
        assert_select "[data-test='clip-drop']", /Drop the generated MP4 here/
        assert_select "input[type='file'][name='file'][data-test='clip-file']"
      end
      assert_select "[data-test='clip-versions-empty']"
    end
  end

  test "an upload becomes the primary version; an older one can be put back" do
    AltVideo.build_from!(@video)
    log_in_as users(:alex)

    upload(2)
    assert_redirected_to music_video_alt_video_path(@video, 1, anchor: "clip-2")
    assert_equal "Clip 2: version 1 uploaded and primary.", flash[:notice]
    key = "music_videos/test_artist_a/tiled_demo/alt_videos/01/clips/tiled_demo_alt_01_chunk_02_0020_0045_v01.mp4"
    assert_equal [[key, file_fixture("stitch_demo.mp4").size]], @stored, "the whole file reached the bucket seam"

    travel 1.second do
      upload(2)
    end
    assert_equal 2, clip(2).primary_version.number

    post primary_music_video_alt_video_clip_version_path(@video, alt, 2, 1)
    assert_equal "Clip 2: version 1 is primary.", flash[:notice]
    assert_equal 1, clip(2).primary_version.number
    assert_equal 2, clip(2).versions.size, "both versions are kept"

    follow_redirect!
    assert_select "[data-test='alt-clip'][data-ordinal='2'][data-primary='1']" do
      assert_select "[data-test='clip-state']", "Version 1 primary"
      assert_select "[data-test='clip-version']", 2
      assert_select "[data-test='clip-version'][data-number='1'][data-primary='true']"
      assert_select "[data-test='clip-version'][data-number='2'][data-primary='false'] [data-test='clip-make-primary']"
    end
    assert_select "[data-test='alt-progress-count']", "1 of 4"
    segments = timeline["segments"]
    assert_equal [true, false, true, true], segments.map { |s| s["source"] }
    assert_equal "version 1", segments.second["label"]
    assert_equal [22_500, 42_500], segments.second.values_at("from_ms", "to_ms")
    assert_match(/v01\.mp4/, segments.second["url"])
    assert_match(/chunks\/tiled_demo_chunk_01_0000_0025\.mp4/, segments.first["url"], "no version: the source chunk plays")
  end

  test "a non-MP4 is refused and records nothing" do
    AltVideo.build_from!(@video)
    log_in_as users(:alex)
    post music_video_alt_video_clip_versions_path(@video, alt, 1),
         params: { file: fixture_file_upload("notes.txt", "text/plain") }

    assert_equal "Clip 1 version not uploaded: that file is not an MP4.", flash[:alert]
    assert_equal 0, AltVideoClipVersion.count
    assert_empty @stored
  end

  test "a clip flagged for a regenerate holds the stitch back until the next upload" do
    AltVideo.build_from!(@video)
    alt.clips.each { |c| TiledVideo.version!(c, number: 1, at: 1.hour.ago) }
    log_in_as users(:alex)

    post music_video_alt_video_clip_regenerate_path(@video, alt, 3), params: { note: "the jersey flickers" }
    assert_equal "Clip 3 flagged for a regenerate.", flash[:notice]
    post music_video_alt_video_stitches_path(@video, alt)
    assert_equal "Not ready to stitch: Clip 3 is flagged for a regenerate.", flash[:alert]

    upload(3)
    assert_not clip(3).regenerate_requested?
    MusicVideos::Stitcher.stub(:available?, false) do
      post music_video_alt_video_stitches_path(@video, alt)
    end
    assert_equal "Stitch 1 requested: waiting for bin/stitch-video #{@video.slug} --alt 1 on the Mac.", flash[:notice]
    assert_equal "1, 1, 2, 1", alt.stitches.sole.take_list

    get music_video_alt_video_stitch_path(@video, alt, 1)
    assert_equal({ "number" => 1, "state" => "requested" }, JSON.parse(response.body))
  end

  test "the index lists every alt video with its progress, newest activity first" do
    first = AltVideo.build_from!(@video)
    TiledVideo.version!(first.clips.first, number: 1)
    travel 1.minute do
      second = AltVideo.build_from!(@video)
      TiledVideo.version!(second.clips.second, number: 1)
      TiledVideo.version!(second.clips.third, number: 1)
    end
    log_in_as users(:alex)
    get alt_videos_path

    assert_response :ok
    assert_select "[data-test='alt-video-row']", 2
    assert_select "[data-test='alt-video-row']:first-of-type[data-slug='test-artist-a-tiled-demo-alt-2'][data-primary='2'][data-total='4']"
    assert_select "[data-test='alt-video-row'][data-slug='test-artist-a-tiled-demo-alt-1']" do
      assert_select "[data-test='alt-video-row-progress']", /1 of 4/
      assert_select "[data-test='alt-video-row-stitch']", "Not stitched"
      assert_select "[data-test='alt-video-row-swaps']", "Test Athlete Alpha > Home Blue"
    end
  end

  test "the clip builder costs no query per clip or version" do
    built = AltVideo.build_from!(@video)
    log_in_as users(:alex)
    count = lambda do
      queries = []
      ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" },
                                              "sql.active_record") { get music_video_alt_video_path(@video, built) }
      queries.size
    end
    bare = count.call
    built.clips.each { |c| 2.times { |i| TiledVideo.version!(c, number: i + 1) } }
    assert_equal bare, count.call, "eight versions over four clips render with the same queries as none"
  end

  test "the admin links reach the index" do
    log_in_as users(:alex)
    get admin_links_path
    assert_select "a[href='#{alt_videos_path}']", /Alt videos/
  end
end
