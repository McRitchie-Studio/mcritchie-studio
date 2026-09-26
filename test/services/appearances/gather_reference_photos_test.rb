require "test_helper"

# [unit] FILING WHAT A SEARCH FOUND — every candidate, with the verdict on each.
#
# ZERO NETWORK, BY CONSTRUCTION. The search collaborator is injected (`search:`),
# exactly as Appearances::CreateCharacterReference injects its vendor client and for
# the same reason: a real query costs money PER CALL, so the suite must be handed
# something that cannot reach out. `FakeSearch` below holds a literal Answer.
class Appearances::GatherReferencePhotosTest < ActiveSupport::TestCase
  # A SEARCH THAT CANNOT SEARCH. No HTTP, no sockets, no key — it returns whatever
  # Answer it was built with and records what it was asked.
  class FakeSearch
    attr_reader :asked

    def initialize(results: [], unparsed: 0, available: true)
      @answer = Appearances::ImageSearch::Answer.new(
        results: results, unparsed_count: unparsed, provider_name: "fake"
      )
      @available = available
      @asked = []
    end

    def available? = @available
    def provider_name = (@available ? "fake" : nil)

    def search(query:, limit:)
      @asked << [query, limit]
      @answer
    end
  end

  # A CLASSIFIER THAT CANNOT SEE. Injected for exactly the reason the search is:
  # Appearances::FaceVisibility bills per image, so the suite must be handed
  # something that cannot reach the network. It returns whatever scores it was
  # built with and records what it was asked to look at.
  class FakeFaces
    attr_reader :asked

    def initialize(scores = {}, available: true)
      @scores = scores
      @available = available
      @asked = []
    end

    def available? = @available

    def call(urls)
      @asked.concat(urls)
      @scores.slice(*urls)
    end
  end

  # NOTHING LOOKS. The default in most tests below, and the state of every machine
  # with no ANTHROPIC_API_KEY.
  class NoFaces
    def self.available? = false
    def self.call(_urls) = raise("an unavailable classifier must never be asked to look")
  end

  def hit(url, position: 1, **rest)
    Appearances::ImageSearch::Result.new(image_url: url, position: position, **rest)
  end

  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    @person = people(:josh_allen)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  # THE PATH THAT RUNS TODAY. No serper.dev credential exists anywhere, so this is
  # what the operator's first click would do — and it must file nothing, spend
  # nothing and raise nothing.
  test "with no provider configured nothing is searched, filed or raised" do
    search = FakeSearch.new(available: false)

    summary = Appearances::GatherReferencePhotos.call(@look, search: search)

    refute summary.configured?
    assert_equal [], search.asked, "an unavailable provider must not be asked to search"
    assert_equal 0, AppearanceReferencePhoto.count
    assert_equal 0, summary.returned
  end

  # THE REJECTS ARE THE POINT. A gallery of winners cannot distinguish a good search
  # from a bad one, so everything the provider offered is filed with its verdict.
  test "candidates past the cap are FILED as rejects rather than dropped" do
    over = Appearances::GatherReferencePhotos::CHOSEN_LIMIT + 3
    results = (1..over).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }

    summary = Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: results), faces: NoFaces)

    assert_equal over, AppearanceReferencePhoto.count, "every candidate is kept, not just the winners"
    assert_equal Appearances::GatherReferencePhotos::CHOSEN_LIMIT, summary.chosen
    assert_equal 3, summary.rejected
    assert_equal 3, AppearanceReferencePhoto.rejected
                                            .where(rejection_reason: AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT)
                                            .count
  end

  # SSRF. These are URLs a third party handed us and nobody has looked at.
  test "a URL no remote fetcher should follow is refused and filed as unsafe" do
    results = [
      hit("https://cdn.example.com/good.jpg", position: 1),
      hit("http://127.0.0.1/secret.png", position: 2),
      hit("http://169.254.169.254/latest/meta-data", position: 3),
      hit("file:///etc/passwd", position: 4),
      hit("not-a-url", position: 5)
    ]

    summary = Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: results), faces: NoFaces)

    assert_equal 4, summary.unfetchable
    assert_equal 1, summary.chosen
    unsafe = AppearanceReferencePhoto.where(rejection_reason: AppearanceReferencePhoto::REJECTED_UNFETCHABLE)
    assert_equal 4, unsafe.count
    assert unsafe.none?(&:chosen?), "an unsafe URL must never reach the identity"
  end

  # ORDER MATTERS: guard first, cap second. The other way round lets one
  # private-range URL at rank 1 consume a slot and push a good photograph out.
  test "an unsafe hit does not consume one of the chosen slots" do
    results = [hit("http://127.0.0.1/a.png", position: 1)]
    results += (2..(Appearances::GatherReferencePhotos::CHOSEN_LIMIT + 1)).map do |i|
      hit("https://cdn.example.com/#{i}.jpg", position: i)
    end

    summary = Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: results), faces: NoFaces)

    assert_equal Appearances::GatherReferencePhotos::CHOSEN_LIMIT, summary.chosen,
                 "the unsafe hit must not have eaten a slot a good photograph wanted"
  end

  test "the unreadable-row count rides home on the summary" do
    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [hit("https://cdn.example.com/a.jpg")], unparsed: 7),
      faces: NoFaces
    )

    assert_equal 7, summary.unparsed,
                 "a silent zero and a silent parse failure are the same empty list without this"
  end

  # A SEARCH IS RE-JUDGED, NOT DUPLICATED. The unique index makes it safe; this
  # asserts the verdict actually moves rather than the row merely surviving.
  test "re-searching re-judges an existing hit instead of filing a second row" do
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    demoted = "https://cdn.example.com/climber.jpg"

    first = (1..limit).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }
    first << hit(demoted, position: limit + 1)
    Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: first), faces: NoFaces)

    row = AppearanceReferencePhoto.find_by!(image_url: demoted)
    refute row.chosen?
    assert_equal AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT, row.rejection_reason

    # Same photograph, now the provider's top hit.
    second = [hit(demoted, position: 1)]
    second += (1..limit).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i + 1) }
    Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: second), faces: NoFaces)

    assert_equal limit + 1, AppearanceReferencePhoto.count, "no row was duplicated"
    row.reload
    assert row.chosen?, "a hit that climbed to rank 1 must now be chosen"
    assert_nil row.rejection_reason
  end

  # THE TRUST ORDER. `source` is what the operator reads to know whether a human
  # ever looked at a photograph, so a search hit arriving at the same URL must not
  # rewrite the record of where we actually got it.
  test "a search hit never demotes the operator's own photograph" do
    url = "https://cdn.example.com/operator-picked.jpg"
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, image_url: url,
                                     source: AppearanceReferencePhoto::SOURCE_OPERATOR, chosen: true)

    Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: [hit(url)]), faces: NoFaces)

    row = AppearanceReferencePhoto.find_by!(image_url: url)
    assert_equal AppearanceReferencePhoto::SOURCE_OPERATOR, row.source
    assert row.chosen?
  end

  # THE QUERY. The descriptor is deliberately absent — it names how we want the
  # person RENDERED ("navy suit"), which no photograph on the internet is tagged
  # with, so folding it in narrows the search with a useless term.
  test "the query is the person and their team, never the look's descriptor" do
    look = Appearance.create!(person_slug: @person.slug, descriptor: "1994 Ace Ventura")

    query = Appearances::GatherReferencePhotos.new(look).query

    assert_includes query, "Josh Allen"
    refute_includes query, "Ace Ventura"
  end

  test "a person with no team still produces a usable query" do
    carrey = Person.create!(first_name: "Jim", last_name: "Carrey")
    look = Appearance.create!(person_slug: carrey.slug, descriptor: "1994 Ace Ventura")

    assert_equal "Jim Carrey", Appearances::GatherReferencePhotos.new(look).query
  end

  # ---- ranking by face visibility --------------------------------------------
  #
  # THE OPERATOR'S ASK, in his words: "we should prioritize pictures with no helmet
  # so the face has more details." A helmet occludes exactly the features a
  # character identity is built from, and the provider ranks by its own idea of
  # relevance, which says nothing about whether you can see anyone.

  # THE CASE NO METADATA SIGNAL CAN SOLVE, taken from the operator's own labelled
  # example: two photographs of the same person, near-identical portrait ratios,
  # near-identical titles, opposite answers. If this passes on shape or title, the
  # test is measuring the wrong thing — so both candidates are given the SAME
  # metadata and differ only in what the classifier saw.
  test "a bare-faced photo outranks a helmeted one of the same shape and title" do
    helmet = hit("https://cdn.example.com/helmet.jpg", position: 1, width: 686, height: 930,
                 title: "Josh Allen, 18 December 2023")
    bare   = hit("https://cdn.example.com/bare.jpg", position: 2, width: 686, height: 930,
                 title: "Josh Allen, 22 October 2023")
    faces = FakeFaces.new({ helmet.image_url => 0.15, bare.image_url => 0.92 })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [helmet, bare]), faces: faces
    )

    order = Appearances::ReferenceSet.new(@look.reload).persisted_rows.map(&:image_url)
    assert_equal [bare.image_url, helmet.image_url], order,
                 "the bare face must lead even though the helmet was the provider's hit 1"
  end

  # PRIORITISE, NOT EXCLUDE. On a real Commons answer for "Drew Lock" exactly ONE
  # of twenty hits was bare-faced; a threshold that dropped the helmets would have
  # left the identity with a single photograph.
  test "helmeted photos are still chosen when there is nothing better" do
    helmets = (1..3).map { |i| hit("https://cdn.example.com/h#{i}.jpg", position: i) }
    faces = FakeFaces.new(helmets.to_h { |h| [h.image_url, 0.15] })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: helmets), faces: faces
    )

    assert_equal 3, summary.chosen, "a person with only helmeted photos still gets an identity"
  end

  # THE BUG THIS RULE WAS WRITTEN FROM. Measured on a real Commons answer for
  # "Drew Lock": 12 of 20 hits were scanned books, and with a blind take-the-top-N
  # a 1896 edition of The Rape of the Lock was selected INTO the character model.
  test "a scanned document is never chosen, however thin the answer" do
    scan = hit("https://cdn.example.com/page1-500px-book.pdf.jpg", position: 1,
               title: "The Rape of the Lock, 1896", page_url: "https://x.test/book.pdf")
    photo = hit("https://cdn.example.com/player.jpg", position: 2)
    faces = FakeFaces.new({ photo.image_url => 0.9 })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [scan, photo]), faces: faces
    )

    assert_equal 1, summary.chosen
    row = AppearanceReferencePhoto.find_by!(image_url: scan.image_url)
    refute row.chosen?
    assert_equal AppearanceReferencePhoto::REJECTED_NOT_A_PHOTO, row.rejection_reason
  end

  # A DOCUMENT IS NEVER PAID FOR. It can never be chosen, so classifying it buys an
  # answer we would not act on — and on a real answer that was 12 of 20 images,
  # taking the classifier's shortlist from 12 images down to 8.
  test "documents are never sent to the classifier" do
    scan = hit("https://cdn.example.com/page1-500px-book.pdf.jpg", position: 1)
    photo = hit("https://cdn.example.com/player.jpg", position: 2)
    faces = FakeFaces.new({ photo.image_url => 0.9 })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [scan, photo]), faces: faces
    )

    assert_equal [photo.image_url], faces.asked
  end

  # A DISQUALIFIED CANDIDATE MUST NOT EAT A SLOT on its way to being rejected, or a
  # thin answer full of scanned pages leaves the identity smaller than its supply.
  test "a rejected document does not consume one of the chosen slots" do
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    scans = (1..3).map { |i| hit("https://cdn.example.com/page1-#{i}.pdf.jpg", position: i) }
    photos = (1..limit).map { |i| hit("https://cdn.example.com/p#{i}.jpg", position: i + 3) }
    faces = FakeFaces.new(photos.to_h { |p| [p.image_url, 0.8] })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: scans + photos), faces: faces
    )

    assert_equal limit, summary.chosen
  end

  # `face_obscured` IS A JUDGEMENT, so it is stamped only where something judged.
  test "a loser nothing looked at is beyond_limit, never face_obscured" do
    results = (1..(Appearances::GatherReferencePhotos::CHOSEN_LIMIT + 2)).map do |i|
      hit("https://cdn.example.com/#{i}.jpg", position: i)
    end

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: NoFaces
    )

    reasons = AppearanceReferencePhoto.rejected.pluck(:rejection_reason).uniq
    assert_equal [AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT], reasons,
                 "with no classifier configured nothing may be labelled face_obscured"
  end

  test "a loser the classifier judged obscured is labelled as such" do
    keep = (1..Appearances::GatherReferencePhotos::CHOSEN_LIMIT).map do |i|
      hit("https://cdn.example.com/k#{i}.jpg", position: i)
    end
    loser = hit("https://cdn.example.com/helmet.jpg", position: 99)
    scores = keep.to_h { |k| [k.image_url, 0.9] }.merge(loser.image_url => 0.15)

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: keep + [loser]), faces: FakeFaces.new(scores)
    )

    row = AppearanceReferencePhoto.find_by!(image_url: loser.image_url)
    assert_equal AppearanceReferencePhoto::REJECTED_FACE_OBSCURED, row.rejection_reason
  end

  # COST CEILING. The bill must scale with our constant, not with whatever the
  # provider felt like returning.
  test "no more than VISION_SHORTLIST images are ever paid to be classified" do
    results = (1..40).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }
    faces = FakeFaces.new({})

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: faces
    )

    assert_equal Appearances::GatherReferencePhotos::VISION_SHORTLIST, faces.asked.length
  end

  # THE DEGRADE. An unconfigured or broken classifier must cost the operator a
  # better ORDER, never the search itself.
  test "a classifier that returns nothing falls back to the free ranking" do
    results = (1..3).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: FakeFaces.new({})
    )

    assert_equal 3, summary.chosen
    refute summary.ranked_by_face?
    assert AppearanceReferencePhoto.where.not(face_score: nil).none?,
           "an unscored row must stay NULL - nobody looked is not a score of zero"
  end

  test "the summary names what did the ordering" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)

    scored = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]),
      faces: FakeFaces.new({ photo.image_url => 0.9 })
    )
    assert scored.ranked_by_face?
    assert_equal 1, scored.scored
  end

  # A RE-SEARCH MUST NOT ERASE A JUDGEMENT WE PAID FOR. Turning "we looked in
  # March" into "nobody has ever looked" would re-sort the gallery on an absence we
  # created ourselves.
  test "a later search with no classifier keeps the score an earlier one bought" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)
    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]),
      faces: FakeFaces.new({ photo.image_url => 0.77 })
    )
    assert_in_delta 0.77, AppearanceReferencePhoto.find_by!(image_url: photo.image_url).face_score, 0.001

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]), faces: NoFaces
    )

    assert_in_delta 0.77, AppearanceReferencePhoto.find_by!(image_url: photo.image_url).face_score, 0.001
  end

  test "the provider is asked for the query the summary reports" do
    search = FakeSearch.new(results: [])
    summary = Appearances::GatherReferencePhotos.call(@look, search: search, faces: NoFaces, limit: 11)

    assert_equal [[summary.query, 11]], search.asked
  end
end
