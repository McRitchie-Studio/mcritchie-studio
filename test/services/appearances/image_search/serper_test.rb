require "test_helper"

# [unit] THE SERPER RESPONSE PARSER, over an ASSUMED fixture.
#
# ⚠ READ THE CLASS NAME AND THEN THIS PARAGRAPH BEFORE TRUSTING ANY GREEN HERE.
# The fixture below was NOT captured from a live serper.dev response. No credential
# for serper.dev exists — not in 1Password, not in Heroku config — so the shape is
# assembled from public write-ups: `docs.serper.dev` did not resolve when this was
# written and the playground page served only a cookie banner. Every test name in
# this file carries `assumed_fixture` for that reason.
#
# A GREEN TEST OVER A GUESSED FIXTURE PROVES THE GUESS IS SELF-CONSISTENT AND
# NOTHING ELSE. What it DOES prove, and what makes it worth having: the parser's
# TOLERANCE is real. The cases below feed it rows with fields missing, fields of the
# wrong type, fields under alternative names, and rows that are not Hashes at all —
# and those behaviours are the ones that matter precisely BECAUSE the shape is
# unknown.
#
# WHEN THE KEY LANDS: probe once, capture the real body, and replace
# `assumed_serper_body` with it. If the capture disagrees with the guess, the
# disagreement is the finding — fix the parser, keep the tolerance tests.
#
# ZERO NETWORK. Every test drives `send(:parse, ...)` on an instance built with a
# literal key; `#post` is never reached, so nothing here can open a socket or spend
# a cent. The one test that asserts the HTTP path does so by refusing to enter it.
class Appearances::ImageSearch::SerperTest < ActiveSupport::TestCase
  Serper = Appearances::ImageSearch::Serper

  def provider = Serper.new(api_key: "test-key-not-a-real-credential")

  def parse(payload) = provider.send(:parse, payload)

  # THE ASSUMED SHAPE. Not measured — see the header.
  def assumed_serper_body
    {
      "searchParameters" => { "q" => "Drew Lock Seattle Seahawks", "type" => "images" },
      "images" => [
        { "title" => "Drew Lock warms up", "imageUrl" => "https://cdn.example.com/lock-1.jpg",
          "imageWidth" => 1200, "imageHeight" => 1600,
          "link" => "https://sports.example.com/lock", "source" => "sports.example.com",
          "position" => 1 },
        { "title" => "Drew Lock profile", "imageUrl" => "https://cdn.example.com/lock-2.jpg",
          "imageWidth" => 800, "imageHeight" => 800,
          "link" => "https://news.example.com/lock", "source" => "news.example.com",
          "position" => 2 }
      ]
    }
  end

  test "assumed_fixture: the two fields we are confident about are read" do
    answer = parse(assumed_serper_body)

    assert_equal 2, answer.results.length
    assert_equal "https://cdn.example.com/lock-1.jpg", answer.results.first.image_url
    assert_equal "https://sports.example.com/lock", answer.results.first.page_url
    assert_equal 0, answer.unparsed_count
    assert_equal "serper", answer.provider_name
  end

  test "assumed_fixture: optional fields are read when present" do
    result = parse(assumed_serper_body).results.first

    assert_equal "Drew Lock warms up", result.title
    assert_equal 1200, result.width
    assert_equal 1600, result.height
    assert_equal 1, result.position
  end

  # THE CENTRAL TOLERANCE CLAIM, and the reason this parser is written the way it
  # is. The field list is a guess, so the likeliest failure is not "the API is down"
  # but "width is called something else" — and dropping a good photograph over a
  # missing dimension would be the guess costing us real results.
  test "assumed_fixture: a row with only imageUrl is kept, not dropped" do
    answer = parse({ "images" => [{ "imageUrl" => "https://cdn.example.com/bare.jpg" }] })

    assert_equal 1, answer.results.length, "imageUrl is the ONLY field this parser requires"
    result = answer.results.first
    assert_nil result.title
    assert_nil result.width
    assert_nil result.height
    assert_nil result.page_url
    assert_equal 1, result.position, "with no position field the array order IS the rank"
  end

  test "assumed_fixture: source stands in for link when only source is present" do
    answer = parse({ "images" => [{ "imageUrl" => "https://cdn.example.com/a.jpg",
                                    "source" => "espn.com" }] })

    assert_equal "espn.com", answer.results.first.page_url
  end

  test "assumed_fixture: width and height are read under either spelling" do
    answer = parse({ "images" => [{ "imageUrl" => "https://cdn.example.com/a.jpg",
                                    "width" => 640, "height" => 480 }] })

    assert_equal 640, answer.results.first.width
    assert_equal 480, answer.results.first.height
  end

  # A DIMENSION WE CANNOT TRUST IS NO DIMENSION. `to_i` turns "large" into 0, and a
  # 0-pixel-wide photograph renders as a broken image rather than an unreported one.
  test "assumed_fixture: an unparseable dimension becomes nil rather than zero" do
    answer = parse({ "images" => [{ "imageUrl" => "https://cdn.example.com/a.jpg",
                                    "imageWidth" => "large", "imageHeight" => nil }] })

    result = answer.results.first
    assert_nil result.width
    assert_nil result.height
    refute_equal 0, result.width
  end

  test "assumed_fixture: a numeric dimension arriving as a string is still read" do
    answer = parse({ "images" => [{ "imageUrl" => "https://cdn.example.com/a.jpg",
                                    "imageWidth" => "640" }] })

    assert_equal 640, answer.results.first.width
  end

  # SKIPPED AND COUNTED, NEVER RAISED ON. A raise would lose nineteen good results to
  # one odd row; a silent skip would report a parser bug as "the search found
  # nothing". The count is the difference.
  test "assumed_fixture: rows we cannot read are skipped and counted, not raised on" do
    answer = nil
    assert_nothing_raised do
      answer = parse({ "images" => [
        { "imageUrl" => "https://cdn.example.com/good.jpg" },
        { "title" => "no url at all" },
        { "imageUrl" => "" },
        "a bare string where an object was expected",
        nil
      ] })
    end

    assert_equal 1, answer.results.length
    assert_equal 4, answer.unparsed_count,
                 "a silent zero and a silent parse failure are the same empty list without this"
  end

  test "assumed_fixture: a response with no images key is empty rather than an error" do
    answer = parse({ "searchParameters" => { "q" => "x" } })

    assert_equal [], answer.results
    assert_equal 0, answer.unparsed_count
  end

  test "assumed_fixture: a response that is not an object at all is empty" do
    assert_equal [], parse([]).results
    assert_equal [], parse(nil).results
  end

  # ZERO PARSED FROM A NON-EMPTY ANSWER is the shape of a parser bug, and it is the
  # single most likely failure once a real key lands. It has to be loud.
  test "assumed_fixture: parsing none of a non-empty answer is logged as a parser bug" do
    logged = []
    Rails.logger.stub(:warn, ->(msg) { logged << msg }) do
      parse({ "images" => [{ "url" => "https://cdn.example.com/wrong-field.jpg" }] })
    end

    assert_equal 1, logged.length
    assert_match(/parsed 0 of 1/, logged.first)
  end

  # THE SUITE MUST NOT BE ABLE TO SPEND. Without a key the provider refuses BEFORE
  # any socket work, so a test that forgot to inject one cannot reach serper.dev.
  test "a search with no key refuses locally instead of calling out" do
    error = assert_raises(Serper::Error) do
      Serper.new(api_key: nil).search(query: "Drew Lock")
    end

    assert_match(/SERPER_API_KEY/, error.message,
                 "the refusal names the variable, because the reader is who will set it")
  end

  test "an empty query refuses locally rather than buying a useless result" do
    assert_raises(ArgumentError) { provider.search(query: "   ") }
  end

  # The env var name is a published fact — it goes in 1Password and in Heroku config
  # — so a rename has to break a test rather than silently orphan the credential.
  test "the credential's env var name is SERPER_API_KEY" do
    assert_equal "SERPER_API_KEY", Serper::API_KEY_ENV
  end
end
