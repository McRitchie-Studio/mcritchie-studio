require "test_helper"

# [component] + [integration] THE CHARACTER-MODEL PAGE — the operator's whole
# acceptance test for this lane: "I want to see the images found on the internet and
# the output on the same UI."
#
# THE TIERS ARE SPLIT BY WHAT THEY PROVE, not by file.
#   [component]   the ERB renders the right STRUCTURE for a given record state —
#                 which galleries exist, which chips, which panel.
#   [integration] the request/response round trip across the persistence and the
#                 injected search seam: a click files rows and the next render shows
#                 them.
#
# THE ASSERTIONS SELECT ON `data-test` AND `data-*` STATE, not on copy. Caption prose
# is going to be reworded — and prose inside a partial is page bytes, so an assertion
# on a sentence can be satisfied by a COMMENT that happens to contain it. Structure
# cannot be satisfied by accident.
#
# NOTHING HERE REACHES THE NETWORK. The page never searches (a render must not spend
# money), and the one test that drives the search action injects a fake through the
# controller's collaborator.
class CharacterModelPageTest < ActionDispatch::IntegrationTest
  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  def cache_headshot
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "400",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/400.png",
                       content_type: "image/png")
  end

  def file_photo(url, chosen: true, **rest)
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, image_url: url,
                                     source: AppearanceReferencePhoto::SOURCE_SEARCH,
                                     chosen: chosen, **rest)
  end

  def page_path = person_appearance_path(@person.slug, @look.slug)

  # A VENDOR THAT CANNOT BE REACHED, standing in for Higgsfield refusing. Injected by
  # stubbing `.new` rather than by reaching for a mock, so nothing in this file can
  # open a socket even if the stub is removed by mistake.
  class ExplodingMint
    def initialize(*, **); end
    def call(*) = raise(StandardError, "Higgsfield said 402 insufficient credits")
  end

  # ---- the shape of the page -------------------------------------------------

  # THE ACCEPTANCE TEST ITSELF. Both halves, on one page, with the direction between
  # them. If this fails, the page has stopped answering the question it was built for.
  test "[component] both halves and the direction between them render on one page" do
    cache_headshot
    get page_path
    assert_response :success

    assert_select "[data-test='reference-input-panel']", count: 1
    assert_select "[data-test='model-output-panel']", count: 1
    assert_select "[data-test='pipeline-arrow']", count: 1
  end

  test "[component] the page is reachable without a session, like the person page" do
    cache_headshot
    get page_path
    assert_response :success
  end

  # ---- the input half --------------------------------------------------------

  # THE REJECTS ARE RENDERED, and this is the assertion that defends the whole
  # reason they are stored. A gallery of winners cannot answer "is the search any
  # good?", so a change that quietly stopped showing them would gut the page while
  # leaving it looking fine.
  test "[component] rejected candidates render beside the chosen ones, with their reason" do
    cache_headshot
    file_photo("https://cdn.example.com/kept.jpg", chosen: true, position: 1)
    file_photo("https://cdn.example.com/passed.jpg", chosen: false, position: 2,
               rejection_reason: AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT)
    file_photo("https://cdn.example.com/dupe.jpg", chosen: false, position: 3,
               rejection_reason: AppearanceReferencePhoto::REJECTED_DUPLICATE)

    get page_path

    assert_select "[data-test='chosen-gallery'] [data-test='reference-photo']", { count: 2 },
                  "the headshot floor plus the one chosen hit"
    assert_select "[data-test='rejected-gallery'] [data-test='reference-photo']", count: 2
    assert_select "[data-rejection='#{AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT}']", count: 1
    assert_select "[data-rejection='#{AppearanceReferencePhoto::REJECTED_DUPLICATE}']", count: 1
  end

  test "[component] each photo is labelled with where it came from" do
    cache_headshot
    @look.update!(reference_url: "https://example.com/operator.jpg")
    file_photo("https://cdn.example.com/found.jpg")

    get page_path

    assert_select "[data-source='#{AppearanceReferencePhoto::SOURCE_HEADSHOT}']", count: 1
    assert_select "[data-source='#{AppearanceReferencePhoto::SOURCE_OPERATOR}']", count: 1
    assert_select "[data-source='#{AppearanceReferencePhoto::SOURCE_SEARCH}']", count: 1
  end

  # A URL WE REFUSED TO HAND A REMOTE FETCHER IS NOT HANDED TO THE OPERATOR'S BROWSER
  # EITHER. An img tag makes the same request from a machine INSIDE our network,
  # which is the one place a loopback or private-range URL must never be fetched
  # from. The tile shows the address as text instead.
  test "[component] a candidate refused as unsafe is never emitted as an image src" do
    cache_headshot
    file_photo("http://127.0.0.1:9999/internal-probe.png", chosen: false,
               rejection_reason: AppearanceReferencePhoto::REJECTED_UNFETCHABLE)

    get page_path

    assert_select "[data-rejection='#{AppearanceReferencePhoto::REJECTED_UNFETCHABLE}']", count: 1
    assert_select "img[src='http://127.0.0.1:9999/internal-probe.png']", count: 0
    assert_select "a[href='http://127.0.0.1:9999/internal-probe.png']", count: 0
  end

  # ---- the unconfigured degrade ---------------------------------------------

  # THE PATH THAT RUNS TODAY, on every machine, because no serper.dev credential
  # exists anywhere. It must be a finished-looking page, not an error and not a stub.
  # SIGNED IN AS AN ADMIN ON PURPOSE. The `search-button count: 0` assertion below
  # claims "an absent provider offers no purchase" — and a non-admin session would
  # satisfy it for the OTHER reason, leaving the sentence true and the test inert.
  test "[integration] with no search provider the page renders the headshot floor and names the env var" do
    log_in_as(users(:alex))
    cache_headshot
    Appearances::ImageSearch.stub(:available?, false) do
      Appearances::ImageSearch.stub(:provider_name, nil) do
        get page_path
      end
    end

    assert_response :success
    assert_select "[data-test='search-unconfigured']", count: 1
    assert_select "[data-test='search-button']", { count: 0 },
                  "an absent provider offers no purchase"
    assert_select "[data-test='chosen-gallery'] [data-test='reference-photo']", count: 1
    assert_includes response.body, Appearances::ImageSearch::Serper::API_KEY_ENV,
                    "the reader of this message is who will set the credential"
  end

  # A PERSON WITH NO PHOTOGRAPHS AT ALL is a real state, not a failure: the mint
  # service raises rather than building an identity from nothing, so the page has to
  # say so instead of offering a button that cannot work.
  test "[integration] a look with no photographs renders a warning and no live mint button" do
    # AS AN ADMIN, because the disabled button is what an admin who may mint sees
    # when there is nothing to mint FROM. A non-admin is shown no button at all, for
    # a different reason, and asserting the absence would prove the wrong thing.
    log_in_as(users(:alex))
    get page_path

    assert_response :success
    assert_select "[data-test='no-photos']", count: 1
    assert_select "[data-test='chosen-gallery']", count: 0
    assert_select "button[type='submit'][disabled]", { minimum: 1 },
                  "the mint button must not offer a purchase that would raise"
  end

  # ---- the output half -------------------------------------------------------

  test "[component] a look with no identity says so rather than showing a blank panel" do
    cache_headshot
    get page_path

    assert_select "[data-test='identity-status'][data-state='none']", count: 1
  end

  test "[component] a ready identity shows its id and the number of photos it was built from" do
    cache_headshot
    file_photo("https://cdn.example.com/found.jpg")
    @look.update!(higgsfield_reference_id: "1af15765-4e2c-4f91-9c3a-0b6d7e8f9a01",
                  higgsfield_reference_status: "completed",
                  higgsfield_reference_synced_at: Time.current)

    get page_path

    assert_select "[data-test='identity-status'][data-state='ready']", count: 1
    assert_includes response.body, "1af15765-4e2c-4f91-9c3a-0b6d7e8f9a01"
    assert_includes response.body, "2 photos", "the headshot plus the chosen hit"
  end

  # A STATUS WORD WE HAVE NEVER SEEN IS NOT A SUCCESS. Appearance's own comment makes
  # the same argument for `higgsfield_reference_ready?`; this asserts the PAGE agrees
  # rather than rendering an unrecognised state as quietly fine.
  test "[component] an unrecognised vendor status renders as unknown, not as ready" do
    cache_headshot
    @look.update!(higgsfield_reference_id: "1af15765-4e2c-4f91-9c3a-0b6d7e8f9a01",
                  higgsfield_reference_status: "exploded")

    get page_path

    assert_select "[data-test='identity-status'][data-state='unknown']", count: 1
    assert_select "[data-test='identity-status'][data-state='ready']", count: 0
  end

  test "[component] images generated against the identity render in the output half" do
    cache_headshot
    @look.update!(higgsfield_reference_id: "1af15765-4e2c-4f91-9c3a-0b6d7e8f9a01",
                  higgsfield_reference_status: "completed")
    shot = Artifact.create!(kind: "character_sheet", image_url: "/icon.png", source: "higgsfield")
    shot.subjects.create!(person_slug: @person.slug, appearance_slug: @look.slug, ordinal: 1)

    get page_path

    assert_select "[data-test='model-output-panel'] [data-test='generated-images'] figure", count: 1
  end

  # ---- reachability ----------------------------------------------------------

  # THE OPERATOR MUST REACH THIS PAGE BY CLICKING. A page you can only get to by
  # typing a URL is a page that does not exist for the person it was built for.
  test "[integration] every look on the person page links to its character model" do
    cache_headshot
    Appearance.create!(person_slug: @person.slug, descriptor: "Navy suit")

    get person_path(@person.slug)

    assert_response :success
    assert_select "[data-test='character-model-link']", count: 2
    assert_select "a[data-test='character-model-link'][href='#{page_path}']", count: 1
  end

  # ---- the search round trip -------------------------------------------------

  # THE WRITE HALF, END TO END: a click runs the injected search, files every
  # candidate with its verdict, and the next render shows both halves. The fake
  # cannot reach the network, so this buys nothing.
  test "[integration] searching files every candidate and the page then shows both halves" do
    log_in_as(users(:alex))
    cache_headshot
    limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    results = (1..(limit + 2)).map do |i|
      Appearances::ImageSearch::Result.new(image_url: "https://cdn.example.com/#{i}.jpg", position: i)
    end
    answer = Appearances::ImageSearch::Answer.new(results: results, unparsed_count: 0,
                                                  provider_name: "fake")

    # FaceVisibility IS STUBBED UNAVAILABLE, and that is not belt-and-braces: it
    # reads ANTHROPIC_API_KEY off the machine, and this app has eight other callers
    # so a developer running the suite plausibly has one set. Without the stub, this
    # test bills that key for up to VISION_SHORTLIST images on their laptop and
    # passes either way — a suite that can spend is a suite that will.
    Appearances::ImageSearch.stub(:available?, true) do
      Appearances::ImageSearch.stub(:provider_name, "fake") do
        Appearances::ImageSearch.stub(:search, ->(**) { answer }) do
          Appearances::FaceVisibility.stub(:available?, false) do
            post search_person_appearance_path(@person.slug, @look.slug)
          end
        end
      end
    end

    assert_redirected_to page_path
    assert_equal limit + 2, AppearanceReferencePhoto.count
    assert_equal limit, AppearanceReferencePhoto.chosen.count

    follow_redirect!
    assert_select "[data-test='chosen-gallery'] [data-test='reference-photo']", count: limit + 1
    assert_select "[data-test='rejected-gallery'] [data-test='reference-photo']", count: 2
  end

  # THE READ IS PUBLIC, THE PURCHASES ARE NOT. #show matches the person page beside
  # it; #search and #mint each spend real money, so an anonymous POST must reach the
  # login wall rather than the provider.
  test "[integration] an anonymous visitor can read the page but cannot spend on it" do
    cache_headshot

    get page_path
    assert_response :success

    Appearances::ImageSearch.stub(:available?, true) do
      Appearances::ImageSearch.stub(:search, ->(**) { raise "an anonymous POST must never reach a provider" }) do
        post search_person_appearance_path(@person.slug, @look.slug)
      end
    end
    assert_redirected_to "/login"

    post mint_person_appearance_path(@person.slug, @look.slug)
    assert_redirected_to "/login"
    assert_equal 0, AppearanceReferencePhoto.count
  end

  # ---- who may spend ---------------------------------------------------------

  # THE GATE THE OPEN SIGNUP MAKES NECESSARY, and the reason a login-only gate was
  # not one. Hub signup is OPEN — magic-link and Google are both create-or-login —
  # so "signed in" costs a member of the public one email address. Behind that, a
  # login-only #mint buys a Higgsfield identity per look and a login-only #search
  # buys one query plus up to VISION_SHORTLIST vision classifications PER CLICK,
  # uncapped. Before this lane, Appearances::CreateCharacterReference ran only from a
  # rake task; the page is what made the spend reachable from the web at all.
  #
  # THE REDIRECT IS THE WEAKER HALF OF THIS TEST. What it has to prove is that NO
  # PROVIDER WAS REACHED, so every collaborator is stubbed to RAISE: a refusal that
  # bought the query on its way out would satisfy a status assertion and still have
  # spent the money the gate exists to protect.
  test "[integration] a signed-in non-admin is refused and reaches no provider" do
    log_in_as(users(:viewer))
    cache_headshot

    Appearances::ImageSearch.stub(:available?, true) do
      Appearances::ImageSearch.stub(:search, ->(**) { raise "a non-admin POST must never reach a search provider" }) do
        Appearances::FaceVisibility.stub(:available?, ->(*) { raise "a non-admin POST must never reach the classifier" }) do
          post search_person_appearance_path(@person.slug, @look.slug)
        end
      end
    end
    assert_redirected_to root_path
    assert_equal 0, AppearanceReferencePhoto.count, "a refused search files nothing"

    Appearances::CreateCharacterReference.stub(:new, ->(*, **) { raise "a non-admin POST must never reach the vendor" }) do
      post mint_person_appearance_path(@person.slug, @look.slug)
      assert_redirected_to root_path

      post refresh_person_appearance_path(@person.slug, @look.slug)
      assert_redirected_to root_path
    end
    assert_nil @look.reload.higgsfield_reference_id, "a refused mint buys no identity"
  end

  # THE PAGE OFFERS NO CONTROL IT WOULD REFUSE. #show is public, so without the view
  # guards every reader is shown a button whose only effect is a bounce to the
  # landing page — and the most expensive button on the page reads as available to
  # anybody who can load it.
  test "[component] a non-admin reader is offered no purchase controls" do
    log_in_as(users(:viewer))
    cache_headshot

    Appearances::ImageSearch.stub(:available?, true) do
      Appearances::ImageSearch.stub(:provider_name, "fake") do
        get page_path
      end
    end

    assert_response :success
    assert_select "[data-test='reference-input-panel']", { count: 1 },
                  "the read half still renders for a non-admin"
    assert_select "[data-test='search-button']", count: 0
    assert_select "form[action='#{search_person_appearance_path(@person.slug, @look.slug)}']", count: 0
    assert_select "form[action='#{mint_person_appearance_path(@person.slug, @look.slug)}']", count: 0
  end

  # ---- where a failure goes --------------------------------------------------

  # A FLASH IS NOT A RECORD. It lives for one redirect and is then gone, and the
  # operator asking "why did the mint refuse?" is reading /admin/error_logs a day
  # later. `target` is what lets them find the row for THIS look rather than reading
  # every row since Tuesday.
  test "[integration] a vendor failure on mint leaves an ErrorLog row on the look" do
    log_in_as(users(:alex))
    cache_headshot

    assert_difference -> { ErrorLog.count }, 1 do
      Appearances::CreateCharacterReference.stub(:new, ->(*, **) { ExplodingMint.new }) do
        post mint_person_appearance_path(@person.slug, @look.slug)
      end
    end

    assert_redirected_to page_path
    assert_match(/Higgsfield refused the request/, flash[:alert],
                 "the operator still gets an answer — the row is in ADDITION to it")
    row = ErrorLog.order(:id).last
    assert_equal @look, row.target
    assert_equal @look.slug, row.target_name
  end

  # THE REFUSAL THAT IS NOT A FAILURE, and the reason #mint splits the two apart. A
  # look with nothing to build from is a state of the record; a row for it would be
  # noise in the one place an operator goes to find real failures.
  test "[integration] a look with nothing to mint from is refused without an ErrorLog row" do
    log_in_as(users(:alex))

    assert_no_difference -> { ErrorLog.count } do
      post mint_person_appearance_path(@person.slug, @look.slug)
    end

    assert_redirected_to page_path
    assert_match(/no reference photographs/, flash[:alert])
  end

  # ---- what a linked caption may point at ------------------------------------

  # A `page_url` IS NOT A URL UNTIL SOMETHING SAYS SO. It is stored exactly as the
  # provider sent it and is never validated on the way in, because the row is
  # evidence of what the search offered. This is the one place it reaches a browser.
  test "[component] a page_url that is not http(s) is never emitted as an href" do
    cache_headshot
    file_photo("https://cdn.example.com/a.jpg", chosen: true, position: 1,
               page_url: "javascript://evil.test/%0aalert(1)")
    file_photo("https://cdn.example.com/b.jpg", chosen: true, position: 2,
               page_url: "espn.com")

    get page_path

    assert_response :success
    assert_select "a[href='javascript://evil.test/%0aalert(1)']", count: 0
    # A BARE DOMAIN IS A RELATIVE href, so today this linked the operator to
    # /people/:person/models/espn.com on our own site instead of anywhere useful.
    assert_select "a[href='espn.com']", count: 0
    refute_includes response.body, "javascript://evil.test",
                    "a refused scheme has no business in the page at all"
  end

  # A SEARCH THAT COULD NOT RUN CHANGES NOTHING AND SAYS WHY. Without this the
  # unconfigured click looks like a search that found nothing.
  test "[integration] searching with no provider files nothing and names the env var" do
    log_in_as(users(:alex))
    cache_headshot
    Appearances::ImageSearch.stub(:available?, false) do
      post search_person_appearance_path(@person.slug, @look.slug)
    end

    assert_redirected_to page_path
    assert_equal 0, AppearanceReferencePhoto.count
    assert_match(/#{Appearances::ImageSearch::Serper::API_KEY_ENV}/, flash[:alert])
  end
end
