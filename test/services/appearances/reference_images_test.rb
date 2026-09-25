require "test_helper"

# [unit] WHICH PHOTOGRAPHS A CHARACTER IDENTITY IS BUILT FROM.
#
# The floor that needs no new credential: the ESPN headshot Nflverse::SeedPlayers
# already mirrored into our own S3. One image satisfies the API's minimum of 1,
# so the lane works today; an image-search step will add the profile and the
# expressions later by replacing this object, which is the whole reason it is a
# separate object.
#
# Nothing here reaches S3 or the network — ImageCache#url is pure string
# building over a configured bucket name.
class Appearances::ReferenceImagesTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  def cache_headshot(variant:, key:)
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: variant,
                       s3_key: key, content_type: "image/png")
  end

  test "the cached headshot is the floor a person with no other photos stands on" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")

    urls = Appearances::ReferenceImages.call(@look.reload)

    assert_equal 1, urls.length, "one image is the API's minimum, so one is enough to build on"
    assert_includes urls.first, "headshots/nfl/buffalo-bills/josh-allen/400.png"
    assert urls.first.start_with?("https://"), "Higgsfield fetches this server-side"
  end

  # A 100px crop of a face carries less of it than a 400px one, and the identity
  # is built from what the model can see.
  test "the widest cached variant wins when both are on file" do
    cache_headshot(variant: "100", key: "headshots/nfl/buffalo-bills/josh-allen/100.png")
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")

    urls = Appearances::ReferenceImages.call(@look.reload)

    assert_equal 1, urls.length
    assert_includes urls.first, "/400.png"
  end

  test "a narrower variant is still used when the wide one was never cached" do
    cache_headshot(variant: "100", key: "headshots/nfl/buffalo-bills/josh-allen/100.png")

    urls = Appearances::ReferenceImages.call(@look.reload)

    assert_equal 1, urls.length
    assert_includes urls.first, "/100.png"
  end

  # `appearances.reference_url` has been written by the look form since the
  # column was created and read by NOTHING. This is its first reader.
  test "the operator's reference photo joins the identity" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    @look.update!(reference_url: "https://example.com/josh-allen-profile.jpg")

    urls = Appearances::ReferenceImages.call(@look.reload)

    assert_equal 2, urls.length
    assert_includes urls, "https://example.com/josh-allen-profile.jpg"
  end

  # The measured URL leads: the headshot is the one whose public reachability we
  # control, while reference_url is free text that could point anywhere.
  test "the headshot leads the list and the operator's URL follows" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    @look.update!(reference_url: "https://example.com/profile.jpg")

    urls = Appearances::ReferenceImages.call(@look.reload)

    assert_includes urls.first, "/400.png"
    assert_equal "https://example.com/profile.jpg", urls.last
  end

  test "a person with no photographs at all yields an empty list, not a broken URL" do
    assert_equal [], Appearances::ReferenceImages.call(@look.reload)
  end

  test "a person with no athlete record falls back to their operator URL alone" do
    carrey = Person.create!(first_name: "Jim", last_name: "Carrey")
    look = Appearance.create!(person_slug: carrey.slug, descriptor: "1994 Ace Ventura",
                              reference_url: "https://example.com/ace.jpg")

    assert_equal ["https://example.com/ace.jpg"], Appearances::ReferenceImages.call(look)
  end

  # Asking a remote fetcher to pull from our loopback is a request to probe our
  # own network, and a relative URL is a paid 422 (url_parsing).
  test "a URL no remote fetcher could or should follow is dropped" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")

    ["http://localhost:3000/secret.png", "http://127.0.0.1/x.png", "not-a-url",
     "file:///etc/passwd", "http://169.254.169.254/latest/meta-data"].each do |bad|
      @look.update!(reference_url: bad)
      urls = Appearances::ReferenceImages.call(@look.reload)

      assert_equal 1, urls.length, "#{bad} must not reach the vendor"
      assert_includes urls.first, "/400.png", "the good URL must survive its bad neighbour"
    end
  end

  test "the same URL recorded twice is offered once" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    @look.update!(reference_url: @athlete.reload.headshot_url(width: 400))

    assert_equal 1, Appearances::ReferenceImages.call(@look.reload).length
  end

  # THE SEAM ITSELF. A replacement supplies more photographs without any other
  # part of the lane moving — this is the contract the image-search step will
  # implement.
  test "the contract a replacement implements is one call returning URLs" do
    assert_respond_to Appearances::ReferenceImages, :call
    assert_equal 1, Appearances::ReferenceImages.method(:call).arity
  end
end
