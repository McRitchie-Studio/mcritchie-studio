# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [integration] The recast round trip on the cast panel: admin gate, an athlete
# and look saved and the video's prompts refreshed, the JSON saves the Replace
# with card makes (a pick turns the swap on, a look change, Keep Original turns
# it off keeping the person, another pick unchecks it, refusal), clear, the
# athlete typeahead, the by-hand look link's way back, and a cast confirmed
# with nobody named and nothing pressed. All data is synthetic.
class VideoPerformerRecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @video = RecastVideo.seed!
    @athlete = RecastVideo.athlete!
    @home, @away = @athlete.appearances.order(:created_at, :id).to_a
  end

  def recast(ordinal, video: @video, **params) = patch music_video_performer_recast_path(video, ordinal), params: params

  # What the Replace with card sends: JSON in, JSON out.
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
      assert_select "[data-test='performer-recast'][data-keep='false']"
      assert_select "[data-test='card-bottom'] [data-test='keep-toggle']:not([x-cloak]) button[data-test='keep-original']:not([x-cloak])", "Keep Original"
      assert_select "[data-test='swap-body']:not([x-cloak]) [data-test='swap-athlete-name']", "Test Athlete Alpha"
      assert_select "[data-test='look-cast']", 0
    end
    assert_select "#chunk-1 [data-test='chunk-recast']", /Test Athlete Alpha > Away White/
    assert_select "#chunk-1 [data-test='chunk-prompt']", /with Test Athlete Alpha, the football player/
    assert_select "[data-test='cast-swap-count']", "1 of 2"
  end

  test "the card's JSON saves: a pick, a look change, and Clear, each refreshing the prompts" do
    log_in_as users(:alex)

    body = save(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert_response :success
    assert_equal({ "state" => "recast", "person_slug" => @athlete.slug, "appearance_slug" => @home.slug,
                   "label" => "Test Athlete Alpha > Home Blue", "message" => "Person 1 is replaced by Test Athlete Alpha > Home Blue." }, body)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("like the Home Blue model provided") })

    assert_equal "Test Athlete Alpha > Away White", save(1, person_slug: @athlete.slug, appearance_slug: @away.slug)["label"]
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("like the Away White model provided") })

    body = save(1, clear: "1")
    assert_equal ["none", nil, nil], body.values_at("state", "person_slug", "appearance_slug")
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

    # The admin wall answers a signed-in non-admin's JSON request with an empty 403.
    log_in_as users(:viewer)
    patch music_video_performer_recast_path(@video, 1),
          params: { person_slug: @athlete.slug, appearance_slug: @home.slug }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :forbidden
    assert_nil performer(1).recast_person_slug
  end

  test "a pick turns the swap on; Keep Original turns it off keeping the person; unchecked restores with no re-pick" do
    log_in_as users(:alex)
    assert performer(1).recast_keep?, "seeded under the old keep as is, with nobody remembered"
    body = save(1, person_slug: @athlete.slug, appearance_slug: @away.slug)
    assert_equal "recast", body["state"]
    assert performer(1).swap?, "the pick alone turned the swap on"

    body = save(1, keep: "1")
    assert_equal ["kept", @athlete.slug, @away.slug], body.values_at("state", "person_slug", "appearance_slug")
    assert_equal "Person 1 is not swapped; Test Athlete Alpha > Away White is remembered.", body["message"]
    assert_not performer(1).swap?
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("{athlete}") })

    body = save(1, swap: "1")
    assert_equal ["recast", @athlete.slug, @away.slug], body.values_at("state", "person_slug", "appearance_slug")
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("like the Away White model provided") })
  end

  test "picking another person while Keep Original is checked unchecks it and swaps to them" do
    log_in_as users(:alex)
    gamma = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)
    save(1, person_slug: gamma.slug, appearance_slug: "")
    save(1, keep: "1")
    assert_equal "kept", performer(1).swap_state

    body = save(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert_equal ["recast", @athlete.slug, @home.slug], body.values_at("state", "person_slug", "appearance_slug")
    assert_equal [@athlete.slug, @home.slug, false], performer(1).values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("like the Home Blue model provided") })
  end

  # The card's queue sends changes in the order they were made (show.html.erb, swapCard#drain):
  # a pick, a look change made while it was in flight, then Keep Original. In that order the
  # server ends where the card does: the second look, remembered, not swapped.
  test "the card's changes in order end on the last one: pick, look change, Keep Original" do
    log_in_as users(:alex)
    save(1, person_slug: @athlete.slug, appearance_slug: @home.slug)
    save(1, person_slug: @athlete.slug, appearance_slug: @away.slug)
    save(1, keep: "1")

    assert_equal ["kept", @athlete.slug, @away.slug], [performer(1).swap_state, *performer(1).values_at(:recast_person_slug, :recast_appearance_slug)]
    assert_equal "Away White", save(1, swap: "1")["label"].split(" > ").last
  end

  test "a look-less athlete is saved alone as pending through JSON" do
    log_in_as users(:alex)
    gamma = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)

    body = save(1, person_slug: gamma.slug, appearance_slug: "")
    assert_equal ["pending", gamma.slug, nil], body.values_at("state", "person_slug", "appearance_slug")
    assert performer(1).recast_pending?
  end

  test "keep turns the swap off and remembers; clear forgets; both read as not swapped" do
    log_in_as users(:alex)
    recast(1, person_slug: @athlete.slug, appearance_slug: @away.slug)

    recast(1, keep: "1")
    assert_equal "Person 1 is not swapped; Test Athlete Alpha > Away White is remembered.", flash[:notice]
    assert_equal [@athlete.slug, @away.slug, true], performer(1).values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert(@video.video_chunks.reload.all? { |c| c.prompt.include?("{athlete}") })
    follow_redirect!
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='kept'][data-keep='true']" do |node|
      assert_select "[data-test='card-bottom'] button[data-test='swap-back']:not([x-cloak])", /Swap back to\s+Test Athlete Alpha/
      assert_select "[data-test='swap-body'][x-cloak]"
      assert_equal "Test Athlete Alpha", JSON.parse(node.first["data-athlete"])["name"], "the card still knows who is remembered"
    end
    assert_select "#chunk-1 [data-test='chunk-recast']", 0
    assert_select "#chunk-1 [data-test='chunk-look-sheet'], #chunk-1 [data-test='chunk-look-sheet-missing']", 0
    assert_select "[data-test='cast-swap-count']", "0 of 2"

    recast(1, clear: "1")
    assert_equal "Person 1 is not swapped.", flash[:notice]
    assert_not performer(1).recast_keep?
    follow_redirect!
    assert_select "[data-test='performer-card'][data-ordinal='1'] [data-test='performer-recast'][data-state='none']" do
      assert_select "[data-test='keep-toggle'][x-cloak]"
      assert_select "[data-test='performer-recast'][data-athlete]", 0
    end
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
      assert_select "[data-test='performer-resolution'] [data-test='performer-typeahead'] input[role='combobox']", 2
      assert_select "[data-test='performer-recast'][data-state='none']", 2
      assert_select "[data-test='cast-named-count']", /Nobody named\. Naming is optional/
      assert_select "[data-test='confirm-cast-form'] button:not([disabled])", "Cast confirmed"

      post confirm_cast_music_video_path(video)
      assert_equal "cast_confirmed", video.reload.stage
      assert_equal [nil, nil], video.video_performers.map(&:artist_slug)
    end
  end

  # What the always-open "Who is this on screen?" search sends: JSON in, what the card shows out.
  def save_name(ordinal, **body)
    patch music_video_performer_path(@video, ordinal), params: body.to_json,
                                                       headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    response.body.present? ? response.parsed_body : {} # the admin wall's 403 is empty
  end

  test "the naming search's JSON saves: a pick names the card and offers the swap, extra, clear, refusal; viewers get no save" do
    log_in_as users(:alex)
    artist = Artist.create!(slug: "test-athlete-alpha-artist", name: "Test Athlete Alpha", kind: "person", person_slug: @athlete.slug)

    body = save_name(2, artist_slug: artist.slug)
    assert_response :success
    assert_equal({ "kind" => "artist", "slug" => artist.slug, "name" => "Test Athlete Alpha", "avatar_url" => nil,
                   "vocation" => "athlete", "team" => nil }, body["named"])
    assert_equal ["test-athlete-alpha", ["Home Blue", "Away White"]], [body["offer"]["slug"], body["offer"]["looks"].pluck("descriptor")]
    assert_equal "Person 2 is Test Athlete Alpha.", body["message"]
    assert_equal artist.slug, performer(2).artist_slug
    assert_nil performer(2).recast_person_slug, "naming offers the swap, never does it"

    body = save_name(2, extra: "1")
    assert_equal [{ "kind" => "extra" }, nil], body.values_at("named", "offer")
    assert performer(2).extra?

    body = save_name(2, clear: "1")
    assert_equal [nil, nil], body.values_at("named", "offer")
    assert_not performer(2).named?

    body = save_name(2, new_artist_name: "Test Artist E", new_artist_kind: "group")
    assert_equal ["Test Artist E", "group"], body["named"].values_at("name", "vocation")

    assert_no_difference -> { ErrorLog.count } do
      body = save_name(2, nothing: "1")
      assert_response :unprocessable_entity
      assert_equal "Person 2 not updated: choose an artist or person, or name a new artist.", body["error"]
    end

    log_in_as users(:viewer)
    save_name(2, clear: "1")
    assert_response :forbidden
    assert performer(2).named?
  end

  test "a confirmed cast can still be named, and the stored prompts are refreshed with it" do
    log_in_as users(:alex)
    assert @video.cast_confirmed?
    artist = Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person")
    calls = 0
    refresh = MusicVideos::ClipPrompts.method(:refresh!)
    MusicVideos::ClipPrompts.stub(:refresh!, ->(video) { calls += 1; refresh.call(video) }) do
      patch music_video_performer_path(@video, 2), params: { artist_slug: artist.slug }
    end

    assert_equal "Person 2 is Test Artist A.", flash[:notice]
    assert_equal artist.slug, performer(2).artist_slug
    assert_equal 1, calls
  end
end
