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

    def initialize(results: [], unparsed: 0, available: true)
      @answer = Appearances::ImageSearch::Answer.new(
        results: results, unparsed_count: unparsed, provider_name: "fake"
      )
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
      @answer
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

  test "the provider is asked for the query the summary reports" do
    search = FakeSearch.new(results: [])
    summary = Appearances::GatherReferencePhotos.call(@look, search: search, faces: NoFaces, limit: 11)

    assert_equal [[summary.query, 11]], search.asked
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

    assert_equal [@look], search.targets
    assert_equal [@look], faces.targets
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
  # why a gallery looks wrong a day later is reading /admin/error_logs.
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
                 "the class name is what the operator scans /admin/error_logs for"
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

    assert_match "fake returned 2 result(s)", summary.sentence
    assert_match "2 in a shape we could not read", summary.sentence
    assert_match "1 refused as unsafe to fetch", summary.sentence
    assert_match "1 measured for face size", summary.sentence
    assert_match "1 chosen as references", summary.sentence
  end
end
