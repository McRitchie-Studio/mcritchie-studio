require "test_helper"

# [component] + [integration] THE PHOTO SCOUTING PAGE — the operator's acceptance test:
# "I should have a good idea of what the raw found images look like and which ones your
# taste is picking up to use into the model build."
#
# THE TIERS ARE SPLIT BY WHAT THEY PROVE, matching CharacterModelPageTest beside it.
#   [component]   the ERB renders the right STRUCTURE for a record state — which
#                 sections, which chips, which order, which controls.
#   [integration] the round trip: a verdict POST writes a row and the recomputed tally
#                 comes back from the server.
#
# ASSERTIONS SELECT ON `data-test` AND `data-*` STATE, not on copy. Prose inside a
# partial is page bytes, so an assertion on a sentence can be satisfied by a COMMENT
# that happens to contain it — structure cannot be satisfied by accident.
#
# NOTHING HERE REACHES THE NETWORK, AND THE `[control]` TEST PROVES IT rather than
# asserting it. A render must never spend, and the one test that drives #search injects
# a fake provider through the façade's own registry seam.
class PhotoScoutingPageTest < ActionDispatch::IntegrationTest
  Photo = AppearanceReferencePhoto

  setup do
    Appearance.delete_all
    Photo.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    @person.update!(default_appearance_slug: @look.slug)
  end

  def page_path = person_scouting_path(@person.slug)

  def file_photo(url, chosen: false, **rest)
    Photo.create!(appearance_slug: @look.slug, image_url: url,
                  source: Photo::SOURCE_SEARCH, chosen: chosen, **rest)
  end

  # THREE CANDIDATES IN A KNOWN PROVIDER ORDER, deliberately NOT the ranked order: the
  # winner is hit 3, so a page that showed the ranking in the raw column would show
  # [3,1,2] and fail the ordering test below.
  def file_three
    @loser = file_photo("https://example.com/1.jpg", position: 1, title: "Someone Else",
                        chosen: false, rejection_reason: Photo::REJECTED_BEYOND_LIMIT,
                        width: 3000, height: 2000, mime_type: "image/jpeg")
    @document = file_photo("https://example.com/2.pdf", position: 2, title: "A Book.pdf",
                           chosen: false, rejection_reason: Photo::REJECTED_NOT_A_PHOTO,
                           width: 600, height: 900, mime_type: "application/pdf")
    @winner = file_photo("https://example.com/3.jpg", position: 3, title: "Josh Allen",
                         chosen: true, width: 700, height: 900, mime_type: "image/jpeg",
                         face_score: 0.92)
  end

  # ── THE WRONG-PERSON REFUSAL, ON THE TILE ────────────────────────────────────────

  # CRITERION: "show why a photo was rejected as wrong person". The chip alone says "not
  # this person", which is an assertion the operator has to take on faith; the note names
  # the name we actually READ, so he can check it against the thumbnail and correct us when
  # the ARCHIVE is what is wrong.
  test "[component] a wrong-person reject names the name it was refused for" do
    file_photo("https://example.com/keenan.jpg", position: 1, title: "Keenan Allen.jpg",
               chosen: false, rejection_reason: Photo::REJECTED_WRONG_PERSON,
               width: 700, height: 900)

    get page_path

    assert_select "[data-test='wrong-person-note']", count: 1 do |nodes|
      assert_match "Keenan Allen", nodes.first.text
      assert_match "Josh Allen", nodes.first.text,
                   "naming only the stranger leaves the reader guessing who we wanted"
    end
    assert_select "figure[data-rejection='wrong_person']", count: 1
  end

  # THE CONTROL FOR THE CASE ABOVE. A tile for the right person must carry no accusation —
  # a note that rendered on every tile would be furniture rather than evidence.
  test "[component] a photograph of the right person carries no wrong-person note" do
    file_photo("https://example.com/josh.jpg", position: 1, title: "Josh Allen, 22 October 2023",
               chosen: true, width: 700, height: 900, face_score: 0.9, face_fill: 0.9)

    get page_path

    assert_select "[data-test='wrong-person-note']", count: 0
  end

  # ── THE TRAP ─────────────────────────────────────────────────────────────────────

  class NetworkReached < StandardError; end

  def with_no_network
    TCPSocket.stub(:open, ->(*) { raise NetworkReached, "the page tried to open a socket" }) do
      yield
    end
  end

  # PROVES THE TRAP IS LIVE AND THAT A RENDER DOES NOT SPEND.
  #
  # Two claims in one test, and both need the trap. "The page does not search" is exactly
  # the sort of thing that is asserted and never checked — the render asks
  # `ImageSearch.available?`, which is one refactor away from a round trip. The control
  # half is the socket stub reaching the real provider, proving the trap would catch it.
  test "[control] rendering the page opens no socket, and the trap would catch one" do
    file_three

    with_no_network do
      get page_path
      assert_response :success
    end

    # THE TRAP ITSELF STILL BITES. Without this the test above would stay green if the
    # stub silently stopped covering the path a search takes.
    assert_raises(NetworkReached) do
      with_no_network { Appearances::ImageSearch::WikimediaCommons.new.search(query: "Josh Allen") }
    end
  end

  # ── THE SHAPE OF THE PAGE ────────────────────────────────────────────────────────

  test "[component] the page answers both questions in their own sections" do
    file_three
    get page_path
    assert_response :success

    assert_select "[data-test='photo-scouting']", count: 1
    assert_select "[data-test='picks-section']", count: 1
    assert_select "[data-test='found-section']", count: 1
    assert_select "[data-test='calibration-panel']", count: 1
  end

  test "[component] it is readable without a session, like the person page" do
    file_three
    get page_path

    assert_response :success
    assert_select "[data-test='found-gallery'] [data-test='reference-photo']", count: 3
  end

  # THE ACCEPTANCE CRITERION "show every raw candidate as found". Both halves matter: the
  # COUNT (nothing is filtered out of the raw column) and the ORDER (it is the provider's,
  # not ours).
  test "[component] every raw candidate renders IN THE ORDER FOUND" do
    file_three
    get page_path

    assert_select "[data-test='found-gallery'] [data-test='reference-photo']", count: 3
    titles = css_select("[data-test='found-gallery'] [data-test='reference-photo'] figcaption p").map(&:text)
                .map(&:strip).reject(&:empty?)
    # The winner is hit 3 and is LAST here even though it leads the picks section — which
    # is the whole reason the raw column exists.
    assert_operator titles.index { |t| t.include?("Someone Else") }, :<,
                    titles.index { |t| t.include?("Josh Allen") },
                    "the raw column must keep the provider's order, not the ranking"
  end

  test "[component] the picks section shows only the chosen, with the cap named" do
    file_three
    get page_path

    assert_select "[data-test='picks-gallery'] [data-test='reference-photo']", count: 1
    assert_select "[data-test='picks-gallery'] [data-chosen='true']", count: 1
    assert_select "[data-test='chosen-limit-note']", count: 1
  end

  test "[component] every reject carries its reason, and the breakdown counts them" do
    file_three
    get page_path

    assert_select "[data-test='found-gallery'] [data-rejection='beyond_limit']", count: 1
    assert_select "[data-test='found-gallery'] [data-rejection='not_a_photo']", count: 1
    assert_select "[data-test='rejection-breakdown']", count: 1
  end

  test "[component] per-image detail enough to argue with is on every tile" do
    file_three
    get page_path

    # THE FOUR FACTS THE OPERATOR ASKED FOR: title, source, dimensions, face score. The
    # title is the one that catches a clear photograph of the WRONG PERSON, which no score
    # on this page can.
    assert_select "[data-test='found-gallery'] [data-source='search']", count: 3
    assert_select "[data-test='merit-reasons']", minimum: 3
    body = response.body
    assert_includes body, "Someone Else"
    assert_includes body, "3000x2000"
    assert_includes body, "application/pdf"
    assert_includes body, "face 92"
  end

  # ── THE DEFECTS IT MUST NOT HIDE ─────────────────────────────────────────────────

  test "[component] both known defects are named on the page" do
    # A CALIBRATION PAGE THAT HID ITS MODEL'S WORST FAILURES would have the operator tune
    # his judgement against a machine that does not behave the way the page implied.
    file_three
    get page_path

    assert_select "[data-test='scouting-honesty']", count: 1
    assert_select "[data-test='defect-wrong-person']", count: 1
    assert_select "[data-test='defect-cannot-mint']", count: 1
  end

  test "[component] the ranking basis says when NOTHING looked at the photographs" do
    # `face_score` nil on every row means no classifier ran, and the operator must not
    # read a merit ordering as a face judgement.
    file_photo("https://example.com/unscored.jpg", position: 1, chosen: true)
    get page_path

    assert_select "[data-test='ranking-basis'][data-basis='merit']", count: 1
  end

  test "[component] the ranking basis says face when the classifier DID run" do
    file_three
    get page_path

    assert_select "[data-test='ranking-basis'][data-basis='face']", count: 1
  end

  # ── THE ADMIN GATES ──────────────────────────────────────────────────────────────

  test "[component] a visitor is offered NO spending button" do
    file_three
    get page_path

    assert_select "[data-test='scouting-search-button']", { count: 0 },
                  "hub signup is open, so a button shown to everyone is a purchase offered to everyone"
    assert_select "[data-test='verdict-control']", count: 0
  end

  test "[component] an admin is offered the search button and the verdict controls" do
    log_in_as(users(:alex))
    file_three
    get page_path

    assert_select "[data-test='scouting-search-button']", count: 1
    assert_select "[data-test='verdict-control']", minimum: 3
  end

  test "[integration] a non-admin session cannot search or record a verdict" do
    # A SESSION IS NOT A COST CONTROL: magic-link and Google are both create-or-login, so
    # this is the gate that costs something to get through.
    file_three
    log_in_as(users(:viewer))

    post search_person_scouting_path(@person.slug)
    assert_response :redirect

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @winner.slug, verdict: "drop" }
    assert_response :redirect
    assert_nil @winner.reload.operator_verdict
  end

  test "[integration] a visitor with no session cannot record a verdict" do
    file_three

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @winner.slug, verdict: "keep" }

    assert_response :redirect
    assert_nil @winner.reload.operator_verdict
  end

  # ── THE CALIBRATION ROUND TRIP ───────────────────────────────────────────────────

  test "[integration] an admin verdict is stored and the server returns the new tally" do
    log_in_as(users(:alex))
    file_three

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @loser.slug, verdict: "keep" }, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal "keep", @loser.reload.operator_verdict
    assert_not_nil @loser.operator_verdict_at
    # A KEEP ON A REJECTED PHOTOGRAPH IS A PROMOTION — the cell worth collecting.
    assert_equal "operator_promoted", body["state"]
    assert_equal 1, body["tally"]["promotions"]
    assert_equal 1, body["tally"]["judged"]
    assert_equal 3, body["tally"]["total"]
    assert_equal 0, body["tally"]["agreement_rate"]
  end

  test "[integration] agreeing with a pick counts as agreement, not as a promotion" do
    log_in_as(users(:alex))
    file_three

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @winner.slug, verdict: "keep" }, as: :json

    body = response.parsed_body
    assert_equal "agreed_keep", body["state"]
    assert_equal 0, body["tally"]["promotions"]
    assert_equal 100, body["tally"]["agreement_rate"]
  end

  test "[integration] re-sending the same verdict clears it" do
    # THE FASTEST CORRECTION FOR A MISCLICK IS THE BUTTON YOU JUST PRESSED, and "no
    # opinion" has to stay reachable or the first click on a tile is permanent.
    log_in_as(users(:alex))
    file_three

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @winner.slug, verdict: "keep" }, as: :json
    assert_equal "keep", @winner.reload.operator_verdict

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @winner.slug, verdict: "keep" }, as: :json

    assert_nil @winner.reload.operator_verdict
    assert_nil @winner.operator_verdict_at
    assert_equal 0, response.parsed_body["tally"]["judged"]
    assert_nil response.parsed_body["tally"]["agreement_rate"]
  end

  test "[integration] an unknown verdict word is refused and stores nothing" do
    log_in_as(users(:alex))
    file_three

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: @winner.slug, verdict: "promote" }, as: :json

    assert_response :unprocessable_entity
    assert_nil @winner.reload.operator_verdict
  end

  test "[integration] a candidate on ANOTHER look cannot be judged through this person" do
    # THE LOOKUP IS SCOPED TO THE RESOLVED LOOK, so a slug from elsewhere is a 404 rather
    # than a write into somebody else's calibration data.
    log_in_as(users(:alex))
    file_three
    other_look = Appearance.create!(person_slug: @person.slug, descriptor: "away")
    stranger = Photo.create!(appearance_slug: other_look.slug, source: Photo::SOURCE_SEARCH,
                             image_url: "https://example.com/stranger.jpg")

    post verdict_person_scouting_path(@person.slug),
         params: { photo_slug: stranger.slug, verdict: "keep" }, as: :json

    assert_response :not_found
    assert_nil stranger.reload.operator_verdict
  end

  # ── WHICH VARIANT FOUND EACH PHOTOGRAPH ──────────────────────────────────────────
  #
  # THE OPERATOR'S REQUIREMENT, and he judges this pipeline by this page: a candidate with
  # no provenance is one he cannot calibrate a variant against. A tile carrying a laugh he
  # likes is an argument for keeping "laughing"; the same tile with no label argues nothing.
  #
  # THE FIXTURE SPELLS THE QUERIES THE WAY THE SERVICE WOULD, from the constant, so a test
  # here cannot pass against a stale copy of the variant list.

  def queries_for(subject)
    Appearances::GatherReferencePhotos::QUERY_VARIANTS.map do |variant|
      [subject, variant].compact_blank.join(" ")
    end
  end

  # THE SUBJECT AS THIS LOOK ACTUALLY RESOLVES IT — the athlete fixture carries a
  # `team_slug`, and the subject now carries the team it humanises to, so a hard-coded
  # "Josh Allen" would file rows whose query the page could not shorten.
  def look_subject = Appearances::GatherReferencePhotos.new(@look).query

  def file_one_per_variant
    queries_for(look_subject).each_with_index.map do |query, i|
      file_photo("https://example.com/v#{i}.jpg", position: i + 1, title: "Josh Allen",
                 query: query, chosen: i.zero?, width: 700, height: 900)
    end
  end

  test "[component] every tile names the search that found it" do
    file_one_per_variant
    get page_path

    # SCOPED TO THE RAW COLUMN, because a chosen candidate appears in BOTH galleries and
    # carries its provenance in each — which is right, and is why the count is scoped
    # rather than the chip made conditional.
    assert_select "[data-test='found-gallery'] [data-test='found-by-variant']", count: 4
    assert_select "[data-test='picks-gallery'] [data-test='found-by-variant']", count: 1
    text = css_select("[data-test='found-gallery'] [data-test='found-by-variant']").map { |n| n.text.squish }
    # THE VARIANT, NOT THE WHOLE QUERY. "Josh Allen Buffalo Bills no helmet" on a
    # thumbnail-sized tile is unreadable; "no helmet" is what he says out loud.
    assert_includes text, "found by no helmet"
    assert_includes text, "found by laughing"
    assert_includes text, "found by smiling"
    assert_includes text, "found by name only",
                    "the bare-name variant must be named, not rendered as a blank"
  end

  # THE WHOLE QUERY IS STILL REACHABLE, in the tooltip, because the subject carries the
  # TEAM — and the team silently leaving the query is the defect this task also fixed. A
  # page that showed only the suffix could not show that it is back.
  test "[component] the tile's tooltip carries the whole query, team and all" do
    file_one_per_variant
    get page_path

    titles = css_select("[data-test='found-by-variant']").map { |n| n["title"].to_s }
    assert titles.all? { |t| t.include?(look_subject) },
           "the subject, which carries the team, has to be readable somewhere on the tile"
  end

  # THE ROW THE OPERATOR TUNES THE VARIANT LIST FROM. Counts per variant, over the rows
  # rather than over a summary, because the summary exists only inside the request that
  # ran the search and he reads this page long afterwards.
  test "[component] a per-variant breakdown counts what each search contributed" do
    file_one_per_variant
    get page_path

    assert_select "[data-test='variant-breakdown']", count: 1
    rows = css_select("[data-test='variant-row']")
    assert_equal 4, rows.length
    assert_equal %w[1 1 1 1], rows.map { |r| r["data-variant-found"] }
    assert_equal %w[1 0 0 0], rows.map { |r| r["data-variant-chosen"] },
                 "only the first tile was chosen, and the breakdown must say so per variant"
  end

  # ⚠ A VARIANT THAT FOUND NOTHING IS THE MOST USEFUL LINE ON THE PAGE — it is the query
  # to drop — so it is rendered as a zero rather than omitted. Grouping the ROWS alone
  # would render it as absence, which reads as "not asked" rather than "asked and came
  # back empty", and those two have opposite remedies.
  test "[component] a variant that contributed nothing still gets a row, at zero" do
    queries = queries_for(look_subject)
    file_photo("https://example.com/only.jpg", position: 1, query: queries.first, chosen: true)

    get page_path

    rows = css_select("[data-test='variant-row']")
    assert_equal 4, rows.length, "all four are listed even though three found nothing"
    assert_equal %w[1 0 0 0], rows.map { |r| r["data-variant-found"] }
  end

  # A ROW FILED BEFORE THE FAN-OUT LANDED carries the OLD single query, which is the
  # bare-name variant's spelling exactly — so it groups under it rather than into a
  # mystery bucket, and a gallery of pre-fan-out rows reads as one variant's work because
  # that is what it was.
  test "[component] rows from before the fan-out group under the bare-name variant" do
    file_photo("https://example.com/old.jpg", position: 1, query: look_subject, chosen: true)

    get page_path

    rows = css_select("[data-test='variant-row']")
    assert_equal "1", rows.first["data-variant-found"]
    assert_equal %w[0 0 0], rows.drop(1).map { |r| r["data-variant-found"] }
  end

  # A ROW WHOSE QUERY MATCHES NO CURRENT VARIANT IS COLLECTED, NOT DROPPED. A traded
  # player's old rows carry the old team in their subject, and a candidate visible in the
  # gallery but in no breakdown row would make the counts disagree with the tiles.
  test "[component] a row from a query we no longer ask is still accounted for" do
    file_photo("https://example.com/stale.jpg", position: 1, chosen: false,
               query: "Josh Allen Denver Broncos winking")

    get page_path

    rows = css_select("[data-test='variant-row']")
    assert_equal 5, rows.length, "four variants plus one row for the query we retired"
    assert_equal "1", rows.last["data-variant-found"]
  end

  # EVERY QUERY THE BUTTON WOULD BUY IS PRINTED. He cannot judge searches whose questions
  # he cannot see, and the count alone would hide both the expression words and the team.
  test "[component] the header lists all four queries, not a count" do
    get page_path

    assert_select "[data-test='search-queries'] li", count: 4
    listed = css_select("[data-test='search-queries'] li").map { |n| n.text.squish }
    queries_for(look_subject).each do |query|
      assert listed.any? { |line| line.include?(query) }, "#{query.inspect} is not on the page"
    end
  end

  # THE TWO CEILINGS, STATED WITH THEIR CONSTANTS. The operator's calibration depends on
  # knowing that most of what a search found was never looked at — otherwise he reads
  # `face_unscored` as a judgement of the photograph.
  test "[component] the page states the vision ceiling as well as the chosen cap" do
    file_three
    get page_path

    assert_select "[data-test='vision-ceiling-note']", count: 1
    assert_select "[data-test='fan-out-note']", count: 1
    body = response.body
    assert_includes body, Appearances::GatherReferencePhotos::VISION_SHORTLIST.to_s
    assert_includes body, "CHOSEN_LIMIT = #{Appearances::GatherReferencePhotos::CHOSEN_LIMIT}"
  end

  # ── THE SEARCH ACTION ────────────────────────────────────────────────────────────

  test "[integration] an admin search files every candidate and reports the count" do
    log_in_as(users(:alex))

    # A FAKE PROVIDER THROUGH THE FAÇADE'S OWN REGISTRY SEAM — the reason
    # `ImageSearch.providers` is a method and not a frozen constant. Nothing here can
    # reach a network even if the trap were removed.
    # ⚠ IT ANSWERS EVERY QUERY WITH THE SAME TWO ROWS, which is why the counts below are
    # 8 bought and 2 filed: four searches really do cost four queries, and the dedupe
    # really does collapse their identical answers to two photographs. A fake that
    # answered once would hide both halves.
    fake = Class.new do
      def self.provider_name = "fake-archive"
      def self.available? = true
      def self.search(query:, limit: 20)
        results = [
          Appearances::ImageSearch::Result.new(image_url: "https://example.com/a.jpg",
                                               title: "Josh Allen", width: 700, height: 900,
                                               position: 1, mime: "image/jpeg"),
          Appearances::ImageSearch::Result.new(image_url: "https://example.com/b.pdf",
                                               title: "A Book.pdf", width: 600, height: 900,
                                               position: 2, mime: "application/pdf")
        ]
        Appearances::ImageSearch::Answer.new(results: results, unparsed_count: 0,
                                            provider_name: provider_name)
      end
    end

    Appearances::ImageSearch.stub(:providers, [fake]) do
      assert_difference -> { Photo.count }, 2 do
        post search_person_scouting_path(@person.slug)
      end
    end

    assert_redirected_to page_path
    assert_match(/fake-archive ran 4 search\(es\) for 8 result\(s\)/, flash[:notice])
    assert_match(/2 unique after dropping 6 duplicate\(s\)/, flash[:notice])
    # THE MIME TYPE IS PERSISTED, so the page can print the archive's own claim.
    assert_equal "application/pdf", Photo.find_by(image_url: "https://example.com/b.pdf").mime_type
    # AND THE DOCUMENT IS NOT IN THE MODEL. A scanned page is not a poor reference.
    refute Photo.find_by(image_url: "https://example.com/b.pdf").chosen?
  end

  # Production 2026-09-28 (Justin Jefferson): every scored candidate refused on face size
  # and the page flashed green without naming why.
  test "[integration] a search whose every candidate is too small says why, as an alert" do
    log_in_as(users(:alex))
    fake = Class.new do
      def self.provider_name = "fake-archive"
      def self.available? = true
      def self.search(query:, limit: 20)
        results = [Appearances::ImageSearch::Result.new(image_url: "https://example.com/far.jpg",
                                                        title: "Josh Allen", width: 700,
                                                        height: 900, position: 1,
                                                        mime: "image/jpeg")]
        Appearances::ImageSearch::Answer.new(results: results, unparsed_count: 0,
                                            provider_name: provider_name)
      end
    end
    hosted = "https://bucket.example.com/far.png"
    small = Appearances::FaceVisibility::Judgement.new(visibility: 0.9, fill: 0.2, subjects: 1)

    Appearances::ImageSearch.stub(:providers, [fake]) do
      Appearances::MirrorCandidates.stub(:call, ->(*, **) { { "https://example.com/far.jpg" => hosted } }) do
        Appearances::FaceVisibility.stub(:available?, true) do
          Appearances::FaceVisibility.stub(:call, ->(*, **) { { hosted => small } }) do
            post search_person_scouting_path(@person.slug)
          end
        end
      end
    end

    assert_redirected_to page_path
    assert_nil flash[:notice]
    assert_match(/0 chosen as references - 1 of 1 scored refused as face_too_small/, flash[:alert])
  end

  test "[integration] a search that finds nothing changes nothing and says so" do
    log_in_as(users(:alex))
    empty = Class.new do
      def self.provider_name = "fake-archive"
      def self.available? = true
      def self.search(query:, limit: 20) = Appearances::ImageSearch::Answer.empty(provider_name: provider_name)
    end

    Appearances::ImageSearch.stub(:providers, [empty]) do
      assert_no_difference -> { Photo.count } do
        post search_person_scouting_path(@person.slug)
      end
    end

    assert_match(/returned nothing/, flash[:alert])
  end

  # ── WHAT THE PAGE SAYS ABOUT AN UNRANKED GALLERY ─────────────────────────────────
  #
  # TWO STATES, NOT ONE. "Nothing looked at these" was the whole message before
  # 2026-09-26, and it reads as "no credential" — which was TRUE of every machine then
  # and a LIE about the production run that had a key, sent eight images and was refused
  # on all eight. The operator trusted the ordering because the page gave them no reason
  # not to.

  test "[component] an unranked gallery with NO classifier says the credential is missing" do
    file_three
    Photo.update_all(face_score: nil)

    Appearances::FaceVisibility.stub(:available?, false) { get page_path }

    assert_select "[data-test='classifier-absent']", count: 1
    assert_select "[data-test='classifier-silent']", count: 0
  end

  test "[component] an unranked gallery with a CONFIGURED classifier says it went silent" do
    file_three
    Photo.update_all(face_score: nil)

    Appearances::FaceVisibility.stub(:available?, true) { get page_path }

    assert_select "[data-test='classifier-silent']", { count: 1 },
                  "a configured classifier that scored nothing must not read as a missing key"
    assert_select "[data-test='classifier-absent']", count: 0
  end

  # THE ERROR-LOG LINK IS ADMIN-ONLY, because /error_logs is behind require_admin and a
  # link that bounces the reader to a sign-in wall is worse than no link.
  test "[component] only an admin is offered the error-log link on a silent classifier" do
    file_three
    Photo.update_all(face_score: nil)

    Appearances::FaceVisibility.stub(:available?, true) { get page_path }
    assert_select "[data-test='classifier-silent'] a[href=?]", error_logs_path, count: 0

    log_in_as(users(:alex))
    Appearances::FaceVisibility.stub(:available?, true) { get page_path }
    assert_select "[data-test='classifier-silent'] a[href=?]", error_logs_path, count: 1
  end

  # ── THE CLASSIFIER LANE, END TO END THROUGH THE ACTION ───────────────────────────
  #
  # MEASURED ON PRODUCTION 2026-09-26, and these two tests are that run's two halves.
  # Anthropic answered 400 on every image — "Unable to download the file" — because
  # Wikimedia refuses a request with no User-Agent and Anthropic's fetcher was the
  # party refused. The classifier degraded to an empty Hash as documented, ranking fell
  # back to shape and title, six photographs entered the character model, and THREE
  # WERE AIRCRAFT. The operator read it off this page before we did, because this page
  # reported a green notice.
  #
  # ONLY THE TWO NETWORK COLLABORATORS ARE STUBBED. The controller, the flash choice,
  # GatherReferencePhotos and the ErrorLog row are all the real thing — which is the
  # point: the defect was in what the real wiring REPORTED, so a test that stubbed the
  # reporting would have proved nothing.

  # A provider whose two hits are both real photographs, so both reach the shortlist.
  def two_photo_provider
    Class.new do
      def self.provider_name = "fake-archive"
      def self.available? = true
      def self.search(query:, limit: 20)
        results = [
          Appearances::ImageSearch::Result.new(image_url: "https://upload.wikimedia.org/a.png",
                                              title: "Josh Allen", width: 700, height: 900,
                                              position: 1, mime: "image/png"),
          Appearances::ImageSearch::Result.new(image_url: "https://upload.wikimedia.org/b.png",
                                              title: "Josh Allen", width: 700, height: 900,
                                              position: 2, mime: "image/png")
        ]
        Appearances::ImageSearch::Answer.new(results: results, unparsed_count: 0,
                                            provider_name: provider_name)
      end
    end
  end

  # A mirror that copies nothing but answers the shape the real one does, plus the
  # classifier's answer, and a record of what the classifier was actually shown.
  def with_scouting_lane(provider:, scores:, shown:, mirror_fails: [])
    mirror = lambda do |photos, target: nil|
      photos.reject { |photo| mirror_fails.include?(photo.image_url) }
            .to_h { |photo| [photo.image_url, "https://bucket.s3.test/mirror/#{photo.slug}.png"] }
    end
    faces = lambda do |urls, target: nil|
      shown.concat(urls)
      scores.call(urls)
    end

    Appearances::ImageSearch.stub(:providers, [provider]) do
      Appearances::MirrorCandidates.stub(:call, mirror) do
        Appearances::FaceVisibility.stub(:available?, true) do
          Appearances::FaceVisibility.stub(:call, faces) { yield }
        end
      end
    end
  end

  test "[integration] a classifier that scored none of its inputs warns on the page" do
    log_in_as(users(:alex))
    shown = []

    assert_difference -> { ErrorLog.count }, 1 do
      with_scouting_lane(provider: two_photo_provider, scores: ->(_urls) { {} }, shown: shown) do
        post search_person_scouting_path(@person.slug)
      end
    end

    assert_redirected_to page_path
    # THE FLASH IS AN ALERT, NOT A NOTICE. The run "succeeded" — two candidates were
    # filed and an identity can be built from them — so a green notice is precisely
    # what let a confidently wrong result read as a good one.
    refute_match(/fake-archive returned/, flash[:notice].to_s,
                 "a blind classifier must not be reported as good news — note the " \
                 "sign-in notice is still in the flash, so this asks whether the " \
                 "SEARCH's own sentence arrived as a notice, not whether any did")
    assert_match(/FACE CLASSIFIER SAW NOTHING/, flash[:alert])
    assert_match(/0 of 2 shortlisted/, flash[:alert])
    assert_match(/2 mirrored and sent/, flash[:alert],
                 "the numbers separate a classifier failure from a mirror failure")
    # AND THE DURABLE HALF. A flash lives for one redirect; the operator working out a
    # week later why a gallery looks wrong is reading /admin/error_logs.
    row = ErrorLog.order(:id).last
    assert_equal @look, row.target
    assert_match(/scored 0 of 2 shortlisted/, row.message)
    # THE PAGE STILL WORKS. This degrades — it must cost an ordering, never the page.
    assert_equal 2, Photo.count
  end

  test "[integration] the classifier is shown our mirrored copy, never the provider's URL" do
    log_in_as(users(:alex))
    shown = []
    # THE REAL VALUE OBJECT, not a bare Float. Appearances::FaceVisibility answers a
    # Judgement per image — a visibility, a face SIZE and a subject count — and a stub that
    # answered the old scalar would keep this test green through a ranking that can no
    # longer read the answer at all.
    judged = ->(urls) {
      urls.index_with do
        Appearances::FaceVisibility::Judgement.new(visibility: 0.9, fill: 0.8, subjects: 1)
      end
    }

    with_scouting_lane(provider: two_photo_provider, scores: judged, shown: shown) do
      post search_person_scouting_path(@person.slug)
    end

    assert_equal 2, shown.length
    assert shown.all? { |url| url.start_with?("https://bucket.s3.test/mirror/") },
           "the classifier was handed #{shown.inspect} — any upload.wikimedia.org URL " \
           "here is the production defect: that host answers 403 to a fetcher sending " \
           "no User-Agent, and the silent degrade put three aircraft in a model"
    refute shown.any? { |url| url.include?("upload.wikimedia.org") }

    # A HEALTHY LANE IS STILL A NOTICE, so the alert above means something.
    assert_match(/2 measured for face size/, flash[:notice])
    assert_nil flash[:alert]
    # AND EVERY MEMBER OF THE ANSWER LANDS ON THE ROW KEYED BY THE PROVIDER'S URL, which is
    # what the gallery, the rejection reasons and both eligibility verdicts read.
    row = Photo.find_by!(image_url: "https://upload.wikimedia.org/a.png")
    assert_in_delta 0.9, row.face_score, 0.001
    assert_in_delta 0.8, row.face_fill, 0.001, "the face SIZE is the measurement a mint turns on"
    assert_equal 1, row.face_subjects
    assert row.mint_eligible?(@person.full_name), "a measured, visible, single face may train"
  end

  # A TOTAL MIRROR FAILURE IS THE SAME CLASS OF SILENCE and must be just as loud —
  # otherwise "the mirror copied nothing, so we sent nothing, so there was nothing to
  # do" reads as a clean run.
  test "[integration] a mirror that copied nothing is as loud as a blind classifier" do
    log_in_as(users(:alex))
    shown = []
    both = ["https://upload.wikimedia.org/a.png", "https://upload.wikimedia.org/b.png"]

    with_scouting_lane(provider: two_photo_provider, scores: ->(_urls) { {} },
                       shown: shown, mirror_fails: both) do
      post search_person_scouting_path(@person.slug)
    end

    assert_empty shown, "nothing mirrored means nothing is paid to be classified"
    assert_match(/0 mirrored and sent/, flash[:alert])
    refute_match(/fake-archive returned/, flash[:notice].to_s)
  end

  # ── A PERSON WITH NO LOOK ────────────────────────────────────────────────────────

  test "[component] a person with no look explains itself rather than 404ing" do
    # A PERSON PAGE LINKS HERE, so a dead link would read as a broken feature.
    Photo.delete_all
    @look.destroy
    @person.update!(default_appearance_slug: nil)

    get page_path

    assert_response :success
    assert_select "[data-test='no-look']", count: 1
    assert_select "[data-test='found-gallery']", count: 0
  end
end
