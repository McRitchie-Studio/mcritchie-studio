# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

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
      assert_select "[data-test='clip-swap-row'][data-letter='A'][data-lead='true']", /Person A.*lead.*Test Athlete Alpha, Home Blue.*sheet 1/m
      assert_select "[data-test='clip-prompt']", /Person A \(lead\) -> Test Athlete Alpha, Home Blue \(character sheet 1\)/
      assert_select "[data-test='clip-copy']", "Copy prompt"
      assert_select "[data-test='clip-chunk-download'][download='tiled_demo_chunk_02_0020_0045.mp4']", "Download 25 s clip"
      assert_select "[data-test='clip-sheet-missing'][data-ordinal='1']",
                    /Sheet 1 · Person A · Test Athlete Alpha: no character sheet for Test Athlete Alpha > Home Blue/
      assert_select "[data-test='clip-frames-none']", /bin\/clip-references #{@video.slug}/
      assert_select "[data-test='clip-drop-form'][data-max-bytes='#{Store::MAX_BYTES}']" do
        assert_select "[data-test='clip-drop']", /Drop the generated MP4 here/
        assert_select "input[type='file'][name='file'][data-test='clip-file']"
      end
      assert_select "[data-test='clip-versions-empty']"
    end
  end

  # [component] Piece 16: two swaps in one window, lettered frames with
  # Download above the hand-off, and each sheet labelled as the prompt numbers it.
  test "a clip card letters its people: frames, numbered sheets and the full v2 prompt" do
    video = LetteredVideo.seed!
    alt = video.alt_videos.first
    log_in_as users(:alex)
    get music_video_alt_video_path(video, alt)

    assert_select "[data-test='alt-video-swap'][data-ordinal='2']", /Person B.*Person 2.*#4.*Test Passer Epsilon > Home White/m
    assert_select "[data-test='alt-clip'][data-ordinal='3']" do
      assert_select "[data-test='clip-swap-row']", 2
      assert_select "[data-test='clip-swap-row'][data-letter='B'][data-lead='true']", /#4 Test Passer Epsilon/
      assert_select "[data-test='clip-swap-row'][data-letter='C'][data-lead='false']", /background.*#88 Test Receiver Zeta/m
      assert_select "[data-test='clip-frames'][data-count='2']" do
        assert_select "[data-test='clip-frame'][data-letters='A,B,C']", 2
        assert_select "[data-test='clip-frame']", /0:45 · A B C/
      end
      assert_select "[data-test='clip-sheet'][data-sheet='1'][data-ordinal='2']", "Sheet 1 · Person B · #4 Test Passer Epsilon"
      assert_select "[data-test='clip-sheet'][data-sheet='2'][data-ordinal='3']", "Sheet 2 · Person C · #88 Test Receiver Zeta"
      assert_select "[data-test='clip-prompt']", /- Person B \(lead\) -> #4 Test Passer Epsilon, Home White \(character sheet 1\)\s+- Person C \(background\) -> #88 Test Receiver Zeta, Home White \(character sheet 2\)/
    end
    # The frames sit above the hand-off buttons on the card.
    card = css_select("[data-test='alt-clip'][data-ordinal='3']").sole.to_html
    assert_operator card.index("data-test=\"clip-frames\""), :<, card.index("data-test=\"clip-handoff\"")
    assert_select "[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-frames-none']"

    # The cast card carries the same letter.
    get music_video_path(video)
    assert_select "[data-test='performer-card'][data-ordinal='2'] [data-test='performer-letter']", "B"
  end

  test "a swapped person with no sheet keeps the number in the card's label" do
    video = LetteredVideo.seed!
    alt = video.alt_videos.first
    ArtifactSubject.where(appearance_slug: alt.swap_set[3].appearance_slug).destroy_all
    log_in_as users(:alex)
    get music_video_alt_video_path(video, alt)

    assert_select "[data-test='alt-clip'][data-ordinal='3']" do
      assert_select "[data-test='clip-sheet'][data-sheet='1']", "Sheet 1 · Person B · #4 Test Passer Epsilon"
      assert_select "[data-test='clip-sheet-missing'][data-ordinal='3']", /\ASheet 2 · Person C · #88 Test Receiver Zeta: no character sheet/
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

  # [component] Piece 18: a clip with a primary version shows it beside the
  # source chunk, both opening on their first frame, with Play both and one
  # scrub under them; a clip with none keeps the single preview, which also
  # opens on its first frame. What it proves: the markup the browser is handed
  # (which file sits on which side, preload=metadata plus the #t=0.001
  # fragment, the labels, the controls). It does not prove a frame is painted
  # or that the two play in sync: the e2e drives the player, and the posters
  # are judged by eye in the screenshots.
  test "a clip with a primary shows the original and the primary side by side, each on its first frame" do
    AltVideo.build_from!(@video)
    TiledVideo.version!(clip(2), number: 1, at: 1.hour.ago)
    TiledVideo.version!(clip(2), number: 2)
    log_in_as users(:alex)
    get music_video_alt_video_path(@video, alt)

    version_key = clip(2).primary_version.object_key
    assert_select "[data-test='alt-clip'][data-ordinal='2'][data-compare='true']" do
      assert_select "[data-test='clip-compare'][data-primary='2'][x-data='clipPair()']" do
        assert_select "[data-test='clip-compare-original'] figcaption", "Original"
        assert_select "[data-test='clip-compare-original'] video[data-test='clip-player'][x-ref='original'][preload='metadata'][controls]" do |video|
          assert_match %r{chunks/tiled_demo_chunk_02_0020_0045\.mp4\?.*#t=0\.001\z}, video.first["src"]
        end
        assert_select "[data-test='clip-compare-version'][data-number='2'] figcaption", /\AVersion 2\s+\(primary\)\z/
        assert_select "[data-test='clip-compare-version'] video[data-test='clip-version-player'][x-ref='version'][preload='metadata'][controls]" do |video|
          assert_includes video.first["src"], "#{version_key}?"
          assert video.first["src"].end_with?("#t=0.001")
        end
        assert_select "video[muted]", 0, "nothing is muted until Play both: either player alone keeps its sound"
        assert_select "[data-test='clip-play-both']", /Play both/
        assert_select "input[type='range'][data-test='clip-scrub']"
        assert_select "[data-test='clip-play-both-note']", /Sound from Version 2 only: the original plays muted\./
      end
      assert_select "[data-test='clip-preview-button']", 0
      # The rest of the card is untouched.
      assert_select "[data-test='clip-handoff'] [data-test='clip-chunk-download']"
      assert_select "[data-test='clip-version']", 2
      assert_select "[data-test='clip-regenerate-form']"
    end

    # No version: the single preview, now on its first frame rather than black.
    assert_select "[data-test='alt-clip'][data-ordinal='1'][data-compare='false']" do
      assert_select "[data-test='clip-compare']", 0
      assert_select "[data-test='clip-play-both']", 0
      assert_select "[data-test='clip-solo'][x-data='clipPair()'] video[data-test='clip-player'][preload='metadata']" do |video|
        assert_match %r{tiled_demo_chunk_01_0000_0025\.mp4\?.*#t=0\.001\z}, video.first["src"]
      end
      assert_select "[data-test='clip-preview-button']", /Preview the source chunk/
    end
  end

  test "making an older version primary swaps the right-hand player" do
    AltVideo.build_from!(@video)
    TiledVideo.version!(clip(3), number: 1, at: 1.hour.ago)
    TiledVideo.version!(clip(3), number: 2)
    log_in_as users(:alex)

    post primary_music_video_alt_video_clip_version_path(@video, alt, 3, 1)
    follow_redirect!

    one = clip(3).versions.find { |v| v.number == 1 }.object_key
    assert_select "[data-test='alt-clip'][data-ordinal='3'] [data-test='clip-compare'][data-primary='1']" do
      assert_select "[data-test='clip-compare-version'][data-number='1'][data-key=?] figcaption", one, /Version 1\s+\(primary\)/
      assert_select "video[data-test='clip-version-player']" do |video|
        assert_includes video.first["src"], "#{one}?"
      end
    end
  end

  test "a primary whose file is not reachable keeps the single preview" do
    AltVideo.build_from!(@video)
    TiledVideo.version!(clip(2), number: 1)
    # Signs everything but the versions, as a store missing that object would.
    store = Object.new
    store.define_singleton_method(:signed_url) { |key:, **| key.include?("/clips/") ? nil : "https://fixture.invalid/#{key}?sig" }
    log_in_as users(:alex)
    AssetBrowser.stub(:source, store) { get music_video_alt_video_path(@video, alt) }

    assert_select "[data-test='alt-clip'][data-ordinal='2'][data-compare='false']" do
      assert_select "[data-test='clip-compare']", 0
      assert_select "[data-test='clip-solo'] video[data-test='clip-player']"
    end
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

  # [integration] The links endpoint: the page's signed URLs again, as JSON, for
  # a page left open past the fifteen minutes they last. What it proves: who is
  # answered and how (a status the page can read, never a redirect), that the
  # answer holds exactly the keys the page shows, and that nothing in the
  # request can add a key. It does not prove a URL opens: the fixture store
  # signs nothing real.
  JSON_FETCH = { "Accept" => "application/json" }.freeze

  test "the links endpoint answers a signed-out fetch 401 and a non-admin 403, with no link" do
    built = AltVideo.build_from!(@video)

    get links_music_video_alt_video_path(@video, built), headers: JSON_FETCH
    assert_response :unauthorized
    assert_equal({ "error" => "unauthenticated" }, JSON.parse(response.body))

    log_in_as users(:viewer)
    get links_music_video_alt_video_path(@video, built), headers: JSON_FETCH
    assert_response :forbidden
    assert_no_match(/fixture\.invalid/, response.body)
    # Opened as a page it is walled like every other: a redirect, and still no link.
    get links_music_video_alt_video_path(@video, built)
    assert_redirected_to root_path
  end

  test "the links endpoint signs the page's own files again, and no key the request names" do
    AltVideo.build_from!(@video)
    alt.clips.each { |c| TiledVideo.version!(c, number: 1, at: 1.hour.ago) }
    TiledVideo.version!(clip(2), number: 2)
    stitch = MusicVideos::RequestStitch.new(alt.reload).call.stitch
    stitch.update!(state: "done", duration_ms: 95_000, byte_size: 4_096, finished_at: Time.current)
    # Another alt video of the same source: its versions are not this page's.
    other = AltVideo.build_from!(@video)
    foreign = TiledVideo.version!(other.clips.first, number: 1).object_key
    log_in_as users(:alex)

    get music_video_alt_video_path(@video, alt)
    shown = css_select("[data-signed-key]").map { |el| el["data-signed-key"] }.uniq

    freeze_time do
      get links_music_video_alt_video_path(@video, alt), params: { keys: [foreign, "secrets/elsewhere.mp4"], key: foreign }, headers: JSON_FETCH
      assert_response :ok
      assert_equal "no-store", response.headers["Cache-Control"]
      body = JSON.parse(response.body)

      chunk_keys = @video.video_chunks.map(&:object_key)
      version_keys = alt.reload.clips.flat_map { |c| c.versions.map(&:object_key) }
      assert_equal 5, version_keys.size
      assert_equal (chunk_keys + version_keys + [@video.source_object_key, stitch.object_key]).sort, body["inline"].keys.sort
      assert_equal (chunk_keys + [stitch.object_key]).sort, body["download"].keys.sort
      assert_not_includes body["inline"].keys, foreign
      assert_no_match(/elsewhere|#{Regexp.escape(foreign)}/, response.body)
      body["inline"].each { |key, url| assert_equal "https://fixture.invalid/#{key}?X-Amz-Expires=900&X-Amz-Signature=fixture", url }
      assert_match(/response-content-disposition=attachment/, body["download"].fetch(stitch.object_key))

      assert_equal 900, body["ttl"]
      assert_equal (Time.current.to_f * 1000).round, body["signed_at"]
      assert_equal 15.minutes.from_now.iso8601, body["expires_at"]
    end

    # Every element the page marks for a fresh link gets one.
    assert_operator shown.size, :>=, 6
    assert_empty shown - JSON.parse(response.body)["inline"].keys
  end

  test "the links endpoint says so when the store cannot sign" do
    AltVideo.build_from!(@video)
    store = Object.new
    store.define_singleton_method(:signed_url) { |**| raise AssetBrowser::Unavailable, "NotConfigured" }
    log_in_as users(:alex)
    AssetBrowser.stub(:source, store) { get links_music_video_alt_video_path(@video, alt), headers: JSON_FETCH }

    assert_response :service_unavailable
    assert_equal({ "error" => "storage_unreachable" }, JSON.parse(response.body))
  end

  # [component] What the page hands the refresher: where to ask, how long the
  # links last and when they were signed; each player, frame and link marked
  # with its object key; the watch timeline's segments keyed the same way.
  test "the page marks every signed file with its key and says when its links were signed" do
    video = LetteredVideo.seed!
    alt = video.alt_videos.first
    TiledVideo.version!(alt.clips.find { |c| c.chunk_ordinal == 3 }, number: 1)
    chunk = video.video_chunks.find_by!(ordinal: 3)
    version = alt.reload.clips.find { |c| c.chunk_ordinal == 3 }.primary_version
    log_in_as users(:alex)

    freeze_time do
      get music_video_alt_video_path(video, alt)
      assert_select "[data-test='alt-video'][data-links-url=?][data-links-ttl='900'][data-links-signed-at=?]",
                    links_music_video_alt_video_path(video, alt), (Time.current.to_f * 1000).round.to_s
    end
    assert_select "[data-test='alt-clip'][data-ordinal='3']" do
      assert_select "video[data-test='clip-player'][data-signed-key=?]", chunk.object_key
      assert_select "video[data-test='clip-version-player'][data-signed-key=?]", version.object_key
      assert_select "[data-test='clip-link-refreshing'][x-show='renewing.original']", /This link expired: getting a fresh one/
      assert_select "[data-test='clip-version-link-refreshing'][x-show='renewing.version']"
      frame = chunk.reference_frame_list.first["object_key"]
      assert_select "[data-test='clip-frame'] a[data-signed-key=?]:not([data-signed-as]) img[data-signed-key=?]", frame, frame
      assert_select "[data-test='clip-frame-download'][data-signed-key=?][data-signed-as='download']", frame
      assert_select "[data-test='clip-chunk-download'][data-signed-key=?][data-signed-as='download']", chunk.object_key
      assert_select "[data-test='clip-version-open'][data-signed-key=?]", version.object_key
    end
    assert_select "[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-solo'] video[data-signed-key]"
    assert_select "[data-test='links-status'][x-cloak]"
    assert_equal alt.clips.map { |c| c.primary_version&.object_key || video.video_chunks.find { |k| k.ordinal == c.chunk_ordinal }.object_key },
                 timeline["segments"].map { |s| s["key"] }
    # Every marked element carries the URL the same key signs to.
    css_select("[data-signed-key]").each do |el|
      assert_includes el["src"] || el["href"], "https://fixture.invalid/#{el['data-signed-key']}?"
    end
  end

  test "the admin links reach the index" do
    log_in_as users(:alex)
    get admin_links_path
    assert_select "a[href='#{alt_videos_path}']", /Alt videos/
  end
end
