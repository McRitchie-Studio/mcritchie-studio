require "test_helper"

# [unit] THE COMPOSED PHOTOGRAPH LIST — the floor plus the chosen search hits, and
# the gallery that shows both halves.
#
# THIS IS THE SEAM. Appearances::CreateCharacterReference takes its list as an
# injected `references:` collaborator, so this object is how the search reaches the
# identity WITHOUT the mint service changing. The contract it implements is the one
# Appearances::ReferenceImages documents, and the last test here asserts the two are
# interchangeable — which is the property the whole design rests on.
#
# Nothing here reaches S3 or the network: ImageCache#url is pure string building.
class Appearances::ReferenceSetTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  def cache_headshot(key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "400",
                       s3_key: key, content_type: "image/png")
  end

  def file(url, chosen: true, **rest)
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, image_url: url,
                                     source: AppearanceReferencePhoto::SOURCE_SEARCH,
                                     chosen: chosen, **rest)
  end

  # THE FLOOR IS UNCHANGED WHEN NOTHING HAS BEEN SEARCHED, which is what makes this
  # safe to inject everywhere: a look nobody has run a search for behaves exactly as
  # it did before this object existed.
  test "with no search hits the set is exactly the floor" do
    cache_headshot
    @look.update!(reference_url: "https://example.com/operator.jpg")

    assert_equal Appearances::ReferenceImages.call(@look.reload),
                 Appearances::ReferenceSet.call(@look.reload)
  end

  # THE MEASURED URL STILL LEADS. The headshot is the one whose public reachability
  # we control; a search hit is one nobody has ever looked at. Concatenating the
  # other way round would have quietly destroyed a deliberate property of the floor.
  test "the floor leads and the chosen search hits follow" do
    cache_headshot
    @look.update!(reference_url: "https://example.com/operator.jpg")
    file("https://cdn.example.com/found.jpg")

    urls = Appearances::ReferenceSet.call(@look.reload)

    assert_includes urls.first, "/400.png"
    assert_equal "https://cdn.example.com/found.jpg", urls.last
    assert_equal 3, urls.length
  end

  test "a rejected search hit never reaches the identity" do
    cache_headshot
    file("https://cdn.example.com/chosen.jpg", chosen: true)
    file("https://cdn.example.com/rejected.jpg", chosen: false,
         rejection_reason: AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT)

    urls = Appearances::ReferenceSet.call(@look.reload)

    assert_includes urls, "https://cdn.example.com/chosen.jpg"
    refute_includes urls, "https://cdn.example.com/rejected.jpg"
  end

  # ROWS OUTLIVE THE RULE THAT JUDGED THEM. GatherReferencePhotos refused the unsafe
  # ones at file time, but a tightening of the engine's SSRF ranges would otherwise
  # apply only to photographs found AFTER the change — and an old row would keep
  # being handed to a remote fetcher under a rule nobody holds any more. So the
  # check runs again here, immediately before we spend money.
  test "a chosen row that would fail today's guard is still refused today" do
    cache_headshot
    # Written straight to the table, as a row filed under an older, looser rule.
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug,
                                     image_url: "http://127.0.0.1/legacy.png",
                                     source: AppearanceReferencePhoto::SOURCE_SEARCH, chosen: true)

    urls = Appearances::ReferenceSet.call(@look.reload)

    refute_includes urls, "http://127.0.0.1/legacy.png"
    assert_equal 1, urls.length
  end

  test "the same URL from the floor and from a search is offered once" do
    cache_headshot
    @look.update!(reference_url: "https://example.com/same.jpg")
    file("https://example.com/same.jpg")

    urls = Appearances::ReferenceSet.call(@look.reload)

    assert_equal urls.uniq, urls
    assert_equal 2, urls.length
  end

  # THE GALLERY. One list, chosen first, with the floor rendered through the same
  # partial as the search hits so the page cannot drift from the identity's list.
  test "the gallery carries the floor as unsaved rows beside the persisted hits" do
    cache_headshot
    @look.update!(reference_url: "https://example.com/operator.jpg")
    file("https://cdn.example.com/found.jpg", position: 1)
    file("https://cdn.example.com/passed.jpg", chosen: false, position: 2,
         rejection_reason: AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT)

    gallery = Appearances::ReferenceSet.new(@look.reload).gallery

    assert_equal 4, gallery.length
    sources = gallery.map(&:source)
    assert_includes sources, AppearanceReferencePhoto::SOURCE_HEADSHOT
    assert_includes sources, AppearanceReferencePhoto::SOURCE_OPERATOR
    assert_includes sources, AppearanceReferencePhoto::SOURCE_SEARCH

    floor = gallery.reject(&:persisted?)
    assert_equal 2, floor.length, "the floor is derived, never written on a page view"
    assert floor.all?(&:chosen?)
  end

  test "the gallery labels the operator's own URL as theirs, not as a headshot" do
    cache_headshot
    @look.update!(reference_url: "https://example.com/operator.jpg")

    gallery = Appearances::ReferenceSet.new(@look.reload).gallery
    operator = gallery.find { |p| p.image_url == "https://example.com/operator.jpg" }

    assert_equal AppearanceReferencePhoto::SOURCE_OPERATOR, operator.source
  end

  # THE COUNTS ON THE PAGE MUST AGREE. A search routinely re-finds the URL the
  # operator already typed, and before this the gallery rendered that photograph
  # TWICE — once as the floor, once as a search hit — so the page read
  # "IN THE MODEL (6)" beside an identity "BUILT FROM 5 photos". Two counts of one
  # thing, on one screen, disagreeing.
  test "a search hit that duplicates the floor renders once, not twice" do
    cache_headshot
    url = "https://example.com/operator.jpg"
    @look.update!(reference_url: url)
    file(url)

    gallery = Appearances::ReferenceSet.new(@look.reload).gallery

    assert_equal 1, gallery.count { |p| p.image_url == url }
    assert_equal gallery.count(&:chosen?), Appearances::ReferenceSet.call(@look).length,
                 "the gallery's chosen count IS the number of photos the identity gets"
  end

  # THE FLOOR WINS THE COLLAPSE, because the chip is the more trustworthy claim:
  # "you added this" is a fact about a human.
  test "the surviving row of a duplicate is the floor's, not the search's" do
    cache_headshot
    url = "https://example.com/operator.jpg"
    @look.update!(reference_url: url)
    file(url)

    row = Appearances::ReferenceSet.new(@look.reload).gallery.find { |p| p.image_url == url }

    assert_equal AppearanceReferencePhoto::SOURCE_OPERATOR, row.source
  end

  test "the gallery puts the chosen photographs first" do
    cache_headshot
    file("https://cdn.example.com/passed.jpg", chosen: false, position: 1,
         rejection_reason: AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT)
    file("https://cdn.example.com/kept.jpg", chosen: true, position: 2)

    gallery = Appearances::ReferenceSet.new(@look.reload).gallery
    chosen_flags = gallery.map(&:chosen?)

    assert_equal chosen_flags.sort { |a, b| (b ? 1 : 0) <=> (a ? 1 : 0) }, chosen_flags
    refute gallery.last.chosen?
  end

  test "a look with nothing at all yields an empty set and an empty gallery" do
    assert_equal [], Appearances::ReferenceSet.call(@look)
    assert_equal [], Appearances::ReferenceSet.new(@look).gallery
  end

  # THE SEAM ITSELF. This object is substitutable for the one
  # Appearances::CreateCharacterReference defaults to, which is the entire reason
  # the search needed no change to the mint path.
  test "it implements the same one-call contract as the floor it replaces" do
    assert_respond_to Appearances::ReferenceSet, :call
    assert_equal Appearances::ReferenceImages.method(:call).arity,
                 Appearances::ReferenceSet.method(:call).arity
  end

  test "the mint service accepts it as its references collaborator" do
    cache_headshot
    file("https://cdn.example.com/found.jpg")

    # A client that would raise if touched: this asserts WHICH LIST the service
    # would spend on, without spending.
    spy = Object.new
    def spy.create_custom_reference(name:, image_urls:)
      @image_urls = image_urls
      "11111111-2222-3333-4444-555555555555"
    end
    def spy.image_urls = @image_urls

    Appearances::CreateCharacterReference
      .new(@look.reload, client: spy, references: Appearances::ReferenceSet).call

    assert_includes spy.image_urls, "https://cdn.example.com/found.jpg"
    assert_includes spy.image_urls.first, "/400.png", "the measured URL still leads the list"
  end
end
