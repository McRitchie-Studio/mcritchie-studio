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

    summary = Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: results))

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

    summary = Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: results))

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

    summary = Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: results))

    assert_equal Appearances::GatherReferencePhotos::CHOSEN_LIMIT, summary.chosen,
                 "the unsafe hit must not have eaten a slot a good photograph wanted"
  end

  test "the unreadable-row count rides home on the summary" do
    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [hit("https://cdn.example.com/a.jpg")], unparsed: 7)
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
    Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: first))

    row = AppearanceReferencePhoto.find_by!(image_url: demoted)
    refute row.chosen?
    assert_equal AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT, row.rejection_reason

    # Same photograph, now the provider's top hit.
    second = [hit(demoted, position: 1)]
    second += (1..limit).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i + 1) }
    Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: second))

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

    Appearances::GatherReferencePhotos.call(@look, search: FakeSearch.new(results: [hit(url)]))

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

  test "the provider is asked for the query the summary reports" do
    search = FakeSearch.new(results: [])
    summary = Appearances::GatherReferencePhotos.call(@look, search: search, limit: 11)

    assert_equal [[summary.query, 11]], search.asked
  end
end
