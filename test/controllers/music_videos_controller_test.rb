# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s

# [integration] The cast panel round trip: admin gate, the page, labelling each
# way (artist, person, new artist, extra, clear), the typeahead endpoint, and the
# Cast confirmed button that refuses while anyone is unlabelled. Every label is a
# synthetic test artist: only the operator maps an on-screen person to a real one.
class MusicVideosControllerTest < ActionDispatch::IntegrationTest
  setup do
    @video = NightCallCast.seed!
    @artist = Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person")
    ArtistAlias.create!(artist: @artist, name: "Test Alias A")
  end

  def label(ordinal, **params) = patch music_video_performer_path(@video, ordinal), params: params

  test "visitors are sent to log in and non-admins are refused" do
    get music_video_path(@video)
    assert_redirected_to "/login"

    log_in_as users(:viewer)
    get music_video_path(@video)
    assert_redirected_to root_path
    label(1, extra: "1")
    assert_not @video.video_performers.find_by!(ordinal: 1).extra?
    get search_artists_path(format: :json, q: "test")
    assert_response :forbidden
  end

  test "the page shows credits, unresolved credits, seven unnamed cards and Cast confirmed ready to press" do
    log_in_as users(:alex)
    get music_video_path(@video)

    assert_response :success
    assert_select "[data-test='credited-artist']", 2
    assert_select "[data-test='unresolved-credit']", /Steve Aoki/
    assert_select "[data-test='performer-card']", 7
    assert_select "[data-test='performer-still'] img[src*='person_01_0230.jpg'][src*='X-Amz-Signature']"
    assert_select "[data-test='cast-swap-count']", "0 of 7"
    assert_select "[data-test='cast-named-count']", /\ANobody named\. Naming is optional: it builds the artist rolodex\.\z/
    assert_select "[data-test='performer-badge']", text: "Not named", count: 7
    assert_select "[data-test='confirm-cast-form'] button:not([disabled])", "Cast confirmed"
  end

  test "Cast confirmed needs no names: with everyone unnamed it advances the stage" do
    log_in_as users(:alex)

    post confirm_cast_music_video_path(@video)
    assert_redirected_to music_video_path(@video)
    assert_equal "Cast confirmed.", flash[:notice]
    assert_equal "cast_confirmed", @video.reload.stage
    assert(@video.video_performers.all? { |p| p.artist_slug.nil? && !p.extra? })
  end

  test "Cast confirmed refuses a video with no performers yet" do
    log_in_as users(:alex)
    @video.video_performers.delete_all

    post confirm_cast_music_video_path(@video)
    assert_equal "Not yet: no performers yet: the vision pass has not posted any.", flash[:alert]
    assert_equal "digested", @video.reload.stage
  end

  test "labelling some, with extras, still confirms, which advances the stage" do
    log_in_as users(:alex)
    label(1, artist_slug: @artist.slug)
    (2..7).each { |n| label(n, extra: "1") }
    get music_video_path(@video)
    assert_select "[data-test='confirm-cast-form'] button:not([disabled])"

    post confirm_cast_music_video_path(@video)
    assert_equal "Cast confirmed.", flash[:notice]
    assert_equal "cast_confirmed", @video.reload.stage

    # Naming stays editable after the confirm (it is optional, and Change is always offered).
    label(1, clear: "1")
    assert_nil @video.video_performers.find_by!(ordinal: 1).artist_slug
    assert_equal "Person 1 cleared.", flash[:notice]
  end

  test "picking a person from People makes them an artist, once" do
    person = Person.create!(slug: "test-person-a", first_name: "Test", last_name: "Person A")
    log_in_as users(:alex)

    assert_difference -> { Artist.count } => 1 do
      label(1, person_slug: person.slug)
      label(2, person_slug: person.slug)
    end
    artist = Artist.find_by!(person_slug: person.slug)
    assert_equal ["Test Person A", "person"], [artist.name, artist.kind]
    assert_equal [artist.slug] * 2, @video.video_performers.where(ordinal: [1, 2]).pluck(:artist_slug)
    assert_equal "Person 2 is Test Person A.", flash[:notice]
  end

  test "creating a new artist inline links it" do
    log_in_as users(:alex)
    label(1, new_artist_name: "  Test   Artist B ", new_artist_kind: "person")

    artist = Artist.find_by!(name: "Test Artist B")
    assert_equal "test-artist-b", artist.slug
    assert_equal artist.slug, @video.video_performers.find_by!(ordinal: 1).artist_slug
    assert_redirected_to music_video_path(@video, anchor: "person-1")
  end

  test "an extra can be cleared back to unnamed, and an empty answer is refused" do
    log_in_as users(:alex)
    label(3, extra: "1")
    assert @video.video_performers.find_by!(ordinal: 3).extra?
    get music_video_path(@video)
    assert_select "[data-test='cast-named-count']", /Nobody named \(1 marked extras\)/

    label(3, clear: "1")
    assert_not @video.video_performers.find_by!(ordinal: 3).extra?
    assert_not @video.video_performers.find_by!(ordinal: 3).named?

    label(3, artist_slug: "")
    assert_match "choose an artist", flash[:alert]
  end

  test "the typeahead endpoint answers top matches with kind and hint" do
    log_in_as users(:alex)
    get search_artists_path(format: :json, q: "test alias a")

    assert_response :success
    first = JSON.parse(response.body).first
    assert_equal({ "type" => "artist", "slug" => @artist.slug, "name" => "Test Artist A", "kind" => "person",
                   "hint" => "aka Test Alias A", "avatar_url" => nil, "vocation" => "musician", "team" => nil }, first)
  end

  # Synthetic people: the typeahead's rows carry a headshot, a vocation and a team.
  test "the typeahead endpoint returns avatar, vocation and team per row" do
    log_in_as users(:alex)
    team = Team.create!(slug: "test-city-testers", name: "Test City Testers")
    rostered = Person.create!(first_name: "Test", last_name: "Rowfinder Athlete", athlete: true)
    profile = Athlete.create!(person_slug: rostered.slug, sport: "football", team_slug: team.slug)
    cache = ImageCache.create!(owner: profile, purpose: "headshot", variant: "100", content_type: "image/png",
                               s3_key: "headshots/nfl/test-city-testers/#{rostered.slug}/100.png")
    Person.create!(first_name: "Test", last_name: "Rowfinder Plain", avatar_url: "https://img.example/plain.png")
    Artist.create!(slug: "test-rowfinder-band", name: "Test Rowfinder Band", kind: "group")

    get search_artists_path(format: :json, q: "test rowfinder")

    assert_response :success
    rows = JSON.parse(response.body).index_by { |r| r["slug"] }
    assert_not rows.key?(rostered.slug), "an athlete is offered in the swap search, not as the person on screen"
    assert_equal [cache.url, "athlete", "Test City Testers"],
                 People::SearchRows.for([rostered.slug]).fetch(rostered.slug).to_h.values_at(:avatar_url, :vocation, :team)
    assert_equal ["https://img.example/plain.png", nil, nil],
                 rows.fetch("test-rowfinder-plain").values_at("avatar_url", "vocation", "team")
    assert_equal [nil, "group", nil], rows.fetch("test-rowfinder-band").values_at("avatar_url", "vocation", "team")
    assert_equal %w[avatar_url hint kind name slug team type vocation], rows.values.first.keys.sort
  end
end
