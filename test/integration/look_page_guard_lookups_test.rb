require "test_helper"
require_relative "../support/url_guard_world"

# [integration] THE LOOK PAGE, ON AN ENGINE WHOSE URL GUARD LOOKS NAMES UP.
#
# appearances#show re-judges every chosen reference by today's rules, through
# several readers (the trainer's list, the gallery, the build plan, the anchor).
# On the next engine each judgement is a DNS lookup of up to six seconds, so the
# page asks once per distinct host and stops at a budget
# (/tasks/url-guard-off-hot-paths). No DNS and no HTTP here: the guard is a
# stand-in (test/support/url_guard_world.rb).
class LookPageGuardLookupsTest < ActionDispatch::IntegrationTest
  include UrlGuardWorld

  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "original",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/original.png", content_type: "image/png")
    @headshot_host = URI.parse(@athlete.headshot_url(width: "original")).host
  end

  def reference(url)
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, image_url: url, chosen: true,
                                     source: AppearanceReferencePhoto::SOURCE_SEARCH,
                                     face_score: 0.9, face_fill: 0.9, face_subjects: 1)
  end

  def show! = get(person_appearance_path(@person.slug, @look.slug))

  test "a look with eight chosen references makes one lookup per distinct host" do
    5.times { |i| reference("https://cdn.example.com/a#{i}.jpg") }
    3.times { |i| reference("https://photos.example.org/b#{i}.jpg") }
    log_in_as users(:alex)

    with_url_guard do |lookups|
      show!
      assert_response :success
      assert_equal [@headshot_host, "cdn.example.com", "photos.example.org"].sort, lookups.sort
    end
  end

  test "the next request looks the hosts up again: nothing is remembered across requests" do
    reference("https://cdn.example.com/a.jpg")
    log_in_as users(:alex)

    with_url_guard do |lookups|
      show!
      first = lookups.count("cdn.example.com")
      show!
      assert_equal [1, 2], [first, lookups.count("cdn.example.com")]
    end
  end

  test "a reference whose host could not be looked up is left out, logged, and the page says so" do
    reference("https://cdn.example.com/a.jpg")
    2.times { |i| reference("https://dead.example.com/b#{i}.jpg?sig=secret") }
    log_in_as users(:alex)

    warned = []
    Rails.logger.stub(:warn, ->(message = nil, &blk) { warned << (message || blk&.call).to_s }) do
      with_url_guard(unresolved: %w[dead.example.com]) do |lookups|
        show!
        assert_equal 1, lookups.count("dead.example.com")
      end
    end

    assert_response :success
    assert_match(/could not be looked up/, flash[:alert].to_s)
    assert_match(/dead\.example\.com/, flash[:alert].to_s)
    lines = warned.grep(/\[fetchable_url\]/)
    assert_equal 1, lines.size, lines.inspect
    assert_match(/chosen reference left out of look #{@look.slug}: host dead\.example\.com/, lines.first)
    assert_no_match(/secret/, lines.first + flash[:alert].to_s)
  end

  test "dead names stop at the request's budget instead of crossing the router's limit" do
    hosts = (1..8).map { |i| "slow#{i}.example.com" }
    hosts.each { |host| reference("https://#{host}/a.jpg") }
    log_in_as users(:alex)

    with_guard_clock do
      with_url_guard(unresolved: hosts, slow: hosts.index_with { 6 }) do |lookups|
        show!
        assert_response :success
        slow = lookups.grep(/\Aslow/)
        assert_equal 2, slow.size, "two six-second failures cross the ten-second budget; the other six are not asked"
      end
    end
  end
end
