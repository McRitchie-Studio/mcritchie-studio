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

  # ── THE SEARCH ACTION ────────────────────────────────────────────────────────────

  test "[integration] an admin search files every candidate and reports the count" do
    log_in_as(users(:alex))

    # A FAKE PROVIDER THROUGH THE FAÇADE'S OWN REGISTRY SEAM — the reason
    # `ImageSearch.providers` is a method and not a frozen constant. Nothing here can
    # reach a network even if the trap were removed.
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
    assert_match(/fake-archive returned 2 result/, flash[:notice])
    # THE MIME TYPE IS PERSISTED, so the page can print the archive's own claim.
    assert_equal "application/pdf", Photo.find_by(image_url: "https://example.com/b.pdf").mime_type
    # AND THE DOCUMENT IS NOT IN THE MODEL. A scanned page is not a poor reference.
    refute Photo.find_by(image_url: "https://example.com/b.pdf").chosen?
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
