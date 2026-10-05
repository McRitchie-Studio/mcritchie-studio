# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [integration] The recast round trip on the cast panel: admin gate, an athlete
# and look saved and the video's prompts refreshed, keep as is, clear, the
# refusals, the athlete typeahead, the by-hand look link's way back, and a
# cinematic cast confirmed with no artist on it. All data is synthetic.
class VideoPerformerRecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @video = RecastVideo.seed!
    @athlete = RecastVideo.athlete!
    @home, @away = @athlete.appearances.order(:created_at, :id).to_a
  end

  def recast(ordinal, video: @video, **params) = patch music_video_performer_recast_path(video, ordinal), params: params
  def performer(ordinal, video: @video) = video.video_performers.find_by!(ordinal:)

  test "visitors and non-admins cannot recast or search athletes" do
    recast(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert_redirected_to "/login"

    log_in_as users(:viewer)
    recast(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert_redirected_to root_path
    assert_nil performer(1).recast_person_slug
    get search_recast_athletes_path(format: :json, q: "test")
    assert_response :forbidden
  end

  test "an athlete and look are saved on a confirmed cast and the chunk prompts name them" do
    log_in_as users(:alex)
    assert @video.cast_confirmed?

    recast(1, person_slug: @athlete.slug, appearance_slug: @away.slug)

    assert_redirected_to music_video_path(@video, anchor: "person-1")
    assert_equal "Person 1 is replaced by Test Athlete Alpha > Away White.", flash[:notice]
    assert_equal [@athlete.slug, @away.slug], performer(1).values_at(:recast_person_slug, :recast_appearance_slug)
    @video.video_chunks.each do |chunk|
      assert chunk.prompt.start_with?("Replace the man in the red jacket in this video with Test Athlete Alpha, the football player.")
      assert_includes chunk.prompt, "like the Away White model provided"
    end

    follow_redirect!
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='recast']" do
      assert_select "[data-test='recast-label'][data-person=?][data-look=?]", @athlete.slug, @away.slug, "Test Athlete Alpha > Away White"
      assert_select "[data-test='recast-looks'][x-data='lookPicker()'][data-saved-look=?]", @away.slug
      assert_equal [["Home Blue", true, "empty"], ["Away White", false, "empty"]],
                   JSON.parse(css_select("[data-ordinal='1'] [data-test='recast-looks']").first["data-athlete"])["looks"]
                       .map { |look| look.values_at("descriptor", "default", "state") }
      assert_select "[data-test='recast-look-form'][action=?] input[name='appearance_slug']", music_video_performer_recast_path(@video, 1)
    end
    assert_select "#chunk-1 [data-test='chunk-recast']", /Test Athlete Alpha > Away White/
    assert_select "#chunk-1 [data-test='chunk-prompt']", /with Test Athlete Alpha, the football player/
    assert_select "[data-test='recast-progress']", /1\s+recast,\s+0\s+still to answer/
  end

  test "keep as is and clear" do
    log_in_as users(:alex)
    recast(1, person_slug: @athlete.slug, appearance_slug: @away.slug)

    recast(1, keep: "1")
    assert_equal "Person 1 is kept as is.", flash[:notice]
    assert_equal [nil, nil, true], performer(1).values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("{athlete}") })

    recast(1, clear: "1")
    assert_equal "Person 1: recast cleared.", flash[:notice]
    assert_not performer(1).recast_keep?
    follow_redirect!
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='open']"
    assert_select "[data-test='recast-progress']", /0\s+recast,\s+1\s+still to answer/
  end

  test "an athlete with no look, another athlete's look and an unknown person are refused" do
    log_in_as users(:alex)
    other = Person.create!(first_name: "Test", last_name: "Athlete Beta", athlete: true)
    theirs = other.appearances.create!(descriptor: "Road Grey")

    assert_no_difference -> { ErrorLog.count } do
      recast(1, person_slug: @athlete.slug)
    end
    assert_match "choose an athlete and one of their looks, or keep as is", flash[:alert]

    recast(1, person_slug: @athlete.slug, appearance_slug: theirs.slug)
    assert_match "is not a live look of that athlete", flash[:alert]
    recast(1, person_slug: "nobody-here", appearance_slug: @home.slug)
    assert_match "names no person", flash[:alert]

    assert performer(1).recast_keep?, "the seeded answer stands"
    recast(9, keep: "1")
    assert_response :not_found
  end

  test "the typeahead returns every matching person: looks, headshot, vocation and team per row" do
    log_in_as users(:alex)
    team = Team.create!(slug: "test-city-testers", name: "Test City Testers")
    gamma = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)
    profile = Athlete.create!(person_slug: gamma.slug, sport: "football", team_slug: team.slug)
    cache = ImageCache.create!(owner: profile, purpose: "headshot", variant: "100", content_type: "image/png",
                               s3_key: "headshots/nfl/test-city-testers/test-athlete-gamma/100.png")

    get search_recast_athletes_path(format: :json, q: "test ath")
    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal [%w[test-athlete-alpha Test\ Athlete\ Alpha], %w[test-athlete-gamma Test\ Athlete\ Gamma]],
                 rows.map { |r| r.values_at("slug", "name") }
    assert_equal [["Home Blue", true], ["Away White", false]], rows.first["looks"].map { |l| l.values_at("descriptor", "default") }
    assert_equal [@home.slug, @away.slug], rows.first["looks"].map { |l| l["slug"] }
    assert_equal ["2 looks", nil, "athlete", nil], rows.first.values_at("hint", "avatar_url", "vocation", "team")
    assert_equal ["0 looks", cache.url, "athlete", "Test City Testers", []],
                 rows.last.values_at("hint", "avatar_url", "vocation", "team", "looks")
  end

  test "a look-less athlete is saved alone and the card offers to generate the first look, or to add one by hand" do
    log_in_as users(:alex)
    gamma = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)
    card = "/music_videos/#{@video.slug}#person-1"

    assert_no_difference -> { ErrorLog.count } do
      recast(1, person_slug: gamma.slug)
    end
    assert_redirected_to card
    assert_match "Test Athlete Gamma has no look yet", flash[:notice]
    assert performer(1).recast_pending?
    assert_not performer(1).resolved?, "an athlete with no look does not close a card"

    follow_redirect!
    assert_select "[data-ordinal='1'] [data-test='performer-recast'][data-state='pending']" do
      assert_select "[data-test='recast-pending']", 0
      assert_select "[data-test='recast-looks'][data-athlete=?]", { slug: gamma.slug, name: "Test Athlete Gamma", looks: [] }.to_json
      assert_select "[data-test='recast-looks'][data-new-look-url=?]", "/people/__slug__?return_to=%2Fmusic_videos%2F#{@video.slug}%23person-1#new-model"
      assert_select "button[data-test='look-generate-first']", "Generate first look"
      assert_select "[data-test='look-generate-form'][action=?]", music_video_performer_recast_looks_path(@video, 1)
    end

    # The by-hand route still returns to the card, which then lists the look.
    post create_appearance_person_path(gamma.slug, return_to: card), params: { appearance: { descriptor: "Training Grey" } }
    assert_redirected_to card
    follow_redirect!
    assert_select "[data-ordinal='1'] [data-test='recast-pending']", /No look chosen/
    assert_equal ["Training Grey"],
                 JSON.parse(css_select("[data-ordinal='1'] [data-test='recast-looks']").first["data-athlete"])["looks"].pluck("descriptor")
  end

  test "the by-hand link opens the person's look form, and saving returns to the cast card" do
    log_in_as users(:alex)
    recast(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    card = "/music_videos/#{@video.slug}#person-1"

    get music_video_path(@video)
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='recast-looks'][data-new-look-url=?]",
                  person_path("__slug__", return_to: card, anchor: "new-model")
    assert_select "[data-test='performer-card'][data-ordinal='1'] a[data-test='recast-new-look']", /Or add a look by hand/

    get person_path(@athlete.slug, return_to: card)
    assert_select "details#new-model[open] [data-test='new-model-return']"
    assert_select "details#new-model form[action=?]", create_appearance_person_path(@athlete.slug, return_to: card)

    assert_difference -> { @athlete.appearances.count } => 1 do
      post create_appearance_person_path(@athlete.slug, return_to: card), params: { appearance: { descriptor: "Alternate Black" } }
    end
    assert_redirected_to card

    get music_video_path(@video)
    assert_includes JSON.parse(css_select("[data-ordinal='1'] [data-test='recast-looks']").first["data-athlete"])["looks"].pluck("descriptor"),
                    "Alternate Black"
  end

  test "a return address that is not a cast card is ignored" do
    log_in_as users(:alex)
    ["https://evil.example/music_videos/x", "//evil.example", "/admin", "/music_videos/x/../../admin"].each do |target|
      post create_appearance_person_path(@athlete.slug, return_to: target), params: { appearance: { descriptor: "Look #{target.hash}" } }
      assert_redirected_to person_path(@athlete.slug)
    end
    get person_path(@athlete.slug)
    assert_select "details#new-model[open]", 0
  end

  test "a cinematic cast is confirmed with no artist once every card is recast or kept" do
    log_in_as users(:alex)
    video = MusicVideo.create!(slug: "test-cinematic-open", kind: "cinematic", platform: "youtube", source_id: "tco",
                               source_url: "https://www.youtube.com/watch?v=tco", title: "Test Cinematic Open",
                               source_object_key: "music_videos/test_cinematic/open/source/a.mp4")
    MusicVideos::ReplacePerformers.new(video, TiledVideo::PERFORMERS).call

    get music_video_path(video)
    assert_select "[data-test='performer-card'][data-resolved='false']", 2
    assert_select "[data-test='performer-artist-optional']", 2
    assert_select "[data-test='confirm-cast-form'] button[disabled]"
    post confirm_cast_music_video_path(video)
    assert_match "neither recast, kept as is, an artist nor an extra", flash[:alert]

    recast(1, video:, person_slug: @athlete.slug, appearance_slug: @home.slug)
    recast(2, video:, keep: "1")
    get music_video_path(video)
    assert_select "[data-test='performer-card'][data-resolved='true']", 2
    assert_select "[data-test='performer-closed-by-recast']", text: "Recast", count: 1
    assert_select "[data-test='performer-closed-by-recast']", text: "Kept", count: 1

    post confirm_cast_music_video_path(video)
    assert_equal "cast_confirmed", video.reload.stage
    assert_equal [nil, nil], video.video_performers.map(&:artist_slug)
  end

  test "a music video card stays open under a recast" do
    log_in_as users(:alex)
    video = MusicVideo.create!(slug: "test-music-open", kind: "music_video", platform: "youtube", source_id: "tmo",
                               source_url: "https://www.youtube.com/watch?v=tmo", title: "Test Music Open",
                               source_object_key: "music_videos/test_artist/open/source/a.mp4")
    MusicVideos::ReplacePerformers.new(video, TiledVideo::PERFORMERS).call
    recast(1, video:, person_slug: @athlete.slug, appearance_slug: @home.slug)
    recast(2, video:, keep: "1")

    get music_video_path(video)
    assert_select "[data-test='performer-card'][data-resolved='false']", 2
    assert_select "[data-test='performer-artist-optional']", 0
    post confirm_cast_music_video_path(video)
    assert_equal "digested", video.reload.stage
  end
end
