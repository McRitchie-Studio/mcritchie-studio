require "test_helper"

# [unit] THE COMPOSED PHOTOGRAPH LISTS — the floor plus the chosen search hits, one
# list per generator, and the gallery that shows both halves.
#
# TWO LISTS AND THEY ARE DIFFERENT ON PURPOSE. `#generation_urls` feeds the zero-shot
# sheet, which has no preparation stage and therefore nothing that can refuse a weak
# reference; `#call` feeds Higgsfield's TRAINER, which refused four of six measured
# mints, so it additionally demands a MEASURED face size. Half the cases below exist to
# hold that difference in place, because collapsing them is the easy mistake in either
# direction: one way starves the sheet the operator asked for, the other gambles a
# training purchase on photographs nobody measured.
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

  # A ROW SOMETHING ACTUALLY MEASURED — the precondition for reaching the TRAINER.
  # Spelled out in a helper because "a chosen row" and "a chosen row a classifier
  # measured" are now different states, and a case that means the second and writes the
  # first is asserting the old rule.
  def file_measured(url, fill: 0.9, visibility: 0.9, **rest)
    file(url, face_score: visibility, face_fill: fill, face_subjects: 1, **rest)
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
    file_measured("https://cdn.example.com/found.jpg")

    urls = Appearances::ReferenceSet.call(@look.reload)

    assert_includes urls.first, "/400.png"
    assert_equal "https://cdn.example.com/found.jpg", urls.last
    assert_equal 3, urls.length
  end

  # THE ZERO-SHOT SHEET'S LIST, and the operator's own request of 2026-09-27: "it would
  # be better if we provided a few headshots ... more context on facial structure and
  # expressions". The headshot leads and the vetted search hits follow it.
  test "the sheet list leads with the headshot and carries the scouted photos after it" do
    cache_headshot
    file("https://cdn.example.com/found.jpg", position: 1)
    file("https://cdn.example.com/second.jpg", position: 2)

    urls = Appearances::ReferenceSet.new(@look.reload).generation_urls

    assert_includes urls.first, "/400.png", "the one input measured to mint still leads"
    assert_includes urls, "https://cdn.example.com/found.jpg"
    assert_includes urls, "https://cdn.example.com/second.jpg"
  end

  # THE DIFFERENCE BETWEEN THE TWO LISTS, in one case: the SAME row reaches the sheet and
  # not the trainer, because nobody measured how much of the frame its face fills — the
  # variable four of six measured mints turned on (2026-09-25).
  test "a photograph nobody measured reaches the sheet and not the trainer" do
    cache_headshot
    file("https://cdn.example.com/unmeasured.jpg")

    set = Appearances::ReferenceSet.new(@look.reload)

    assert_includes set.generation_urls, "https://cdn.example.com/unmeasured.jpg"
    refute_includes set.call, "https://cdn.example.com/unmeasured.jpg"
    assert_equal 1, set.call.length, "the trainer is left with the proven headshot"
  end

  # A MEASURED FACE THAT IS TOO SMALL IS REFUSED BY BOTH, because that is a judgement of
  # the photograph rather than an absence of one.
  test "a measured tiny face is refused by the sheet as well as the trainer" do
    cache_headshot
    file_measured("https://cdn.example.com/distant.jpg", fill: 0.1)

    set = Appearances::ReferenceSet.new(@look.reload)

    refute_includes set.generation_urls, "https://cdn.example.com/distant.jpg"
    refute_includes set.call, "https://cdn.example.com/distant.jpg"
  end

  # NEVER MINT AN IDENTITY FROM MIXED SUBJECTS — through the free half of the rule, so it
  # holds on a row nothing ever classified. The row is written as CHOSEN, exactly as a
  # search run before this rule existed would have left it.
  # THE STRANGER IS `Keenan Allen` RATHER THAN THE MEASURED `Drew Hutton`, because this
  # fixture's person is Josh Allen and the rule fires on a name CONFLICT: a title that
  # shares one of our person's name words and differs on another. "Drew Hutton" shares
  # nothing with "Josh Allen" and is correctly :unknown to the check — which is the
  # documented limit of Appearances::PersonNaming, not a gap in this case.
  test "a chosen photograph of a DIFFERENT man reaches neither generator" do
    cache_headshot
    file("https://cdn.example.com/keenan.jpg", title: "Keenan Allen.jpg")
    file_measured("https://cdn.example.com/allen.jpg", title: "Josh Allen warming up")

    set = Appearances::ReferenceSet.new(@look.reload)

    refute_includes set.generation_urls, "https://cdn.example.com/keenan.jpg",
                    "a stranger in a sheet's references is a blended face"
    refute_includes set.call, "https://cdn.example.com/keenan.jpg"
    assert_includes set.generation_urls, "https://cdn.example.com/allen.jpg"
  end

  # THE CLASSIFIER SAW TWO FACES, so nothing in the picture can be attributed to our man.
  test "a chosen photograph with two visible faces reaches neither generator" do
    cache_headshot
    file_measured("https://cdn.example.com/pair.jpg", face_subjects: 2)

    set = Appearances::ReferenceSet.new(@look.reload)

    refute_includes set.generation_urls, "https://cdn.example.com/pair.jpg"
    refute_includes set.call, "https://cdn.example.com/pair.jpg"
  end

  # ROWS OUTLIVE THE RULE THAT JUDGED THEM, and the page has to be able to say so rather
  # than showing "in the model" over an identity built from something else.
  test "chosen rows the trainer now refuses are reported rather than silently dropped" do
    cache_headshot
    file("https://cdn.example.com/legacy.jpg")

    refused = Appearances::ReferenceSet.new(@look.reload).refused_rows

    assert_equal ["https://cdn.example.com/legacy.jpg"], refused.map(&:image_url)
    assert_equal AppearanceReferencePhoto::REJECTED_FACE_SIZE_UNMEASURED,
                 refused.first.mint_verdict(@person.full_name).to_s,
                 "the reason is the one the helper prints, not a second spelling of it"
  end

  # THE VENDOR THAT FETCHES THE BYTES ITSELF GETS OUR OWN COPY. Wikimedia answers 403 to
  # a request with no User-Agent (measured 2026-09-26 when Anthropic's fetcher was
  # refused), and ImageGeneration::OpenAI downloads every reference itself — so handing it
  # a Commons URL costs the whole sheet.
  test "the sheet list hands over our mirrored copy when we took one" do
    cache_headshot
    photo = file("https://upload.wikimedia.org/commons/x.jpg")
    ImageCache.create!(owner: photo, purpose: Appearances::MirrorCandidates::PURPOSE,
                       variant: "original", s3_key: "reference-photos/x/original.jpg",
                       content_type: "image/jpeg")

    urls = Appearances::ReferenceSet.new(@look.reload).generation_urls

    refute_includes urls, "https://upload.wikimedia.org/commons/x.jpg"
    assert urls.any? { |url| url.include?("reference-photos/x/original.jpg") },
           "our own S3 copy is the one a fetcher of ours can be relied on to read"
  end

  # THE SHEET'S CAP IS OURS AND IT IS NOT A VENDOR LIMIT. Every reference is bytes in one
  # request body plus another image to reason over.
  test "the sheet list is capped" do
    cache_headshot
    (1..8).each { |i| file("https://cdn.example.com/#{i}.jpg", position: i) }

    urls = Appearances::ReferenceSet.new(@look.reload).generation_urls

    assert_equal Appearances::ReferenceSet::GENERATION_LIMIT, urls.length
    assert_includes urls.first, "/400.png", "the cap must not cost us the one proven input"
  end

  test "a rejected search hit never reaches the identity" do
    cache_headshot
    file_measured("https://cdn.example.com/chosen.jpg", chosen: true)
    file("https://cdn.example.com/rejected.jpg", chosen: false,
         rejection_reason: AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT)

    set = Appearances::ReferenceSet.new(@look.reload)

    assert_includes set.call, "https://cdn.example.com/chosen.jpg"
    refute_includes set.call, "https://cdn.example.com/rejected.jpg"
    refute_includes set.generation_urls, "https://cdn.example.com/rejected.jpg",
                    "a reject is a reject on both paths — only the ELIGIBLE rule differs"
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
    assert_equal gallery.count(&:chosen?),
                 Appearances::ReferenceSet.new(@look).generation_urls.length,
                 "the gallery's chosen count IS the number of photos the sheet is given"
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
    file_measured("https://cdn.example.com/found.jpg")

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
