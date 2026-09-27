require "test_helper"

# [unit] THE VISION CLASSIFIER'S CONTRACT — availability, request shape, tolerant
# parsing, and the degrade.
#
# ⚠ IT HAS BEEN DRIVEN LIVE, AND IT FAILED — and that is the first thing to know.
# This header previously said the classifier "has NEVER been driven against the live
# API" because no ANTHROPIC_API_KEY existed on this machine or in any readable vault.
# Production has one, and on 2026-09-26 the first real scouting run answered 400 on
# every image: "Unable to download the file. Please verify the URL and try again."
# (A 400 rather than a 401 is itself the evidence the key was accepted.
# `credential-inventory.md` records where the VAULT ITEM is not filed — a different
# question, and still true.)
#
# THE CAUSE WAS THE URL WE PASSED, not this object. Wikimedia refuses a request that
# sends no User-Agent (403 with none, 200 with one, measured against the exact failing
# URL) and Anthropic's fetcher was the party refused. Appearances::GatherReferencePhotos
# now mirrors every shortlisted candidate into our own S3 and hands this object the
# copy — so a test that passes a third-party URL here is describing the defect.
#
# STILL UNVERIFIED: THE SUCCESS PATH. Everything below exercises the request BUILDER
# and the response PARSER over literals, and the shapes come from the documented
# Messages API rather than from an observed 200. First job after the first successful
# run is to pin the real response body as a fixture here.
#
# ZERO NETWORK, AND NOW TRAPPED RATHER THAN MERELY ASSERTED. Every test drives the
# private builder or parser directly, or the public path with no key. `#post` is
# additionally guarded by Appearances::LiveCallTrap, armed suite-wide in test_helper,
# so a future test that reaches it raises instead of billing — see
# test/services/appearances/live_call_trap_test.rb.
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

  # THE OLDER SPELLING IS STILL READ. `visibility` was called `score` until face size
  # was split out of it, so these fixtures are deliberately left in the old shape: they
  # are the proof that a model echoing the word it was asked for last month is still
  # understood rather than silently dropped.
  test "scores are keyed back to the url the echoed index names" do
    urls = ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]
    judged = parse(answer('[{"index":1,"score":0.9},{"index":0,"score":0.1}]'), urls)

    assert_in_delta 0.9, judged["https://cdn.example.com/b.jpg"].visibility, 0.001
    assert_in_delta 0.1, judged["https://cdn.example.com/a.jpg"].visibility, 0.001
  end

  # THE REASON THE INDEX IS ECHOED AT ALL. Keying on array position would silently
  # attach a score to the wrong photograph when the model answers out of order —
  # a mis-attribution no reviewer could see on the page.
  test "an out-of-order answer is attributed correctly, not by position" do
    urls = ["https://cdn.example.com/helmet.jpg", "https://cdn.example.com/bare.jpg"]
    judged = parse(answer('[{"index":1,"score":0.95},{"index":0,"score":0.15}]'), urls)

    assert_operator judged["https://cdn.example.com/bare.jpg"].visibility, :>,
                    judged["https://cdn.example.com/helmet.jpg"].visibility
  end

  test "prose around the JSON array is tolerated" do
    urls = ["https://cdn.example.com/a.jpg"]
    judged = parse(answer("Here you go:\n[{\"index\":0,\"score\":0.5}]\nHope that helps."), urls)

    assert_in_delta 0.5, judged["https://cdn.example.com/a.jpg"].visibility, 0.001
  end

  test "scores outside the range are clamped rather than trusted" do
    urls = ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]
    judged = parse(answer('[{"index":0,"score":7,"fill":4},{"index":1,"score":-3,"fill":-1}]'), urls)

    assert_in_delta 1.0, judged["https://cdn.example.com/a.jpg"].visibility, 0.001
    assert_in_delta 0.0, judged["https://cdn.example.com/b.jpg"].visibility, 0.001
    assert_in_delta 1.0, judged["https://cdn.example.com/a.jpg"].fill, 0.001,
                    "a fill is on the same 0..1 scale and is clamped to it too"
    assert_in_delta 0.0, judged["https://cdn.example.com/b.jpg"].fill, 0.001
  end

  # AN UNREADABLE SCORE IS AN ABSENT KEY, NEVER A ZERO. Zero means "there is no
  # person in this picture" and is a hard exclusion in the caller — asserting it on
  # the strength of a parse failure would drop a good photograph silently.
  test "a row we cannot read is omitted rather than scored zero" do
    urls = ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]
    judged = parse(answer('[{"index":0,"score":"banana"},{"index":1,"score":0.4}]'), urls)

    refute judged.key?("https://cdn.example.com/a.jpg")
    assert_in_delta 0.4, judged["https://cdn.example.com/b.jpg"].visibility, 0.001
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

  # ---- the parser, on face SIZE -------------------------------------------------
  #
  # WHY THESE ARE FIXTURE TESTS AND NOT A LIVE CALL. `fill` and `faces` were added to
  # the prompt by a task that forbade paid calls, so nothing here proves the live model
  # answers in this shape. What they DO prove is the half that has to be right either
  # way: a well-formed answer is read, and a malformed or missing field degrades to an
  # absence rather than to a zero — because Appearances::ReferenceEligibility refuses an
  # unmeasured photograph and would read a fabricated 0.0 as a measured tiny face.

  # THE WHOLE REASON THE PROMPT CHANGED. Four real Higgsfield mints turned on face size
  # in frame, and a visibility score cannot be read back for it.
  test "a face size and a subject count ride home beside the visibility" do
    urls = ["https://cdn.example.com/a.jpg"]
    judged = parse(answer('[{"index":0,"visibility":0.9,"fill":0.82,"faces":1}]'), urls)
    row = judged[urls.first]

    assert_in_delta 0.9, row.visibility, 0.001
    assert_in_delta 0.82, row.fill, 0.001
    assert_equal 1, row.subjects
    assert row.sized?, "a reported fill is a measured face size"
  end

  # THE SHAPE A MODEL THAT IGNORED THE NEW FIELDS RETURNS. It must degrade to the
  # OLD behaviour — a usable visibility — rather than to no answer at all, or one
  # unfamiliar field would turn a working classifier into a total outage.
  test "an answer with no face size is kept, and says it has none" do
    urls = ["https://cdn.example.com/a.jpg"]
    row = parse(answer('[{"index":0,"visibility":0.9}]'), urls)[urls.first]

    assert_in_delta 0.9, row.visibility, 0.001
    assert_nil row.fill, "an absent fill is unknown, never a small face"
    refute row.sized?
  end

  # A FILL WITHOUT A VISIBILITY IS NOT AN ANSWER. Every caller keys on visibility, so a
  # row carrying only a size would rank a photograph nothing readable was said about.
  test "a row with a face size but no readable visibility is dropped entirely" do
    urls = ["https://cdn.example.com/a.jpg"]

    assert_equal({}, parse(answer('[{"index":0,"fill":0.9}]'), urls))
  end

  test "an unreadable face size is absent rather than zero" do
    urls = ["https://cdn.example.com/a.jpg"]
    row = parse(answer('[{"index":0,"visibility":0.7,"fill":"big","faces":"lots"}]'), urls)[urls.first]

    assert_in_delta 0.7, row.visibility, 0.001
    assert_nil row.fill
    assert_nil row.subjects
  end

  # THE TWO QUESTIONS HAVE TO BE ASKED SEPARATELY, and the prompt is the only place
  # that can be checked without spending. A prompt that folded size back into the
  # visibility score would make every `face_fill` null and the mint gate inert.
  test "the prompt asks for face size and subject count as their own numbers" do
    assert_match(/"fill"/, FV::SYSTEM_PROMPT)
    assert_match(/"faces"/, FV::SYSTEM_PROMPT)
    assert_match(/HOW MUCH OF THE FRAME THE HEAD OCCUPIES/, FV::SYSTEM_PROMPT)
    assert_match(/how many DIFFERENT people's faces/, FV::SYSTEM_PROMPT)
  end

  # THE THRESHOLD AND THE PROMPT'S ANCHORS ARE ONE JUDGEMENT. MINT_FACE_FILL is set at
  # the "head and shoulders" anchor; if the prompt stopped naming an anchor at that
  # value the threshold would be a number against no scale at all.
  test "the face-size threshold sits on an anchor the prompt actually names" do
    assert_match(/0\.6\s+a head-and-shoulders portrait/, FV::SYSTEM_PROMPT)
    assert_in_delta 0.6, Appearances::ReferenceEligibility::MINT_FACE_FILL, 0.0001
  end

  # THE SPLIT THE PROMPT IS WRITTEN TO MAKE, and the caller's hard exclusion rests
  # on it: 0.15 is "your man, face hidden"; 0.0 is "not a photograph of anybody".
  # A prompt that stopped distinguishing them would silently start excluding every
  # helmeted photograph.
  test "the prompt distinguishes a hidden face from no person at all" do
    assert_match(/0\.15/, FV::SYSTEM_PROMPT)
    assert_match(/NO PERSON IS PRESENT AT ALL/, FV::SYSTEM_PROMPT)
    assert_operator Appearances::ReferenceEligibility::NO_PERSON, :<, 0.15,
                    "the exclusion floor must sit BELOW the helmet band, or helmets are excluded"
  end

  # The model id is a published fact with a cost attached, so a change to it has to
  # break a test rather than quietly re-price every search.
  test "the classifier is pinned to haiku, with no date suffix" do
    assert_equal "claude-haiku-4-5", FV::MODEL
    refute_match(/-\d{8}\z/, FV::MODEL, "date-suffixed ids are the stale spelling")
  end
end
