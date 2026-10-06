# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [integration] The recast round trip on the cast panel: admin gate, an athlete
# and look saved and the video's prompts refreshed, the JSON saves the Swap
# Person toggle makes (pick, look change, toggle off, refusal), clear, the
# athlete typeahead, the by-hand look link's way back, and a cast confirmed
# with nobody named and nothing pressed. All data is synthetic.
class VideoPerformerRecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @video = RecastVideo.seed!
    @athlete = RecastVideo.athlete!
    @home, @away = @athlete.appearances.order(:created_at, :id).to_a
  end

  def recast(ordinal, video: @video, **params) = patch music_video_performer_recast_path(video, ordinal), params: params

  # What the Swap Person card sends: JSON in, JSON out.
  def save(ordinal, video: @video, **body)
    patch music_video_performer_recast_path(video, ordinal), params: body.to_json,
                                                              headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    response.parsed_body
  end
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
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='recast'][x-data='swapCard()']" do |node|
      assert_equal [@athlete.slug, @away.slug], node.first.attributes.values_at("data-saved-person", "data-saved-look").map(&:value)
      assert_equal [["Home Blue", true, "empty"], ["Away White", false, "empty"]],
                   JSON.parse(node.first["data-athlete"])["looks"].map { |look| look.values_at("descriptor", "default", "state") }
      assert_select "button[role='switch'][aria-checked='true'][data-test='swap-toggle']", "Swap Person"
      assert_select "[data-test='swap-athlete-name']", "Test Athlete Alpha"
      assert_select "[data-test='look-cast']", 0
    end
    assert_select "#chunk-1 [data-test='chunk-recast']", /Test Athlete Alpha > Away White/
    assert_select "#chunk-1 [data-test='chunk-prompt']", /with Test Athlete Alpha, the football player/
    assert_select "[data-test='cast-swap-count']", "1 of 2"
  end

  test "the swap card's JSON saves: a pick, a look change, and the toggle turned off, each refreshing the prompts" do
    log_in_as users(:alex)

    body = save(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert_response :success
    assert_equal({ "state" => "recast", "person_slug" => @athlete.slug, "appearance_slug" => @home.slug,
                   "label" => "Test Athlete Alpha > Home Blue", "message" => "Person 1 is replaced by Test Athlete Alpha > Home Blue." }, body)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("like the Home Blue model provided") })

    assert_equal "Test Athlete Alpha > Away White", save(1, person_slug: @athlete.slug, appearance_slug: @away.slug)["label"]
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("like the Away White model provided") })

    body = save(1, clear: "1")
    assert_equal ["off", nil, nil], body.values_at("state", "person_slug", "appearance_slug")
    assert_equal [nil, nil, false], performer(1).values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("{athlete}") })
  end

  test "the JSON save refuses with a 422 and the reason, and records no ErrorLog; visitors get no save" do
    log_in_as users(:alex)
    other = Person.create!(first_name: "Test", last_name: "Athlete Beta", athlete: true)
    theirs = other.appearances.create!(descriptor: "Road Grey")

    assert_no_difference -> { ErrorLog.count } do
      body = save(1, person_slug: @athlete.slug)
      assert_response :unprocessable_entity
      assert_equal "Person 1 not recast: choose an athlete and one of their looks, or turn the swap off.", body["error"]
    end
    assert_match "is not a live look of that athlete", save(1, person_slug: @athlete.slug, appearance_slug: theirs.slug)["error"]
    assert_response :unprocessable_entity
    assert_nil performer(1).recast_person_slug

    log_in_as users(:viewer)
    save(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert_response :redirect
    assert_nil performer(1).recast_person_slug
  end

  test "a look-less athlete is saved alone as pending through JSON" do
    log_in_as users(:alex)
    gamma = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)

    body = save(1, person_slug: gamma.slug, appearance_slug: "")
    assert_equal ["pending", gamma.slug, nil], body.values_at("state", "person_slug", "appearance_slug")
    assert performer(1).recast_pending?
  end

  test "legacy keep and clear both read as not swapped" do
    log_in_as users(:alex)
    recast(1, person_slug: @athlete.slug, appearance_slug: @away.slug)

    recast(1, keep: "1")
    assert_equal "Person 1 is not swapped.", flash[:notice]
    assert_equal [nil, nil, true], performer(1).values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("{athlete}") })
    follow_redirect!
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='off']" do
      assert_select "button[role='switch'][aria-checked='false']", "Don’t Swap Person"
    end

    recast(1, clear: "1")
    assert_equal "Person 1 is not swapped.", flash[:notice]
    assert_not performer(1).recast_keep?
    follow_redirect!
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='off']"
    assert_select "[data-test='cast-swap-count']", "0 of 2"
  end

  test "an athlete with no look, another athlete's look and an unknown person are refused" do
    log_in_as users(:alex)
    other = Person.create!(first_name: "Test", last_name: "Athlete Beta", athlete: true)
    theirs = other.appearances.create!(descriptor: "Road Grey")

    assert_no_difference -> { ErrorLog.count } do
      recast(1, person_slug: @athlete.slug)
    end
    assert_match "choose an athlete and one of their looks, or turn the swap off", flash[:alert]

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
      assert_select "[data-test='performer-recast'][data-athlete=?]",
                    { slug: gamma.slug, name: "Test Athlete Gamma", avatar_url: nil, vocation: "athlete", team: nil, looks: [] }.to_json
      assert_select "[data-test='performer-recast'][data-new-look-url=?]", "/people/__slug__?return_to=%2Fmusic_videos%2F#{@video.slug}%23person-1#new-model"
      assert_select "button[data-test='look-generate-first']", "Generate first look"
      assert_select "[data-test='look-generate-form'][action=?]", music_video_performer_recast_looks_path(@video, 1)
    end
    assert_select "[data-test='recast-waiting']", "1 still needs a look."

    # The by-hand route still returns to the card, which then lists the look.
    post create_appearance_person_path(gamma.slug, return_to: card), params: { appearance: { descriptor: "Training Grey" } }
    assert_redirected_to card
    follow_redirect!
    assert_equal ["Training Grey"],
                 JSON.parse(css_select("[data-ordinal='1'] [data-test='performer-recast']").first["data-athlete"])["looks"].pluck("descriptor")
  end

  test "the by-hand link opens the person's look form, and saving returns to the cast card" do
    log_in_as users(:alex)
    recast(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    card = "/music_videos/#{@video.slug}#person-1"

    get music_video_path(@video)
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-new-look-url=?]",
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
    assert_includes JSON.parse(css_select("[data-ordinal='1'] [data-test='performer-recast']").first["data-athlete"])["looks"].pluck("descriptor"),
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

  test "a cast with nobody named and nothing swapped confirms with nothing pressed, cinematic or music video" do
    log_in_as users(:alex)
    %w[cinematic music_video].each do |kind|
      video = MusicVideo.create!(slug: "test-#{kind.dasherize}-open", kind:, platform: "youtube", source_id: "t#{kind}",
                                 source_url: "https://www.youtube.com/watch?v=t#{kind}", title: "Test #{kind} open",
                                 source_object_key: "music_videos/test_artist/#{kind}_open/source/a.mp4")
      MusicVideos::ReplacePerformers.new(video, TiledVideo::PERFORMERS).call

      get music_video_path(video)
      assert_select "[data-test='performer-card'][data-resolved='true'][data-named='false']", 2
      assert_select "[data-test='performer-badge']", text: "Not named", count: 2
      assert_select "[data-test='performer-artist-optional']", 2
      assert_select "[data-test='performer-recast'][data-state='off']", 2
      assert_select "[data-test='cast-named-count']", /Nobody named\. Naming is optional/
      assert_select "[data-test='confirm-cast-form'] button:not([disabled])", "Cast confirmed"

      post confirm_cast_music_video_path(video)
      assert_equal "cast_confirmed", video.reload.stage
      assert_equal [nil, nil], video.video_performers.map(&:artist_slug)
    end
  end
end
