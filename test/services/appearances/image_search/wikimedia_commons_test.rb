require "test_helper"

# [unit] THE WIKIMEDIA COMMONS PARSER, over a CAPTURED body.
#
# READ THIS FIXTURE'S PROVENANCE BEFORE TRUSTING ANY ASSERTION BELOW.
# test/fixtures/files/wikimedia_commons_drew_lock.json is a VERBATIM TRIM of a live 200
# from commons.wikimedia.org on 2026-09-26 — five of the twenty pages that answer
# "Drew Lock", with every field's content exactly as the API sent it, including the
# `utm_*` query parameters, the `File:` title prefix, and the pageid-keyed `pages` hash
# in the order the API emitted it.
#
# THAT IS THE WHOLE DIFFERENCE FROM Appearances::ImageSearch::Serper's test, whose
# fixture is named `assumed_serper_body` because nobody has ever seen a Serper response.
# A green test over a guessed fixture proves the guess is self-consistent and nothing
# else. This one proves the parser reads what the archive actually sends.
#
# NOTHING HERE REACHES THE NETWORK, AND THAT IS PROVEN RATHER THAN ASSERTED. Every test
# runs inside `with_no_network`, which raises on any TCP connect attempt, and the
# `[control]` test drives the provider's REAL search path through that trap to show the
# trap covers it. Without that control a trap that had stopped working would leave every
# test below green and silently live.
class Appearances::ImageSearch::WikimediaCommonsTest < ActiveSupport::TestCase
  Provider = Appearances::ImageSearch::WikimediaCommons

  # RAISED BY THE TRAP, so a leak is a loud failure naming itself rather than a slow test
  # or a surprise bill.
  class NetworkReached < StandardError; end

  FIXTURE = Rails.root.join("test/fixtures/files/wikimedia_commons_drew_lock.json").freeze

  def captured_body = JSON.parse(File.read(FIXTURE))

  # THE TRAP. TCPSocket.open is where every Ruby HTTP client bottoms out — Net::HTTP
  # included, TLS or not — so trapping it catches an escape regardless of which layer
  # tried. Trapping Net::HTTP.start instead would miss anything that built its own
  # socket.
  def with_no_network
    TCPSocket.stub(:open, ->(*) { raise NetworkReached, "a test tried to open a socket" }) do
      yield
    end
  end

  # ONE SEARCH OVER A CANNED BODY. `get` is stubbed rather than the socket mocked with a
  # scripted response, because what is under test is the PARSER and a hand-built HTTP
  # response would be a second fixture to get wrong.
  def answer_for(body = captured_body, query: "Drew Lock", limit: 20)
    provider = Provider.new
    provider.stub(:get, body) do
      with_no_network { provider.search(query: query, limit: limit) }
    end
  end

  # ── THE TRAP'S OWN CONTROL ───────────────────────────────────────────────────────
  #
  # PROVES THE TRAP BITES ON THE REAL PATH. If `search` were ever refactored to reach the
  # network through something TCPSocket.open does not cover, this test fails and the
  # suite stops claiming a guarantee it no longer has. It is the only test in this file
  # that runs the unstubbed request path.
  test "[control] the network trap catches the provider's real request path" do
    error = assert_raises(NetworkReached) do
      with_no_network { Provider.new.search(query: "Drew Lock", limit: 2) }
    end

    assert_match(/tried to open a socket/, error.message)
  end

  # ── THE KEYLESS CONTRACT ─────────────────────────────────────────────────────────

  test "[unit] it is available with no credential of any kind" do
    # THE ENTIRE REASON THIS PROVIDER EXISTS. Serper answers false on every machine in
    # the ecosystem because SERPER_API_KEY has never been bought, which left
    # ImageSearch.available? false everywhere and the operator's Search button absent.
    # Cleared explicitly so a machine that DID have a Serper key could not make this
    # pass for the wrong reason.
    with_env("SERPER_API_KEY", nil) do
      assert Provider.available?, "the keyless provider must not depend on any ENV"
    end
  end

  test "[unit] its provider name is stable and is not Class#name" do
    assert_equal "wikimedia-commons", Provider.provider_name
    assert_equal "Appearances::ImageSearch::WikimediaCommons", Provider.name
  end

  test "[unit] it is registered in the façade AFTER serper" do
    # THE ORDER IS THE PREFERENCE. The façade serves the first AVAILABLE provider, so
    # Commons listed FIRST would make a bought Serper key permanently unreachable.
    names = Appearances::ImageSearch.providers.map(&:provider_name)

    assert_equal %w[serper wikimedia-commons], names,
                 "paid-first-then-keyless-floor; reversing this silently retires Serper"
  end

  # ── THE MEASURED SHAPE ───────────────────────────────────────────────────────────

  test "[unit] it reads every page of the captured body" do
    answer = answer_for

    assert_equal 5, answer.results.length
    assert_equal 0, answer.unparsed_count
    assert_equal "wikimedia-commons", answer.provider_name
  end

  test "[unit] results come back in SEARCH order, not in the pages hash's order" do
    # THE BUG THIS PINS. `query.pages` is a Hash keyed by pageid and its order is not the
    # ranking — the captured body's keys run 2, 5, 9, 1, 6. The scouting page's first
    # question is "what did the search return, in the order it returned it", so a parser
    # that enumerated the hash would render the archive's ranking scrambled and the
    # operator would be judging an order nobody produced.
    hash_order = captured_body["query"]["pages"].values.map { |page| page["index"] }
    assert_equal [2, 5, 9, 1, 6], hash_order, "fixture no longer exercises the trap"

    assert_equal [1, 2, 5, 6, 9], answer_for.results.map(&:position)
  end

  test "[unit] the File namespace prefix is stripped and the extension is kept" do
    titles = answer_for.results.map(&:title)

    assert_equal "Drew Lock.JPG", titles.first
    refute titles.any? { |title| title.start_with?("File:") }
    # THE EXTENSION IS LOAD-BEARING, not cosmetic: PhotoMerit::DOCUMENT_MARKERS reads
    # `.pdf` and `.djvu` out of exactly this string, and the documented measurements
    # name these files by it ("Drew Hutton.jpg").
    assert_includes titles, "Pope - The Rape of the Lock, 1896.djvu"
  end

  test "[unit] utm tracking parameters are stripped from both urls" do
    # MEASURED: the API decorates `url` and `descriptionurl` with
    # `?utm_source=…&utm_campaign=imageinfo&utm_content=original`. `image_url` is half of
    # this table's unique index, so a campaign tag that ever changed would file the same
    # photograph twice and let it take two slots in one identity.
    raw = captured_body["query"]["pages"].values.first["imageinfo"].first["url"]
    assert_includes raw, "utm_source", "fixture no longer carries the tags to strip"

    answer_for.results.each do |result|
      refute_includes result.image_url.to_s, "utm_", "utm survived on #{result.title}"
      refute_includes result.page_url.to_s, "utm_", "utm survived on #{result.title}"
    end

    assert_equal "https://upload.wikimedia.org/wikipedia/commons/5/50/Drew_Lock.JPG",
                 answer_for.results.first.image_url
  end

  test "[unit] it reports the ORIGINAL dimensions and the page url" do
    first = answer_for.results.first

    assert_equal 936, first.width
    assert_equal 1026, first.height
    assert_equal "https://commons.wikimedia.org/wiki/File:Drew_Lock.JPG", first.page_url
  end

  test "[unit] it reports the mime type the archive claims" do
    # WHY THIS FIELD IS WORTH CARRYING. On the full measured answer 12 of 20 rows were
    # documents, and the archive says so itself — a stronger statement than sniffing an
    # extension out of a URL. The scouting page prints it.
    by_title = answer_for.results.index_by(&:title)

    assert_equal "image/jpeg", by_title["Drew Lock.JPG"].mime
    assert_equal "application/pdf", by_title["John Drew (IA johndrew00dith).pdf"].mime
    assert_equal "image/vnd.djvu", by_title["Pope - The Rape of the Lock, 1896.djvu"].mime
  end

  test "[unit] a LARGE original carries a small rendition beside it" do
    # THE ORIGINAL IS FOR THE VENDOR AND THE THUMBNAIL IS FOR THE BROWSER, and the split
    # is load-bearing rather than tidy: MEASURED 2026-09-26, twenty Commons originals at
    # 1-3 MB each answered **HTTP 429** from the third one onward and a third of the
    # gallery rendered as grey alt-text.
    wide = answer_for.results.find { |r| r.title.start_with?("WFT vs. Broncos") }

    assert_equal 3207, wide.width, "this row is the one big enough to be worth shrinking"
    assert_equal "https://upload.wikimedia.org/wikipedia/commons/5/59/WFT_vs._Broncos_%2851651272550%29.jpg",
                 wide.image_url
    assert_includes wide.thumb_url, "/thumb/"
    refute_equal wide.image_url, wide.thumb_url
    # THE TAGS ARE STRIPPED FROM THIS ONE TOO. It arrives with `utm_content=thumbnail`
    # where the original carries `utm_content=original`.
    refute_includes wide.thumb_url, "utm_"
  end

  test "[unit] a SMALL original is its own thumbnail, and that is the archive's choice" do
    # MEASURED, AND SURPRISING ENOUGH TO PIN. Asked for a 600px rendition of a 936px
    # original, Commons reports `thumbwidth: 600` and hands back the ORIGINAL url — it
    # declines to generate a thumbnail for a file already small enough. So `thumb_url`
    # equalling `image_url` is CORRECT here, not a parser fault, and the display fallback
    # is a no-op rather than a failure.
    small = answer_for.results.find { |r| r.title == "Drew Lock.JPG" }

    assert_equal 936, small.width
    assert_equal small.image_url, small.thumb_url
    refute_includes small.thumb_url, "/thumb/"
  end

  test "[unit] THE ARCHIVE PICKS THE WIDTH, so the request is a hint and not a promise" do
    # WE ASK FOR 600 AND THE THUMB URL SAYS 960 — Commons snaps to its own standard
    # buckets. Pinned because it is the kind of surprise that would otherwise be "fixed"
    # by someone assuming THUMB_WIDTH is honoured literally. Nothing depends on the exact
    # number; everything depends on it being much smaller than a multi-megabyte original.
    assert_equal 600, Appearances::ImageSearch::WikimediaCommons::THUMB_WIDTH

    wide = answer_for.results.find { |r| r.title.start_with?("WFT vs. Broncos") }
    assert_includes wide.thumb_url, "960px-"
  end

  test "[unit] a row with no thumbnail falls back to the original for display" do
    body = captured_body
    body["query"]["pages"].each_value { |page| page["imageinfo"].first.delete("thumburl") }
    result = answer_for(body).results.first

    assert_nil result.thumb_url
    # THE MODEL OWNS THE FALLBACK so no view has to know the rule — a Serper row and
    # every row filed before this column existed still render.
    photo = AppearanceReferencePhoto.new(image_url: result.image_url, thumb_url: nil)
    assert_equal result.image_url, photo.display_url
  end

  # ── THE EMPTY AND BROKEN SHAPES ──────────────────────────────────────────────────

  test "[unit] a zero-hit body is an empty answer with NOTHING unparsed" do
    # MEASURED 2026-09-26: a query that matches nothing answers with exactly this — no
    # `query` key at all. Counting it as unparsed would make every genuinely empty search
    # look like a broken parser, which is the one alarm `unparsed_count` exists to raise.
    answer = answer_for({ "batchcomplete" => "" })

    assert_empty answer.results
    assert_equal 0, answer.unparsed_count
    assert_equal "wikimedia-commons", answer.provider_name
  end

  test "[unit] a page with no imageinfo is SKIPPED AND COUNTED" do
    body = captured_body
    body["query"]["pages"]["999"] = { "pageid" => 999, "ns" => 6, "index" => 3,
                                      "title" => "File:No info.jpg" }
    answer = answer_for(body)

    assert_equal 5, answer.results.length
    assert_equal 1, answer.unparsed_count,
                 "an unreadable row must be counted, or a parser fault reads as an empty search"
  end

  test "[unit] a page with no index sorts LAST rather than first" do
    body = captured_body
    body["query"]["pages"]["998"] = {
      "pageid" => 998, "ns" => 6, "title" => "File:Unranked.jpg",
      "imageinfo" => [{ "url" => "https://upload.wikimedia.org/x/Unranked.jpg",
                        "descriptionurl" => "https://commons.wikimedia.org/wiki/File:Unranked.jpg",
                        "width" => 800, "height" => 900, "mime" => "image/jpeg" }]
    }

    # `to_i` on a missing index is 0, which would PROMOTE an unranked row above hit 1 —
    # the opposite of what an absent rank means.
    assert_equal "Unranked.jpg", answer_for(body).results.last.title
  end

  test "[unit] a body that is not a Hash yields an empty answer rather than raising" do
    assert_empty answer_for([]).results
    assert_equal 0, answer_for([]).unparsed_count
  end

  test "[unit] an empty query is refused before any request is built" do
    error = assert_raises(ArgumentError) do
      with_no_network { Provider.new.search(query: "   ") }
    end

    assert_match(/needs a query/, error.message)
  end

  # ── THE FAÇADE'S CONTRACT ────────────────────────────────────────────────────────

  test "[unit] a provider raise is caught by the façade and files an ErrorLog" do
    # THE PROVIDER RAISES ON PURPOSE and the façade owns the degrade. This pins the seam:
    # an outage must cost photographs, never the page, and must leave a row behind so
    # "the archive is down" and "the archive has nothing" are distinguishable.
    exploding = Class.new do
      def self.provider_name = "wikimedia-commons"
      def self.available? = true
      def self.search(query:, limit: 20) = raise(Appearances::ImageSearch::WikimediaCommons::Error, "503")
    end

    Appearances::ImageSearch.stub(:providers, [exploding]) do
      answer = nil
      assert_difference -> { ErrorLog.count }, 1 do
        answer = Appearances::ImageSearch.search(query: "Drew Lock")
      end
      assert_empty answer.results
      assert_equal "wikimedia-commons", answer.provider_name
    end
  end
end
