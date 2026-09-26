require "test_helper"

# [unit] THE VISION CLASSIFIER'S CONTRACT — availability, request shape, tolerant
# parsing, and the degrade.
#
# ⚠ UNVERIFIED END TO END, and that is the first thing to know. No
# ANTHROPIC_API_KEY exists on this machine or in any vault the agent service
# account can read (`credential-inventory.md` records ANTHROPIC as NOT PRESENT),
# so this classifier has NEVER been driven against the live API. Everything below
# exercises the request BUILDER and the response PARSER over literals.
#
# What that means for a reader: the shapes here come from the documented Messages
# API (image blocks with a `url` source), not from an observed 200. The first job
# the day a key lands is one real call over a handful of candidates — then pin the
# real response body as a fixture here.
#
# ZERO NETWORK. Every test drives the private builder or parser directly, or the
# public path with no key. `#post` is never reached, so nothing here can spend.
class Appearances::FaceVisibilityTest < ActiveSupport::TestCase
  FV = Appearances::FaceVisibility

  def classifier = FV.new(api_key: "test-key-not-a-real-credential")

  # THE PATH THAT RUNS TODAY on every machine in the ecosystem.
  test "with no credential it is unavailable and scores nothing" do
    with_env("ANTHROPIC_API_KEY", nil) do
      refute FV.available?
      assert_equal({}, FV.call(["https://cdn.example.com/a.jpg"]))
    end
  end

  test "availability is decided by the env var alone, with no round trip" do
    with_env("ANTHROPIC_API_KEY", "test-key-not-a-real-credential") do
      assert FV.available?
    end
  end

  # AN EMPTY HASH IS THE DEGRADE. The caller reads it as "nobody looked" and falls
  # back to its free ranking; anything that raised here would cost the operator the
  # whole search rather than a better ordering of it.
  test "a transport failure degrades to an empty hash rather than raising" do
    provider = classifier
    provider.stub(:post, ->(_urls) { raise IOError, "connection reset" }) do
      assert_equal({}, provider.call(["https://cdn.example.com/a.jpg"]))
    end
  end

  test "an empty list of urls never builds a request" do
    assert_equal({}, classifier.call([]))
    assert_equal({}, classifier.call(nil))
  end

  # THE DEGRADE IS ALSO AN ErrorLog ROW, filed against the look.
  #
  # An empty Hash is the answer for "no credential", "refused", "timed out" and
  # "unreadable answer" alike, and the page renders all four as one sentence —
  # "ranked on shape and relevance only (no face classifier)". That sentence is TRUE
  # of a machine with no key and MISLEADING of a machine whose key was rejected, and
  # a row in /admin/error_logs is the only thing that tells the operator which he has.
  test "a transport failure is filed against the look, not only warned about" do
    look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Bills home")
    provider = classifier

    assert_difference -> { ErrorLog.count }, 1 do
      provider.stub(:post, ->(_urls) { raise IOError, "connection reset" }) do
        assert_equal({}, provider.call(["https://cdn.example.com/a.jpg"], target: look))
      end
    end

    row = ErrorLog.order(:id).last
    assert_equal "connection reset", row.message
    assert_equal look, row.target
    assert_equal look.slug, row.target_name
  end

  # AN ANSWER WE PAID FOR AND COULD NOT READ is a parser bug on OUR side, not a
  # vendor outage, and it is the failure here that would otherwise recur silently on
  # every single search. It is filed from its own rescue for that reason.
  test "an answer we paid for and cannot read is filed too" do
    look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Bills home")

    assert_difference -> { ErrorLog.count }, 1 do
      scores = classifier.send(:parse, { "content" => [{ "type" => "text", "text" => "[not json" }] },
                               ["https://cdn.example.com/a.jpg"], target: look)
      assert_equal({}, scores)
    end

    assert_equal look, ErrorLog.order(:id).last.target
  end

  # ---- the request ------------------------------------------------------------

  # THE PRODUCTION BUILDER, called directly rather than through a stub. An earlier
  # cut of these two tests stubbed `#post` and rebuilt the content inside the stub
  # — which asserted that the TEST could build a content array and would have
  # stayed green through any change to the real one.
  def build(urls) = classifier.send(:build_content, urls)

  # ANTHROPIC FETCHES THE IMAGES SERVER-SIDE from a url source — we never download
  # the bytes, which is the same trust boundary Higgsfield's create sits behind.
  test "each image rides as a url source, not as downloaded bytes" do
    content = build(["https://cdn.example.com/a.jpg"])
    image = content.find { |block| block[:type] == "image" }

    assert_equal({ type: "url", url: "https://cdn.example.com/a.jpg" }, image[:source])
    refute content.any? { |block| block.dig(:source, :type) == "base64" },
           "downloading the bytes ourselves would put this app inside the fetch"
  end

  # ONE MESSAGE, EVERY IMAGE. N requests would multiply the per-call overhead by N
  # for an answer the model gives in one pass — and the comparison between the
  # candidates is part of the judgement.
  test "a batch of images is one message, with an index label before each" do
    content = build(["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"])

    assert_equal 4, content.length, "two images plus their two index labels, in ONE message"
    assert_equal "Image index 0:", content[0][:text]
    assert_equal "https://cdn.example.com/a.jpg", content[1].dig(:source, :url)
    assert_equal "Image index 1:", content[2][:text]
    assert_equal "https://cdn.example.com/b.jpg", content[3].dig(:source, :url)
  end

  # THE LABELS ARE WHAT THE ECHOED INDEX REFERS TO, so they have to agree with the
  # array order the parser keys against. If these two ever drift, every score is
  # attached to the wrong photograph and nothing raises.
  test "the index labels match the order the parser keys scores back by" do
    urls = (0..3).map { |i| "https://cdn.example.com/#{i}.jpg" }
    labels = build(urls).filter_map { |b| b[:text] }

    assert_equal urls.each_index.map { |i| "Image index #{i}:" }, labels
  end

  # ---- the parser -------------------------------------------------------------

  def parse(payload, urls) = classifier.send(:parse, payload, urls)

  def answer(json) = { "content" => [{ "type" => "text", "text" => json }] }

  test "scores are keyed back to the url the echoed index names" do
    urls = ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]
    scores = parse(answer('[{"index":1,"score":0.9},{"index":0,"score":0.1}]'), urls)

    assert_in_delta 0.9, scores["https://cdn.example.com/b.jpg"], 0.001
    assert_in_delta 0.1, scores["https://cdn.example.com/a.jpg"], 0.001
  end

  # THE REASON THE INDEX IS ECHOED AT ALL. Keying on array position would silently
  # attach a score to the wrong photograph when the model answers out of order —
  # a mis-attribution no reviewer could see on the page.
  test "an out-of-order answer is attributed correctly, not by position" do
    urls = ["https://cdn.example.com/helmet.jpg", "https://cdn.example.com/bare.jpg"]
    scores = parse(answer('[{"index":1,"score":0.95},{"index":0,"score":0.15}]'), urls)

    assert_operator scores["https://cdn.example.com/bare.jpg"], :>,
                    scores["https://cdn.example.com/helmet.jpg"]
  end

  test "prose around the JSON array is tolerated" do
    urls = ["https://cdn.example.com/a.jpg"]
    scores = parse(answer("Here you go:\n[{\"index\":0,\"score\":0.5}]\nHope that helps."), urls)

    assert_in_delta 0.5, scores["https://cdn.example.com/a.jpg"], 0.001
  end

  test "scores outside the range are clamped rather than trusted" do
    urls = ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]
    scores = parse(answer('[{"index":0,"score":7},{"index":1,"score":-3}]'), urls)

    assert_in_delta 1.0, scores["https://cdn.example.com/a.jpg"], 0.001
    assert_in_delta 0.0, scores["https://cdn.example.com/b.jpg"], 0.001
  end

  # AN UNREADABLE SCORE IS AN ABSENT KEY, NEVER A ZERO. Zero means "there is no
  # person in this picture" and is a hard exclusion in the caller — asserting it on
  # the strength of a parse failure would drop a good photograph silently.
  test "a row we cannot read is omitted rather than scored zero" do
    urls = ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]
    scores = parse(answer('[{"index":0,"score":"banana"},{"index":1,"score":0.4}]'), urls)

    refute scores.key?("https://cdn.example.com/a.jpg")
    assert_in_delta 0.4, scores["https://cdn.example.com/b.jpg"], 0.001
  end

  test "an index naming no image is dropped rather than raising" do
    scores = parse(answer('[{"index":9,"score":0.9}]'), ["https://cdn.example.com/a.jpg"])

    assert_equal({}, scores)
  end

  test "an answer that is not JSON at all degrades to no scores" do
    urls = ["https://cdn.example.com/a.jpg"]

    assert_equal({}, parse(answer("I cannot help with that."), urls))
    assert_equal({}, parse({ "content" => [] }, urls))
  end

  # THE SPLIT THE PROMPT IS WRITTEN TO MAKE, and the caller's hard exclusion rests
  # on it: 0.15 is "your man, face hidden"; 0.0 is "not a photograph of anybody".
  # A prompt that stopped distinguishing them would silently start excluding every
  # helmeted photograph.
  test "the prompt distinguishes a hidden face from no person at all" do
    assert_match(/0\.15/, FV::SYSTEM_PROMPT)
    assert_match(/NO PERSON IS PRESENT AT ALL/, FV::SYSTEM_PROMPT)
    assert_operator Appearances::GatherReferencePhotos::NO_PERSON_THRESHOLD, :<, 0.15,
                    "the exclusion floor must sit BELOW the helmet band, or helmets are excluded"
  end

  # The model id is a published fact with a cost attached, so a change to it has to
  # break a test rather than quietly re-price every search.
  test "the classifier is pinned to haiku, with no date suffix" do
    assert_equal "claude-haiku-4-5", FV::MODEL
    refute_match(/-\d{8}\z/, FV::MODEL, "date-suffixed ids are the stale spelling")
  end
end
