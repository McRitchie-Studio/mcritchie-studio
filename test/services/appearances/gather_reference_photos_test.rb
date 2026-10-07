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

    attr_reader :targets

    # TWO WAYS TO BUILD IT, AND THE SECOND ONE IS WHAT THE FAN-OUT NEEDS.
    #
    # `results:` answers EVERY query with the same list, which is what the cases about
    # the cap, the SSRF guard and the ranking want — they are about one answer's fate and
    # not about which query produced it. ⚠ Note what it means for the COUNTS: four
    # queries each returning the same twenty rows is `returned: 80` and `unique: 20`,
    # because that is exactly what four identical searches would really cost.
    #
    # `per_query:` answers each query from its own list, keyed by the FULL query string,
    # and is the only way to test the fan-out at all: attribution, the marginal dedupe,
    # and the round-robin shortlist are all statements about WHICH query returned a
    # photograph. A query with no entry answers empty, which is also the honest shape for
    # a variant that found nothing.
    def initialize(results: [], unparsed: 0, available: true, per_query: nil)
      @answer = Appearances::ImageSearch::Answer.new(
        results: results, unparsed_count: unparsed, provider_name: "fake"
      )
      @per_query = per_query
      @available = available
      @asked = []
      @targets = []
    end

    def available? = @available
    def provider_name = (@available ? "fake" : nil)

    # `target:` IS RECORDED RATHER THAN IGNORED. It is what the façade files a
    # provider failure against, and a fake that quietly accepted and dropped it
    # would let the caller stop passing it with every test still green.
    def search(query:, limit:, target: nil)
      @asked << [query, limit]
      @targets << target
      return @answer if @per_query.nil?

      Appearances::ImageSearch::Answer.new(
        results: Array(@per_query[query]), unparsed_count: 0, provider_name: "fake"
      )
    end
  end

  # THE FOUR QUERIES ONE SUBJECT PRODUCES, spelled the way the object spells them.
  #
  # DERIVED FROM THE CONSTANT rather than typed out, so a test asserting "every variant
  # ran" cannot pass by agreeing with a stale copy of the list. The one test that pins
  # the WORDS pins them literally, on purpose, and is the only one that should.
  def queries_for(subject)
    Appearances::GatherReferencePhotos::QUERY_VARIANTS.map do |variant|
      [subject, variant].compact_blank.join(" ")
    end
  end

  # A MIRROR THAT COPIES NOTHING. Injected for a slightly different reason than the
  # other two collaborators: it spends no vendor money, but the real one fetches a
  # remote file and writes an object into a real S3 bucket, and a suite must do neither.
  # Appearances::LiveCallTrap refuses the un-injected path outright, so forgetting
  # `mirror:` here fails loudly instead of quietly uploading — see
  # live_call_trap_test.rb.
  class FakeMirror
    HOST = "https://bucket.s3.test.amazonaws.com/reference-photos".freeze

    attr_reader :owners, :targets

    # A STABLE FAKE HOSTED URL PER CANDIDATE, so FakeFaces below can be built with
    # scores keyed by the PROVIDER's url — the way a reader thinks about a test case —
    # and still answer the mirrored url the real classifier is now handed.
    def self.hosted_for(url) = "#{HOST}/#{Digest::SHA256.hexdigest(url)[0, 12]}/original.png"

    # `fails:` names the candidates this mirror cannot copy, which is how the tests
    # reach the partial and total mirror-failure paths without a network.
    def initialize(fails: [])
      @fails = Array(fails)
      @owners = []
      @targets = []
    end

    def call(photos, target: nil)
      @owners.concat(photos)
      @targets << target
      photos.each_with_object({}) do |photo, hosted|
        next if @fails.include?(photo.image_url)

        hosted[photo.image_url] = self.class.hosted_for(photo.image_url)
      end
    end
  end

  # A CLASSIFIER THAT CANNOT SEE. Injected for exactly the reason the search is:
  # Appearances::FaceVisibility bills per image, so the suite must be handed
  # something that cannot reach the network. It returns whatever scores it was
  # built with and records what it was asked to look at.
  #
  # BUILT WITH REMOTE-KEYED SCORES, ANSWERING MIRRORED URLs. The real classifier is
  # handed our own copy of each candidate, never the provider's URL — that is the whole
  # fix — so this fake translates through FakeMirror's own rule. Keeping the fixtures
  # keyed on the provider's URL is deliberate: a test case reads as "the helmet scored
  # 0.15", and rewriting every one of them in terms of a digest would obscure the case
  # to prove a plumbing detail that #asked already proves directly.
  class FakeFaces
    attr_reader :asked

    attr_reader :targets

    def initialize(scores = {}, available: true)
      @scores = scores
      @available = available
      @asked = []
      @targets = []
    end

    def available? = @available

    def call(urls, target: nil)
      @asked.concat(urls)
      @targets << target
      @scores.each_with_object({}) do |(remote_url, score), out|
        hosted = FakeMirror.hosted_for(remote_url)
        out[hosted] = judgement(score) if urls.include?(hosted)
      end
    end

    # A FIXTURE IS EITHER A BARE VISIBILITY OR A WHOLE JUDGEMENT, and both build the
    # value object the real classifier returns — so no test here can be green against a
    # shape Appearances::FaceVisibility#parse does not produce.
    #
    # `0.15` reads as "the helmet scored 0.15" and is what the cases about VISIBILITY
    # want. A Hash (`{ visibility: 0.9, fill: 0.8 }`) is for the cases about face SIZE,
    # which is the measurement a mint turns on. A bare number therefore means "something
    # looked and never measured the size" — which is a real answer shape, and the one
    # every row filed before that field existed carries.
    def judgement(score)
      return Appearances::FaceVisibility::Judgement.new(**score) if score.is_a?(Hash)

      Appearances::FaceVisibility::Judgement.new(visibility: score)
    end
  end

  # NOTHING LOOKS. The default in most tests below, and the state of every machine
  # with no ANTHROPIC_API_KEY.
  class NoFaces
    def self.available? = false
    def self.call(_urls, target: nil) = raise("an unavailable classifier must never be asked to look")
  end

  def hit(url, position: 1, **rest)
    Appearances::ImageSearch::Result.new(image_url: url, position: position, **rest)
  end

  # ONE MIRROR PER TEST, memoised so a test can assert on what it was handed.
  def mirror = @mirror ||= FakeMirror.new

  # A CLASSIFIER THAT MEASURED EVERY CANDIDATE AND LIKED THEM ALL — the precondition for
  # the cases about the MINT list specifically.
  #
  # Appearances::ReferenceEligibility asks two different questions, and this helper is for
  # the stricter one: a photograph may be a REFERENCE without a measured face size, but it
  # may not be paid to Higgsfield's trainer without one, because four real mints on
  # 2026-09-25 turned on face size and a portrait-shaped bare-faced sideline shot failed
  # at prepare. A test about mint eligibility therefore has to hand the lane a classifier
  # that actually measured a size.
  def mintable(results, visibility: 0.9, fill: 0.9)
    FakeFaces.new(Array(results).to_h { |r| [r.image_url, { visibility: visibility, fill: fill }] })
  end

  # A CLASSIFIER THAT LOOKED AND REPORTED NO SIZE — the precondition for being a REFERENCE
  # at all, and the weaker of the two.
  #
  # Appearances::ReferenceEligibility refuses a candidate nothing looked at, because an
  # unjudged photograph cannot be shown to hold ONE person's face. Measured on production
  # 2026-09-27 (`jaylen-waddle`): five returned, three scored, all five chosen, and one of
  # the two unjudged ones was a correctly titled photograph of two men. So a case about the
  # cap or the SSRF guard has to hand the lane a classifier that at least LOOKED; under
  # `NoFaces` nothing is chosen and the case would be asserting a different thing.
  def looked_at(results, visibility: 0.9)
    FakeFaces.new(Array(results).to_h { |r| [r.image_url, visibility] })
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

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: looked_at(results), mirror: mirror
    )

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

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: looked_at(results), mirror: mirror
    )

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

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: looked_at(results), mirror: mirror
    )

    assert_equal Appearances::GatherReferencePhotos::CHOSEN_LIMIT, summary.chosen,
                 "the unsafe hit must not have eaten a slot a good photograph wanted"
  end

  # SUMMED ACROSS THE VARIANTS, not taken from one of them. Each query is its own parse,
  # so a shape the parser cannot read fails once PER SEARCH — and reporting only the last
  # search's count would under-report a total parser failure by three quarters.
  test "the unreadable-row count rides home on the summary, added up across the searches" do
    search = FakeSearch.new(results: [hit("https://cdn.example.com/a.jpg")], unparsed: 7)
    summary = Appearances::GatherReferencePhotos.call(@look, search: search, faces: NoFaces)

    assert_equal 7 * search.asked.length, summary.unparsed,
                 "a silent zero and a silent parse failure are the same empty list without this"
    assert_operator summary.unparsed, :>, 7, "one search's count is not four searches' count"
  end

  # A SEARCH IS RE-JUDGED, NOT DUPLICATED. The unique index makes it safe; this
  # asserts the verdict actually moves rather than the row merely surviving.
  test "re-searching re-judges an existing hit instead of filing a second row" do
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    demoted = "https://cdn.example.com/climber.jpg"

    first = (1..limit).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }
    first << hit(demoted, position: limit + 1)
    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: first), faces: looked_at(first), mirror: mirror
    )

    row = AppearanceReferencePhoto.find_by!(image_url: demoted)
    refute row.chosen?
    assert_equal AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT, row.rejection_reason

    # Same photograph, now the provider's top hit.
    second = [hit(demoted, position: 1)]
    second += (1..limit).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i + 1) }
    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: second), faces: looked_at(second), mirror: FakeMirror.new
    )

    assert_equal limit + 1, AppearanceReferencePhoto.count, "no row was duplicated"
    row.reload
    assert row.chosen?, "a hit that climbed to rank 1 must now be chosen"
    assert_nil row.rejection_reason
  end

  # EVERY NUMBER IN THE SUMMARY IS ABOUT THE SAME POPULATION, and a row this run left
  # ALONE is in none of them.
  #
  # `#upsert` answers nil for a headshot or operator row a search re-found, so a count
  # taken before that answer describes a photograph the run did not file. Measured as a
  # real off-by-one: `mint_ready` was incremented at the call site and could report
  # "1 of 0 carry a measured face size" on a look whose only hit was the operator's own.
  test "a row the run left alone is counted in nothing, not even as mint-ready" do
    url = "https://cdn.example.com/operator-picked.jpg"
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, image_url: url,
                                     source: AppearanceReferencePhoto::SOURCE_OPERATOR,
                                     chosen: true)
    found = hit(url, position: 1)

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [found]),
      faces: mintable([found]), mirror: mirror
    )

    assert_equal 0, summary.filed
    assert_equal 0, summary.chosen
    assert_equal 0, summary.mint_ready,
                   "a photograph this run never filed cannot be one it offered the trainer"
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

  # ── THE TEAM THAT SILENTLY LEFT THE QUERY ────────────────────────────────────────
  #
  # THE DEFECT, MEASURED ON PRODUCTION 2026-09-27. `teams` has ZERO rows there against
  # 2,051 athletes, every one of which carries a populated `team_slug`. `#team_name` read
  # only the ASSOCIATION, which resolved nil, and `compact_blank` dropped the nil without
  # a word — so the effective query for a Vikings receiver was his bare name and the
  # search came back a wall of his LSU college photographs. Nothing raised and nothing
  # logged: the page printed a query that looked deliberate.
  #
  # THESE TESTS NAME TEAMS THE teams TABLE DOES NOT HOLD, which is the production state
  # (no teams rows) and NOT the seeded one; no fixture holds these slugs. The table itself
  # stays, since contracts and the other team children hold its fixture rows by key.

  test "the team joins the query from the slug when the teams table is empty" do
    athlete = athletes(:allen_athlete)
    athlete.update!(team_slug: "minnesota-vikings")
    assert_nil athlete.reload.team, "the precondition IS the defect: the association resolves nil"

    query = Appearances::GatherReferencePhotos.new(@look).query

    assert_equal "Josh Allen Minnesota Vikings", query
  end

  # EVERY ONE OF THE FOUR CARRIES THE TEAM, not just the first. The subject is built once
  # and the variants are appended to it, so a regression that dropped the team from the
  # subject would show up here as four bare-name queries.
  test "every variant carries the team the slug supplied" do
    athletes(:allen_athlete).update!(team_slug: "minnesota-vikings")

    queries = Appearances::GatherReferencePhotos.new(@look).queries

    assert_equal queries_for("Josh Allen Minnesota Vikings"), queries
    assert queries.all? { |q| q.include?("Minnesota Vikings") }
  end

  # THE SLUG IS A FALLBACK, NOT A REPLACEMENT. A row is an authority and a slug is a
  # reconstruction, so the day somebody seeds `teams` the record has to win — otherwise
  # this fix quietly becomes the thing that ignores the real data.
  test "a team RECORD still beats the slug it would have been rebuilt from" do
    team = Team.create!(slug: "minnesota-vikings", name: "Minnesota Vikings FOOTBALL CLUB",
                        league: "NFL")
    athletes(:allen_athlete).update!(team_slug: team.slug)

    assert_equal "Josh Allen #{team.name}", Appearances::GatherReferencePhotos.new(@look).query
  end

  # THE TWO SLUGS THAT COULD HAVE GONE WRONG, and the reason this asserts the whole
  # sentence rather than `titleize` in isolation: swapping `titleize` for `humanize` — the
  # neighbouring method, and the one a reader reaches for — gives "San francisco 49ers",
  # which is a worse search term and a green test under any looser assertion. All 32
  # distinct production slugs were checked by hand on 2026-09-27; these are the two whose
  # digits and multi-word cities make them the ones worth pinning.
  test "a numeric or multi-word team slug humanises to the team's actual name" do
    athlete = athletes(:allen_athlete)

    {
      "san-francisco-49ers" => "San Francisco 49ers",
      "washington-commanders" => "Washington Commanders",
      "new-england-patriots" => "New England Patriots"
    }.each do |slug, expected|
      athlete.update!(team_slug: slug)
      assert_equal "Josh Allen #{expected}",
                   Appearances::GatherReferencePhotos.new(@look.reload).query
    end
  end

  # ── THE FAN-OUT ──────────────────────────────────────────────────────────────────

  # THE OPERATOR'S OWN FOUR, PINNED LITERALLY. The only test here that spells the words
  # out: every other one derives them from the constant, so this is the single place a
  # reviewer can check that what shipped is what he asked for — "First name Last name",
  # "Name Smile", "Name No Helmet", "Name Laugh" — and the single place that fails if
  # somebody quietly swaps one for a variant of their own. His two nouns ship as the
  # gerunds the 107-of-120 measurement used; see QUERY_VARIANTS for what that trades.
  test "the four searches are the operator's four, in his order" do
    assert_equal ["", "smiling", "no helmet", "laughing"],
                 Appearances::GatherReferencePhotos::QUERY_VARIANTS
    assert_equal ["Josh Allen", "Josh Allen smiling", "Josh Allen no helmet",
                  "Josh Allen laughing"],
                 Appearances::GatherReferencePhotos.new(@look).queries
    refute_includes Appearances::GatherReferencePhotos::QUERY_VARIANTS, "press conference",
                    "the variant that measured 0 portrait-shaped of 20 is not shipped"
  end

  # A BLANK SUBJECT BUYS NOTHING. With no name there is no subject, so the variants would
  # degrade to asking the internet for the bare word "smiling" — four purchases for an
  # answer about nobody, which is worse than not searching at all.
  test "a look with no person in it spends no queries" do
    orphan = Appearance.new(person_slug: "nobody-at-all", descriptor: "x")
    search = FakeSearch.new(results: [hit("https://cdn.example.com/a.jpg")])

    summary = Appearances::GatherReferencePhotos.call(orphan, search: search, faces: NoFaces)

    assert_empty search.asked, "no subject means no purchase"
    assert summary.configured?, "the credential is fine — it is the LOOK that has no subject"
    assert_equal 0, summary.returned
    assert_equal 0, AppearanceReferencePhoto.count
  end

  # ── THE DEDUPE ───────────────────────────────────────────────────────────────────

  # ONE PHOTOGRAPH, ONE ROW, HOWEVER MANY VARIANTS RETURNED IT. Measured 2026-09-27 on
  # `jaylen-waddle`: 7 of 80 collided. Without this the same photograph would occupy two
  # slots in one identity, so an identity built from eight would hold seven faces and
  # report eight.
  test "a photograph two variants return is filed once" do
    shared = hit("https://cdn.example.com/shared.jpg", position: 1)
    queries = queries_for("Josh Allen")
    per_query = {
      queries[0] => [shared, hit("https://cdn.example.com/only-base.jpg", position: 2)],
      queries[1] => [shared],
      queries[2] => [shared],
      queries[3] => [hit("https://cdn.example.com/only-laugh.jpg", position: 1)]
    }

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: NoFaces
    )

    assert_equal 5, summary.returned, "five rows were bought"
    assert_equal 3, summary.unique, "three photographs were bought"
    assert_equal 2, summary.duplicates
    assert_equal 3, AppearanceReferencePhoto.count
  end

  # THE COST CONTROL, NOT THE TIDINESS. A duplicate that reaches the classifier is money
  # spent twice for one answer, and the classifier bills per image.
  test "a duplicate is never paid to be classified twice" do
    shared = hit("https://cdn.example.com/shared.jpg", position: 1)
    per_query = queries_for("Josh Allen").to_h { |q| [q, [shared]] }
    faces = FakeFaces.new({ shared.image_url => 0.9 })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: faces, mirror: mirror
    )

    assert_equal 1, faces.asked.length, "four searches found it; it is classified once"
    assert_equal 1, faces.asked.uniq.length
    assert_equal 1, mirror.owners.length, "and mirrored once"
  end

  # ── THE PROVENANCE THE OPERATOR ASKED FOR ────────────────────────────────────────

  # "the scouting page should let him see WHICH variant found each photo". The column
  # already existed and held the only query there was; with four of them the per-ROW
  # answer is the one he calibrates a variant against, and the page reads it off here.
  test "each row records which of the four searches found it" do
    queries = queries_for("Josh Allen")
    per_query = {
      queries[0] => [hit("https://cdn.example.com/base.jpg", position: 1)],
      queries[2] => [hit("https://cdn.example.com/bare-faced.jpg", position: 1)],
      queries[3] => [hit("https://cdn.example.com/grinning.jpg", position: 1)]
    }

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: NoFaces
    )

    assert_equal queries[0], AppearanceReferencePhoto.find_by!(image_url: per_query[queries[0]].first.image_url).query
    assert_equal queries[2], AppearanceReferencePhoto.find_by!(image_url: per_query[queries[2]].first.image_url).query
    assert_equal queries[3], AppearanceReferencePhoto.find_by!(image_url: per_query[queries[3]].first.image_url).query
  end

  # THE FIRST VARIANT WINS, AND THAT IS THE ACCOUNTING RATHER THAN AN ACCIDENT OF
  # ITERATION. A photograph the bare name would have found anyway is not evidence that
  # "no helmet" earns its query, so crediting it to the FIRST variant makes each variant's
  # number on the page its MARGINAL contribution — what dropping that query would cost.
  # Credit it to the LAST variant instead and the page would tell the operator to keep the
  # wrong query.
  test "a photograph several variants return is credited to the first of them" do
    shared = hit("https://cdn.example.com/shared.jpg", position: 1)
    queries = queries_for("Josh Allen")
    per_query = { queries[0] => [shared], queries[1] => [shared], queries[3] => [shared] }

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: NoFaces
    )

    assert_equal queries[0], AppearanceReferencePhoto.find_by!(image_url: shared.image_url).query
    assert_equal 1, summary.per_query[queries[0]][:unique]
    assert_equal 0, summary.per_query[queries[1]][:unique],
                    "a variant is credited with what it alone found, not with what it echoed"
    assert_equal 1, summary.per_query[queries[1]][:returned],
                    "and still reports what it cost, so a useless query is visible"
  end

  # ── WHO GETS CLASSIFIED: THE ROUND-ROBIN ─────────────────────────────────────────

  # ⚠ THE TEST THE WHOLE CHANGE TURNS ON. A global `sort_by(&:merit).first(24)` is the
  # obvious shortlist and it defeats the purpose of the fan-out: `#merit` scores shape,
  # size and title and knows NOTHING about expression, so the bare-name variant's big
  # clean action shots can take every slot, everything from "laughing" is refused as
  # `face_unscored` because nobody looked at it, and the identity is the one we had before
  # — after buying four searches instead of one.
  #
  # THE FIXTURE MAKES THE BARE NAME WIN ON MERIT ON PURPOSE: its candidates carry the
  # person's name in the title and portrait dimensions, the variants' do not. Under a
  # global sort every slot goes to the bare name. Under the round-robin every variant is
  # classified before any variant gets a second look.
  test "every variant reaches the classifier even when one variant outranks them all" do
    queries = queries_for("Josh Allen")
    ceiling = Appearances::GatherReferencePhotos::VISION_SHORTLIST
    per_query = queries.each_with_index.to_h do |query, index|
      rows = (1..ceiling).map do |i|
        if index.zero?
          hit("https://cdn.example.com/base-#{i}.jpg", position: i, title: "Josh Allen portrait",
              width: 800, height: 1200)
        else
          hit("https://cdn.example.com/v#{index}-#{i}.jpg", position: i, width: 1600, height: 400)
        end
      end
      [query, rows]
    end
    faces = FakeFaces.new({})

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: faces, mirror: mirror
    )

    assert_equal ceiling, faces.asked.length, "the ceiling still binds"
    seen = mirror.owners.group_by(&:query).transform_values(&:length)
    assert_equal queries.sort, seen.keys.sort,
                 "a variant with nothing classified is a variant that bought a query for nothing"
    assert_equal [ceiling / queries.length], seen.values.uniq,
                 "four equally-supplied variants split the shortlist evenly"
  end

  # A THIN VARIANT GIVES UP ITS SLOTS RATHER THAN WASTING THEM, which is why the shortlist
  # is an interleave and not a quota of VISION_SHORTLIST / 4. Measured 2026-09-26 on a real
  # Commons answer: 12 of 20 candidates were scanned documents, so thin variants are the
  # normal case. Under a hard quota this run would classify 1 + 3 + 3 + 3 and leave 14 paid
  # slots empty.
  test "a variant that found almost nothing does not waste the slots it cannot fill" do
    queries = queries_for("Josh Allen")
    ceiling = Appearances::GatherReferencePhotos::VISION_SHORTLIST
    per_query = {
      queries[0] => [hit("https://cdn.example.com/thin.jpg", position: 1)],
      queries[1] => (1..ceiling).map { |i| hit("https://cdn.example.com/b#{i}.jpg", position: i) },
      queries[2] => (1..ceiling).map { |i| hit("https://cdn.example.com/c#{i}.jpg", position: i) },
      queries[3] => (1..ceiling).map { |i| hit("https://cdn.example.com/d#{i}.jpg", position: i) }
    }
    faces = FakeFaces.new({})

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: faces, mirror: mirror
    )

    assert_equal ceiling, faces.asked.length,
                 "the thin variant's unused slots go to variants that can fill them"
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
      @look, search: FakeSearch.new(results: [helmet, bare]), faces: faces, mirror: mirror
    )

    order = Appearances::ReferenceSet.new(@look.reload).persisted_rows.map(&:image_url)
    assert_equal [bare.image_url, helmet.image_url], order,
                 "the bare face must lead even though the helmet was the provider's hit 1"
  end

  # ── RANK BY FACE SIZE, NOT JUST BY VISIBILITY ────────────────────────────────────
  #
  # THE DEFECT, MEASURED. The photograph the old ranking put FIRST on look `1943e690035b`
  # scored 92 for face visibility and is one Higgsfield REFUSES: a bare-faced 556x780
  # sideline shot that failed at prepare every time it was tried, while a tight ESPN
  # headshot completed. Ordering on visibility put an unmintable photograph at the top of
  # the page with a confident 92 beside it.
  test "a big face outranks a clearer but smaller one" do
    small = hit("https://cdn.example.com/sideline.jpg", position: 1)
    big = hit("https://cdn.example.com/tight.jpg", position: 2)
    faces = FakeFaces.new({ small.image_url => { visibility: 0.95, fill: 0.2 },
                            big.image_url => { visibility: 0.80, fill: 0.9 } })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [small, big]), faces: faces, mirror: mirror
    )

    ranked = Appearances::ReferenceSet.new(@look.reload).persisted_rows.map(&:image_url)
    assert_equal [big.image_url, small.image_url], ranked,
                 "face SIZE is the variable four real mints turned on; visibility is not"
  end

  # ⚠ THE CASE ABOVE READS THE GALLERY ORDER, WHICH IS THE SQL SCOPE — NOT THE CHOOSER.
  # A mutation run proved it: collapsing `#final_score` to visibility only left that case
  # GREEN, because `gallery_order` sorts on `face_fill` in Postgres and would have kept
  # reporting the right order over a chooser that had stopped using it. The ranker's real
  # consequence is WHICH photographs are chosen once supply exceeds the cap, so that is
  # what this case measures: seven candidates for six slots, where the one with the biggest
  # face has the WORST visibility. Under a visibility-only ranking it is the one left out.
  test "when supply exceeds the cap, the biggest face takes the last slot" do
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    clear_but_small = (1..limit).map { |i| hit("https://cdn.example.com/small#{i}.jpg", position: i) }
    big_face = hit("https://cdn.example.com/big.jpg", position: limit + 1)
    scores = clear_but_small.to_h { |r| [r.image_url, { visibility: 0.99, fill: 0.62 }] }
                            .merge(big_face.image_url => { visibility: 0.60, fill: 0.99 })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: clear_but_small + [big_face]),
      faces: FakeFaces.new(scores), mirror: mirror
    )

    assert_equal limit, summary.chosen
    assert AppearanceReferencePhoto.find_by!(image_url: big_face.image_url).chosen?,
           "face SIZE decides the last slot; a visibility-only ranking drops this one"
    refute AppearanceReferencePhoto.find_by!(image_url: clear_but_small.last.image_url).chosen?,
           "the clearest small face is the one the cap should push out"
  end

  # AND THE SAME MEASUREMENT THROUGH THE CHOOSER FOR THE TIE-BREAK, so neither half of
  # "rank by face size, not JUST by face size" rests on the SQL scope alone.
  test "when supply exceeds the cap, visibility breaks a tie for the last slot" do
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    filler = (1..limit).map { |i| hit("https://cdn.example.com/f#{i}.jpg", position: i) }
    dim = hit("https://cdn.example.com/dim.jpg", position: limit + 1)
    scores = filler.to_h { |r| [r.image_url, { visibility: 0.9, fill: 0.9 }] }
    scores[filler.last.image_url] = { visibility: 0.95, fill: 0.7 }
    scores[dim.image_url] = { visibility: 0.55, fill: 0.7 }

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: filler + [dim]),
      faces: FakeFaces.new(scores), mirror: mirror
    )

    assert AppearanceReferencePhoto.find_by!(image_url: filler.last.image_url).chosen?,
           "two faces the same size are separated by how clearly they show"
    refute AppearanceReferencePhoto.find_by!(image_url: dim.image_url).chosen?
  end

  # VISIBILITY STILL BREAKS A TIE, at a tenth of the weight — "not JUST visibility" rather
  # than "never visibility". Two photographs whose faces fill the same fraction of the frame
  # are ordered by how clearly those faces show.
  test "visibility breaks a tie between two faces of the same size" do
    dim = hit("https://cdn.example.com/dim.jpg", position: 1)
    clear = hit("https://cdn.example.com/clear.jpg", position: 2)
    faces = FakeFaces.new({ dim.image_url => { visibility: 0.55, fill: 0.9 },
                            clear.image_url => { visibility: 0.95, fill: 0.9 } })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [dim, clear]), faces: faces, mirror: mirror
    )

    ranked = Appearances::ReferenceSet.new(@look.reload).persisted_rows.map(&:image_url)
    assert_equal [clear.image_url, dim.image_url], ranked
  end

  # A MEASURED PHOTOGRAPH OUTRANKS ONE NOBODY LOOKED AT, and neither is read as a zero.
  # Three bands, and this is the boundary between the top two.
  test "a measured face size outranks a photograph with only a visibility score" do
    sized = hit("https://cdn.example.com/sized.jpg", position: 9)
    unsized = hit("https://cdn.example.com/unsized.jpg", position: 1)
    faces = FakeFaces.new({ sized.image_url => { visibility: 0.5, fill: 0.6 },
                            unsized.image_url => 0.99 })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [unsized, sized]), faces: faces, mirror: mirror
    )

    ranked = Appearances::ReferenceSet.new(@look.reload).persisted_rows.map(&:image_url)
    assert_equal [sized.image_url, unsized.image_url], ranked,
                 "the band with more evidence in it leads, even on a worse visibility"
  end

  # A PHOTOGRAPH WHOSE TITLE NAMES SOMEBODY ELSE IS NEVER PAID FOR. Same argument as the
  # documents: it can never be chosen, and the classifier bills per image.
  test "a photograph of a different person is never sent to the classifier" do
    stranger = hit("https://cdn.example.com/hutton.jpg", position: 1, title: "Keenan Allen.jpg")
    ours = hit("https://cdn.example.com/ours.jpg", position: 2, title: "Josh Allen at camp")
    faces = FakeFaces.new({ ours.image_url => { visibility: 0.9, fill: 0.9 } })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [stranger, ours]), faces: faces, mirror: mirror
    )

    assert_equal 1, summary.shortlisted, "the stranger must not be shortlisted, let alone billed"
    refute mirror.owners.map(&:image_url).include?(stranger.image_url)
    row = AppearanceReferencePhoto.find_by!(image_url: stranger.image_url)
    refute row.chosen?
    assert_equal AppearanceReferencePhoto::REJECTED_WRONG_PERSON, row.rejection_reason
  end

  # ⚠ A REVERSAL, AND THE MEASUREMENT THAT EARNED IT. This case used to assert the
  # opposite — "helmeted photos are still chosen when there is nothing better" — on the
  # argument that a threshold which EXCLUDED would starve a person of whom no clear
  # photograph exists. The mint measurements retired that argument: the three-photograph
  # set that failed at Higgsfield's prepare step was helmets, and a photograph with no
  # visible face cannot contribute a face to a face likeness on either generator.
  #
  # NOBODY IS STARVED, which is the only reason this is safe: Appearances::ReferenceImages
  # still puts the cached headshot at the head of every set, and that headshot is the one
  # input measured to complete a reference.
  test "a helmeted photo is refused, because a hidden face is no reference at all" do
    helmets = (1..3).map { |i| hit("https://cdn.example.com/h#{i}.jpg", position: i) }
    faces = FakeFaces.new(helmets.to_h { |h| [h.image_url, { visibility: 0.15, fill: 0.95 }] })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: helmets), faces: faces, mirror: mirror
    )

    assert_equal 0, summary.chosen
    assert_equal 3, AppearanceReferencePhoto.where(
      rejection_reason: AppearanceReferencePhoto::REJECTED_FACE_OBSCURED
    ).count, "a big helmet is still a hidden face — fill 0.95 must not rescue it"
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
      @look, search: FakeSearch.new(results: [scan, photo]), faces: faces, mirror: mirror
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
      @look, search: FakeSearch.new(results: [scan, photo]), faces: faces, mirror: mirror
    )

    assert_equal [FakeMirror.hosted_for(photo.image_url)], faces.asked,
                 "one image classified, and it is OUR copy of it"
    refute_includes faces.asked, scan.image_url
  end

  # A DISQUALIFIED CANDIDATE MUST NOT EAT A SLOT on its way to being rejected, or a
  # thin answer full of scanned pages leaves the identity smaller than its supply.
  test "a rejected document does not consume one of the chosen slots" do
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    scans = (1..3).map { |i| hit("https://cdn.example.com/page1-#{i}.pdf.jpg", position: i) }
    photos = (1..limit).map { |i| hit("https://cdn.example.com/p#{i}.jpg", position: i + 3) }
    faces = FakeFaces.new(photos.to_h { |p| [p.image_url, 0.8] })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: scans + photos), faces: faces, mirror: mirror
    )

    assert_equal limit, summary.chosen
  end

  # `face_obscured` IS A JUDGEMENT, so it is stamped only where something judged — and a
  # candidate nothing looked at now says exactly that instead.
  #
  # ⚠ THE REASON CHANGED FROM `beyond_limit` AND THAT IS THE POINT. "past the limit of 6"
  # over a set of 8 that nothing examined was a reassuring sentence about a run in which no
  # judgement was ever made; on production 2026-09-27 the same silence let five of five
  # unjudged candidates into a reference set.
  test "a loser nothing looked at says nobody looked, never face_obscured" do
    results = (1..(Appearances::GatherReferencePhotos::CHOSEN_LIMIT + 2)).map do |i|
      hit("https://cdn.example.com/#{i}.jpg", position: i)
    end

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: NoFaces
    )

    reasons = AppearanceReferencePhoto.rejected.pluck(:rejection_reason).uniq
    assert_equal [AppearanceReferencePhoto::REJECTED_FACE_UNSCORED], reasons,
                 "with no classifier configured nothing may be labelled face_obscured"
    assert_equal 0, summary.chosen,
                 "an unjudged photograph cannot be shown to hold one person's face"
  end

  # ── A CANDIDATE SET SMALLER THAN THE SHORTLIST ───────────────────────────────────
  #
  # THE PRODUCTION SHAPE, cloned from the measured run rather than imagined. On
  # 2026-09-27 `jaylen-waddle` returned FIVE candidates, three were scored, and all five
  # were chosen — because the only thing between a candidate and the model was the cap,
  # and five is under the cap of six. A thin answer therefore had NO floor at all: every
  # hit reached the reference set whatever its merit, which is exactly the condition under
  # which one wrong-person or two-subject hit is guaranteed to be chosen.
  test "a thin answer has a floor, not just a cap" do
    scored = (1..3).map { |i| hit("https://cdn.example.com/scored#{i}.jpg", position: i) }
    unscored = (4..5).map { |i| hit("https://cdn.example.com/unscored#{i}.jpg", position: i) }
    faces = FakeFaces.new(scored.to_h { |r| [r.image_url, { visibility: 0.9, fill: 0.8 }] })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: scored + unscored), faces: faces, mirror: mirror
    )

    assert_equal 5, summary.filed, "every candidate is still filed as evidence of the search"
    assert_equal 3, summary.chosen,
                 "five under a cap of six must not mean five chosen — the cap is not a floor"
    unscored.each do |result|
      row = AppearanceReferencePhoto.find_by!(image_url: result.image_url)
      refute row.chosen?
      assert_equal AppearanceReferencePhoto::REJECTED_FACE_UNSCORED, row.rejection_reason
    end
  end

  test "a loser the classifier judged obscured is labelled as such" do
    keep = (1..Appearances::GatherReferencePhotos::CHOSEN_LIMIT).map do |i|
      hit("https://cdn.example.com/k#{i}.jpg", position: i)
    end
    loser = hit("https://cdn.example.com/helmet.jpg", position: 99)
    scores = keep.to_h { |k| [k.image_url, 0.9] }.merge(loser.image_url => 0.15)

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: keep + [loser]), faces: FakeFaces.new(scores), mirror: mirror
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
      @look, search: FakeSearch.new(results: results), faces: faces, mirror: mirror
    )

    assert_equal Appearances::GatherReferencePhotos::VISION_SHORTLIST, faces.asked.length
  end

  # THE DEGRADE, AND WHAT IT NOW COSTS. A broken classifier must never cost the operator
  # the SEARCH — every candidate is still filed with its evidence and the page still
  # renders — but it does now cost him the picks, and that is the deliberate trade made from
  # production evidence: an unjudged photograph cannot be shown to hold one person's face,
  # and the zero-shot sheet falls back on the cached headshot it used before this lane
  # existed.
  test "a classifier that returns nothing files everything and chooses nothing" do
    results = (1..3).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: FakeFaces.new({}), mirror: mirror
    )

    assert_equal 3, summary.filed, "the evidence of what the search offered is never lost"
    assert_equal 0, summary.chosen
    refute summary.ranked_by_face?
    assert AppearanceReferencePhoto.where.not(face_score: nil).none?,
           "an unscored row must stay NULL - nobody looked is not a score of zero"
  end

  test "the summary names what did the ordering" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)

    scored = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]),
      faces: FakeFaces.new({ photo.image_url => 0.9 }), mirror: mirror
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
      faces: FakeFaces.new({ photo.image_url => 0.77 }), mirror: mirror
    )
    assert_in_delta 0.77, AppearanceReferencePhoto.find_by!(image_url: photo.image_url).face_score, 0.001

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]), faces: NoFaces
    )

    assert_in_delta 0.77, AppearanceReferencePhoto.find_by!(image_url: photo.image_url).face_score, 0.001
  end

  test "the provider is asked for every query the summary reports" do
    search = FakeSearch.new(results: [])
    summary = Appearances::GatherReferencePhotos.call(@look, search: search, faces: NoFaces, limit: 11)

    assert_equal summary.queries.map { |q| [q, 11] }, search.asked
    assert_equal queries_for("Josh Allen"), summary.queries
  end

  # WHO THE FAILURE GETS FILED AGAINST. Both collaborators degrade to an empty
  # answer rather than raising, so a credential failure inside either one is
  # invisible on the page — the ErrorLog row is what makes it findable, and the look
  # is the only handle the operator has for reading the right row back. If this
  # object stops passing itself along, the row loses its subject and every other test
  # here still passes.
  test "the look is handed to both collaborators as the failure target" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)
    search = FakeSearch.new(results: [photo])
    faces = FakeFaces.new({ photo.image_url => 0.8 })

    Appearances::GatherReferencePhotos.call(@look, search: search, faces: faces, mirror: mirror)

    # ONE TARGET PER SEARCH, because there is one HTTP call per query and each can fail
    # on its own — a variant that 429s has to file a row naming the look it failed on,
    # and passing the target on only the first query would lose the other three.
    assert_equal [@look] * search.asked.length, search.targets
    assert_equal [@look], faces.targets, "the classifier is one request for the whole shortlist"
  end
  # ── THE MIRROR: NOTHING THIRD-PARTY IS HANDED TO A THIRD-PARTY FETCHER ───────────
  #
  # THE BUG THESE WERE WRITTEN FROM, measured on production 2026-09-26. Anthropic
  # answered 400 "Unable to download the file" on every image, because Wikimedia
  # refuses a request that sends no User-Agent (403 with none, 200 with one, against
  # the exact failing URL) and Anthropic's fetcher was the party refused. The
  # classifier degraded to an empty Hash as documented, ranking fell back to
  # title-match and aspect ratio, and SIX photographs entered a character model of
  # which THREE WERE AIRCRAFT — `9V-JSN` and `HB-JSN` are registration codes sharing
  # the athlete's initials.

  # ACCEPTANCE: "Classifier reads an image we host." The one assertion the whole
  # change exists for, made against the collaborator's own record of what it was
  # asked rather than against a mock of the request.
  test "the classifier is handed our own copy, never the provider's URL" do
    remote = "https://upload.wikimedia.org/wikipedia/commons/f/f3/Player.png"
    photo = hit(remote, position: 1)
    faces = FakeFaces.new({ remote => 0.9 })

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]), faces: faces, mirror: mirror
    )

    refute_includes faces.asked, remote,
                    "handing the provider's URL to the classifier IS the bug — " \
                    "Wikimedia answers 403 to a fetcher that sends no User-Agent"
    assert_equal [FakeMirror.hosted_for(remote)], faces.asked
    assert_equal 1, summary.scored, "the score still lands, keyed back to the provider's URL"
    assert_in_delta 0.9, AppearanceReferencePhoto.find_by!(image_url: remote).face_score, 0.001,
                    "the row the operator reads is keyed on the provider's URL, not ours"
  end

  # THE ROW REMAINS THE RECORD; ImageCache is only the copy. Studio::ImageCache
  # validates `variant` unique per (owner, purpose), so the mirror needs a
  # PER-PHOTOGRAPH owner — which means the candidate row has to exist before the
  # mirror runs, and the verdict is stamped afterwards.
  test "each shortlisted candidate is filed before the mirror, so it can own the copy" do
    photos = (1..3).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }
    faces = FakeFaces.new(photos.to_h { |p| [p.image_url, 0.8] })

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: photos), faces: faces, mirror: mirror
    )

    assert_equal 3, mirror.owners.length
    assert mirror.owners.all?(&:persisted?),
           "an ImageCache owner must be a saved row — mirroring an unsaved one cannot store"
    assert_equal photos.map(&:image_url).sort, mirror.owners.map(&:image_url).sort
    assert_equal [@look], mirror.targets, "the mirror gets the failure target too"
  end

  # THE VERDICT IS STAMPED AFTER THE CLASSIFIER ANSWERS, not by the pre-pass. A row
  # left `chosen: false` with no reason by the filing pass would read on the page as a
  # rejection nothing made.
  test "the pre-filing pass leaves no candidate stamped with a verdict it did not earn" do
    keep = (1..Appearances::GatherReferencePhotos::CHOSEN_LIMIT).map do |i|
      hit("https://cdn.example.com/k#{i}.jpg", position: i)
    end
    loser = hit("https://cdn.example.com/helmet.jpg", position: 99)
    scores = keep.to_h { |k| [k.image_url, 0.9] }.merge(loser.image_url => 0.15)

    Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: keep + [loser]),
      faces: FakeFaces.new(scores), mirror: mirror
    )

    assert_equal Appearances::GatherReferencePhotos::CHOSEN_LIMIT,
                 AppearanceReferencePhoto.chosen.count
    assert AppearanceReferencePhoto.rejected.none? { |row| row.rejection_reason.blank? },
           "every rejected row must carry a reason — a blank one is the pre-pass showing through"
  end

  # A CANDIDATE WE COULD NOT MIRROR IS NOT CLASSIFIED, and above all is not quietly
  # sent as a remote URL — that fallback is the bug wearing a different hat.
  test "an unmirrorable candidate is skipped rather than sent remote" do
    good = hit("https://cdn.example.com/good.jpg", position: 1)
    bad = hit("https://cdn.example.com/bad.jpg", position: 2)
    faces = FakeFaces.new({ good.image_url => 0.9, bad.image_url => 0.8 })
    partial = FakeMirror.new(fails: [bad.image_url])

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [good, bad]), faces: faces, mirror: partial
    )

    assert_equal [FakeMirror.hosted_for(good.image_url)], faces.asked
    refute_includes faces.asked, bad.image_url
    assert_equal 2, summary.shortlisted
    assert_equal 1, summary.attempted, "the summary must say how many were actually sent"
    assert_equal 1, summary.scored
    refute summary.face_classifier_blind?, "one score is not a blind lane"
    # THE UNSENT CANDIDATE IS UNKNOWN, NOT ZERO. A NULL face_score is what keeps
    # "nobody looked" out of the band the classifier's own answers occupy.
    assert_nil AppearanceReferencePhoto.find_by!(image_url: bad.image_url).face_score
  end

  # ── THE LOUD FAILURE: "DID NOTHING" IS NOT "HAD NOTHING TO DO" ───────────────────

  # ACCEPTANCE: "A total classifier failure is loud." Before this, zero scores from N
  # attempts and N photographs that scored zero were indistinguishable to an operator:
  # both produced `ranked_by: :merit` and the sentence "ranked on shape and relevance
  # only (no face classifier)", which is TRUE of a machine with no credential and a LIE
  # about a machine that sent eight images and was refused on every one.
  test "a classifier that scored none of the images it was sent is loud" do
    results = (1..8).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }
    refused = FakeFaces.new({})

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: refused, mirror: mirror
    )

    assert_equal 8, summary.shortlisted
    assert_equal 8, summary.attempted
    assert_equal 0, summary.scored
    assert summary.face_classifier_blind?,
           "8 sent and 0 scored is the production failure this change was written from"
    assert_equal :alert, summary.flash_key,
                 "a green notice on this run is what let three aircraft into a model"
    assert_match "0 of 8 shortlisted", summary.sentence
    assert_match "8 mirrored and sent", summary.sentence
    assert_match(/check them before minting/, summary.sentence)
  end

  # THE ALARM MUST NOT CRY WOLF on the state of every machine that has no
  # ANTHROPIC_API_KEY, which is the ordinary path and must keep reading as ordinary.
  test "no classifier configured is not a blind classifier" do
    results = (1..3).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: NoFaces
    )

    assert_equal 0, summary.shortlisted
    refute summary.face_classifier_blind?
    assert_equal :notice, summary.flash_key
    assert_match "no face classifier", summary.sentence
  end

  # NOTHING TO CLASSIFY IS NOT A FAILURE EITHER. Documents are never shortlisted, so an
  # answer that is entirely scanned pages reaches the classifier with nothing to send.
  test "an answer with nothing classifiable in it is not a blind classifier" do
    scans = (1..3).map { |i| hit("https://cdn.example.com/page1-#{i}.pdf.jpg", position: i) }
    faces = FakeFaces.new({})

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: scans), faces: faces, mirror: mirror
    )

    assert_equal 0, summary.shortlisted
    assert_empty faces.asked
    refute summary.face_classifier_blind?,
           "zero shortlisted is 'nothing to do', which must not read as 'saw nothing'"
  end

  # A TOTAL MIRROR FAILURE IS EQUALLY BLIND, which is why the predicate keys on
  # `shortlisted` rather than on `attempted`. Keying on what we SENT would read "the
  # mirror copied nothing, so we sent nothing, so there was nothing to do" — and go
  # quiet on exactly the outage the operator most needs to hear about.
  test "a mirror that copied nothing is as loud as a classifier that scored nothing" do
    results = (1..4).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }
    faces = FakeFaces.new(results.to_h { |r| [r.image_url, 0.9] })
    broken = FakeMirror.new(fails: results.map(&:image_url))

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: results), faces: faces, mirror: broken
    )

    assert_equal 4, summary.shortlisted
    assert_equal 0, summary.attempted
    assert summary.face_classifier_blind?
    assert_match "0 mirrored and sent", summary.sentence,
                 "the sentence must separate a mirror failure from a classifier failure"
    assert_empty faces.asked, "nothing mirrored means nothing is paid to be classified"
    assert_equal 4, summary.filed, "the page still gets its photographs, as evidence"
    assert_equal 0, summary.chosen,
                 "nothing was judged, so nothing may be offered to a generator as vetted"
  end

  # THE DURABLE HALF OF LOUD. A flash lives for one redirect; the operator working out
  # why a gallery looks wrong a day later is reading /error_logs.
  test "a blind lane files exactly one ErrorLog row, against the look" do
    results = (1..5).map { |i| hit("https://cdn.example.com/#{i}.jpg", position: i) }

    assert_difference -> { ErrorLog.count }, 1 do
      Appearances::GatherReferencePhotos.call(
        @look, search: FakeSearch.new(results: results), faces: FakeFaces.new({}), mirror: mirror
      )
    end

    row = ErrorLog.order(:id).last
    assert_match "0 of 5 shortlisted", row.message
    assert_equal @look, row.target, "the look is the only handle for reading the right row back"
    assert_match Appearances::GatherReferencePhotos::ClassifierBlind.name,
                 row.read_attribute(:inspect),
                 "the class name is what the operator scans /error_logs for"
  end

  # HEALTHY NOW MEANS A FACE SIZE CAME BACK TOO. A run that scores every candidate for
  # visibility and measures NO face size is not healthy — it is the shape that would
  # leave Higgsfield's trainer with the headshot alone and say nothing about why — so the
  # fixture reports a fill, and the case below asserts the opposite.
  test "a healthy search files no ErrorLog row" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)

    assert_no_difference -> { ErrorLog.count } do
      Appearances::GatherReferencePhotos.call(
        @look, search: FakeSearch.new(results: [photo]),
        faces: FakeFaces.new({ photo.image_url => { visibility: 0.9, fill: 0.8 } }), mirror: mirror
      )
    end
  end

  # ---- the face-size blindness alarm --------------------------------------------
  #
  # THE FAILURE THIS WHOLE ALARM EXISTS FOR. `fill` is a prompt field that no paid call
  # has ever verified, so the realistic failure is a model that answers a visibility and
  # ignores it — which refuses every search hit at the trainer and, without this, reads
  # as an ordinary run.
  test "a classifier that reports no face size at all is loud about it" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)

    summary = nil
    assert_difference -> { ErrorLog.count }, 1 do
      summary = Appearances::GatherReferencePhotos.call(
        @look, search: FakeSearch.new(results: [photo]),
        faces: FakeFaces.new({ photo.image_url => 0.9 }), mirror: mirror
      )
    end

    assert summary.face_size_blind?
    refute summary.face_classifier_blind?, "the classifier answered — it just answered thinly"
    assert_equal :alert, summary.flash_key
    assert_match "NO FACE SIZE REPORTED", summary.sentence
    assert_match Appearances::GatherReferencePhotos::FaceSizeBlind.name,
                 ErrorLog.order(:id).last.read_attribute(:inspect),
                 "the two blindnesses have different remedies, so they need different names"
    assert_equal 1, summary.chosen, "the photograph is still a reference for the sheet path"
    assert_equal 0, summary.mint_ready
  end

  # A MEASURED RUN IS NOT AN ALARM, and this is the control for the case above: the same
  # shape with a fill reported files nothing and says the trainer can have it.
  test "a classifier that reports a face size raises no alarm and names the trainer's set" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]),
      faces: FakeFaces.new({ photo.image_url => { visibility: 0.9, fill: 0.8 } }), mirror: mirror
    )

    refute summary.face_size_blind?
    assert_equal :notice, summary.flash_key
    assert summary.ranked_by_face_size?
    assert_equal 1, summary.mint_ready
    assert_match "1 measured for face size", summary.sentence
    assert_match "all 1 can also go to the trainer", summary.sentence
  end

  # ---- the everything-refused alarm ----------------------------------------------
  #
  # Production 2026-09-28, Justin Jefferson: 6 scored, 6 sized, 6 refused face_too_small,
  # 0 chosen — and the flash was a green notice that never named the cause.
  test "a run whose every scored candidate was refused alerts and names the dominant refusal" do
    summary = Appearances::GatherReferencePhotos::Summary.new(
      configured: true, provider_name: "serper", queries: %w[a b c d], returned: 80,
      unique: 78, filed: 78, chosen: 0, rejected: 78, unfetchable: 0, unparsed: 0,
      ranked_by: :face_size, scored: 6, sized: 6, mint_ready: 0, shortlisted: 24,
      attempted: 14, per_query: {},
      refusals: { "face_too_small" => 6 }
    )

    assert summary.nothing_chosen?
    assert_equal :alert, summary.flash_key
    assert_match(/0 chosen as references: 6 of 6 scored refused as face_too_small/,
                 summary.sentence)
    assert_match "below the #{(Appearances::ReferenceEligibility::SHEET_FACE_FILL * 100).round}% floor",
                 summary.sentence
    assert_no_match(/0 of 0 carry/, summary.sentence, "a zero denominator reads as a contradiction")
  end

  test "a run that chose something is not the everything-refused alarm" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]),
      faces: FakeFaces.new({ photo.image_url => { visibility: 0.9, fill: 0.8 } }), mirror: mirror
    )

    refute summary.nothing_chosen?
    assert_equal :notice, summary.flash_key
  end

  test "a run where face size refused everything is filed as an alert naming face size" do
    tiny = hit("https://cdn.example.com/tiny.jpg", position: 1)
    distant = hit("https://cdn.example.com/distant.jpg", position: 2)
    below = Appearances::ReferenceEligibility::SHEET_FACE_FILL - 0.1

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [tiny, distant]),
      faces: FakeFaces.new({ tiny.image_url => { visibility: 0.9, fill: below },
                             distant.image_url => { visibility: 0.9, fill: below } }),
      mirror: mirror
    )

    assert_equal 0, summary.chosen
    assert_equal({ "face_too_small" => 2 }, summary.refusals)
    assert_equal :alert, summary.flash_key
    assert_match "2 of 2 scored refused as face_too_small", summary.sentence
  end

  # The trainer's floor no longer starves the free sheet: a clear half-frame portrait is
  # a reference, and only the trainer refuses it.
  test "a face between the two floors is chosen for the sheet but not mint-ready" do
    photo = hit("https://cdn.example.com/portrait.jpg", position: 1)

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo]),
      faces: FakeFaces.new({ photo.image_url => { visibility: 0.85, fill: 0.5 } }), mirror: mirror
    )

    assert_equal 1, summary.chosen
    assert_equal 0, summary.mint_ready, "a sheet-only face is not trainer-ready"
    assert_match "0 of 1 clear the trainer's face-size floor", summary.sentence
    assert_equal :notice, summary.flash_key
  end

  # THE SENTENCE IS THE SUMMARY'S, not each controller's. It lived twice, verbatim, in
  # PhotoScoutingController and AppearancesController — so the clause above would have
  # had to be added in two places, and could have been added in one.
  test "the sentence names every number an operator needs, from one place" do
    photo = hit("https://cdn.example.com/a.jpg", position: 1)
    unsafe = hit("http://127.0.0.1/x.png", position: 2)

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(results: [photo, unsafe], unparsed: 2),
      faces: FakeFaces.new({ photo.image_url => { visibility: 0.9, fill: 0.7 } }), mirror: mirror
    )

    # FOUR SEARCHES, EIGHT ROWS, TWO UNIQUE. The fake answers every query with the same
    # pair, so this asserts the harvest arithmetic as well as the copy: `returned` counts
    # what the searches handed back and `unique` what survived the dedupe, and the clause
    # has to name both or the dedupe is invisible.
    assert_match "fake ran 4 search(es) for 8 result(s)", summary.sentence
    assert_match "2 unique after dropping 6 duplicate(s)", summary.sentence
    assert_match "in a shape we could not read", summary.sentence
    assert_match "1 refused as unsafe to fetch", summary.sentence
    assert_match "1 measured for face size", summary.sentence
    assert_match "1 chosen as references", summary.sentence
  end

  # THE DEDUPE IS NAMED ONLY WHEN IT DID SOMETHING. "0 duplicate(s)" on the happy path is
  # noise in the one sentence the operator reads after every click, and the happy path is
  # now the common one — measured 2026-09-27, "smiling" collided with the bare name on
  # nothing at all for one athlete.
  test "the sentence stays quiet about a dedupe that removed nothing" do
    per_query = queries_for("Josh Allen").each_with_index.to_h do |query, i|
      [query, [hit("https://cdn.example.com/#{i}.jpg", position: 1)]]
    end

    summary = Appearances::GatherReferencePhotos.call(
      @look, search: FakeSearch.new(per_query: per_query), faces: NoFaces
    )

    assert_equal 0, summary.duplicates
    assert_match "fake ran 4 search(es) for 4 result(s)", summary.sentence
    refute_match "duplicate", summary.sentence
  end
end
