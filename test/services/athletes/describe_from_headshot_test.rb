require "test_helper"

# [unit] THE VISION HALF'S CONTRACT — which bytes it reads, what it asks for, how
# tolerantly it reads the answer, and what it refuses to write.
#
# ZERO NETWORK, and not because these tests are careful. Athletes::VisionTransport is
# armed to RAISE for the whole suite (test/test_helper.rb), and the exception sits
# outside StandardError so the degrade below cannot swallow it — so a test here that
# forgot to inject a transport fails loudly rather than billing. See
# test/services/athletes/vision_transport_test.rb.
class Athletes::DescribeFromHeadshotTest < ActiveSupport::TestCase
  DFH = Athletes::DescribeFromHeadshot

  # A well-formed answer, in the shape the system prompt asks for.
  GOOD_ANSWER = {
    "content" => [{ "type" => "text",
                    "text" => '{"person_visible": true, "skin_tone": "medium-deep, warm undertone", ' \
                              '"hair_description": "short black fade, full beard"}' }],
    "usage" => { "input_tokens" => 505, "output_tokens" => 38 }
  }.freeze

  # --- BUILD IS NOT ITS JOB -----------------------------------------------
  #
  # STRUCTURAL, not a prompt assertion. A headshot cannot see a body, so this service
  # must be unable to write build even if a model volunteered one — and the way to
  # guarantee that is for the Result to have nowhere to put it. An assertion on the
  # prompt text would pass while a `build` field quietly reached the column.

  test "the result has no build field, so this service can never write one" do
    refute_includes DFH::Result.members, :build,
                    "build comes from Athletes::BuildFromMeasurements; a headshot " \
                    "cannot see a body, and a Result that could carry build is a " \
                    "Result that could write a guess"
  end

  test "a model that volunteers a build has it ignored rather than written" do
    answer = {
      "content" => [{ "type" => "text",
                      "text" => '{"person_visible": true, "skin_tone": "light", ' \
                                '"hair_description": "brown crew cut", "build": "tall and lanky"}' }],
      "usage" => { "input_tokens" => 500, "output_tokens" => 40 }
    }

    result = describe(athlete_with_headshot, answer)

    assert_equal "light", result.skin_tone
    refute_respond_to result, :build
  end

  # --- WHICH BYTES IT READS ------------------------------------------------
  #
  # THE DEFECT THIS FEATURE WAS BORN FROM. Measured on production 2026-09-26: all
  # 6,129 cached headshot objects sit under `headshots/nfl/free-agents/...` because
  # the run that uploaded them derived the folder from `contracts` (an empty table),
  # while `team_slug` is populated for all 2,051 athletes. So
  # Athlete#headshot_key_prefix computes a DIFFERENT, EMPTY folder than the one the
  # bytes are in. The ImageCache row knows where they are; the deriver does not.

  test "it downloads the key the ImageCache row recorded, not the one the athlete computes" do
    athlete = athlete_with_headshot(team_slug: "seattle-seahawks",
                                    s3_key: "headshots/nfl/free-agents/mis-filed/400.png")

    refute_equal "headshots/nfl/free-agents/mis-filed",
                 athlete.headshot_key_prefix,
                 "this test is only meaningful while the two disagree"

    asked = nil
    describe(athlete, GOOD_ANSWER, downloader: ->(key:) { asked = key; "PNGBYTES" })

    assert_equal "headshots/nfl/free-agents/mis-filed/400.png", asked
    refute_includes asked.to_s, "seattle-seahawks",
                    "recomputing the prefix looks in a folder the bytes are not in — " \
                    "that mis-filing is why this feature exists"
  end

  test "an athlete with no cached headshot is never billed for" do
    athlete = bare_athlete
    called = false

    result = DFH.new(api_key: "test-key-not-a-real-credential",
                     transport: ->(**) { called = true; GOOD_ANSWER },
                     downloader: ->(**) { "PNGBYTES" }).call(athlete)

    refute called, "no headshot means nothing to describe — and nothing to pay for"
    refute result.any?
    refute result.billed?
  end

  test "a headshot cached only at another variant is not mistaken for the one it reads" do
    athlete = athlete_with_headshot(variant: "100")
    called = false

    DFH.new(api_key: "test-key-not-a-real-credential",
            transport: ->(**) { called = true; GOOD_ANSWER },
            downloader: ->(**) { "PNGBYTES" }).call(athlete)

    refute called
  end

  # --- THE REQUEST SHAPE ---------------------------------------------------
  #
  # Asked of the real builder rather than rebuilt here: a test that stubs the post and
  # then assembles the body itself proves only that the test can assemble a body.

  test "the request carries the image as base64, at the model and caps this service declares" do
    body = nil
    describe(athlete_with_headshot, GOOD_ANSWER) { |captured| body = captured }

    assert_equal DFH::MODEL, body[:model]
    assert_equal DFH::MAX_TOKENS, body[:max_tokens]
    assert_equal DFH::SYSTEM_PROMPT, body[:system]

    image = body[:messages].first[:content].detect { |c| c[:type] == "image" }
    assert_equal "base64", image[:source][:type]
    assert_equal "image/png", image[:source][:media_type]
    assert_equal Base64.strict_encode64("PNGBYTES"), image[:source][:data]
  end

  test "the media type follows the cached row rather than assuming png" do
    body = nil
    athlete = athlete_with_headshot(content_type: "image/jpeg")
    describe(athlete, GOOD_ANSWER) { |captured| body = captured }

    image = body[:messages].first[:content].detect { |c| c[:type] == "image" }
    assert_equal "image/jpeg", image[:source][:media_type]
  end

  test "a row with no content type still sends a valid media type" do
    body = nil
    athlete = athlete_with_headshot(content_type: nil)
    describe(athlete, GOOD_ANSWER) { |captured| body = captured }

    image = body[:messages].first[:content].detect { |c| c[:type] == "image" }
    assert_equal "image/png", image[:source][:media_type]
  end

  # --- READING THE ANSWER --------------------------------------------------

  test "a well-formed answer yields both fields and its token usage" do
    result = describe(athlete_with_headshot, GOOD_ANSWER)

    assert_equal "medium-deep, warm undertone", result.skin_tone
    assert_equal "short black fade, full beard", result.hair_description
    assert result.any?
    assert result.billed?
    assert_equal({ "input" => 505, "output" => 38 }, result.usage)
    assert_equal DFH::MODEL, result.model
  end

  test "an answer wrapped in prose or a code fence is still read" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => "Here you go:\n```json\n{\"skin_tone\": \"fair\", " \
                                "\"hair_description\": \"red, shoulder length\"}\n```" }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_equal "fair", result.skin_tone
    assert_equal "red, shoulder length", result.hair_description
  end

  # THE HEDGES ARE THE DANGEROUS CASE, because they are truthy and would be written.
  # "not visible" in the column renders on the person page as though it described the
  # man, and then rides into every image prompt built from him.
  test "a hedge is normalized to nothing rather than written as a description" do
    DFH::BLANK_ANSWERS.each do |hedge|
      answer = GOOD_ANSWER.merge(
        "content" => [{ "type" => "text",
                        "text" => { skin_tone: hedge, hair_description: hedge.upcase }.to_json }]
      )

      result = describe(athlete_with_headshot, answer)

      assert_nil result.skin_tone, "#{hedge.inspect} must not be written as a skin tone"
      assert_nil result.hair_description, "#{hedge.inspect} must not be written as hair"
    end
  end

  test "a hedge with a trailing period or stray whitespace is still caught" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => '{"skin_tone": "  Not Visible. ", "hair_description": "Unknown"}' }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_nil result.skin_tone
    assert_nil result.hair_description
  end

  test "a non-string field is not written" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => '{"skin_tone": null, "hair_description": 42}' }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_nil result.skin_tone
    assert_nil result.hair_description
  end

  # EACH FIELD INDEPENDENTLY. A covered head with a clearly visible face is a real
  # and common headshot, and it must yield a skin tone and no hair rather than
  # nothing at all.
  test "one readable field and one blank yields the readable one" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => '{"person_visible": true, "skin_tone": "light-medium", ' \
                                '"hair_description": null}' }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_equal "light-medium", result.skin_tone
    assert_nil result.hair_description
    assert result.any?
  end

  test "a runaway field is truncated rather than stored whole" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => { skin_tone: "medium", hair_description: "brown " * 80 }.to_json }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_operator result.hair_description.length, :<=, DFH::MAX_FIELD_LENGTH
  end

  # --- person_visible -----------------------------------------------------

  test "person_visible false writes nothing, even when the model described something anyway" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => '{"person_visible": false, "skin_tone": "grey", ' \
                                '"hair_description": "none"}' }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_nil result.skin_tone, "a silhouette has no skin tone — 'grey' is the placeholder, not a man"
    assert_nil result.hair_description
    assert_equal false, result.person_visible
    assert result.billed?, "we paid for the answer even though we wrote none of it"
  end

  # NIL IS NOT FALSE. A terser answer that omits the flag but describes a face is
  # still usable, so only an explicit false suppresses the fields.
  test "an answer that omits person_visible is still read" do
    answer = GOOD_ANSWER.merge(
      "content" => [{ "type" => "text",
                      "text" => '{"skin_tone": "tan", "hair_description": "bald"}' }]
    )

    result = describe(athlete_with_headshot, answer)

    assert_equal "tan", result.skin_tone
    assert_equal "bald", result.hair_description
  end

  # --- THE DEGRADE --------------------------------------------------------

  test "with no credential it is unavailable and describes nothing" do
    with_env(DFH::API_KEY_ENV, nil) do
      refute DFH.available?
      result = DFH.call(athlete_with_headshot)
      refute result.any?
      refute result.billed?
    end
  end

  test "availability is decided by the env var alone, with no round trip" do
    with_env(DFH::API_KEY_ENV, "test-key-not-a-real-credential") do
      assert DFH.available?
    end
  end

  test "a transport failure degrades rather than raising, and is filed" do
    athlete = athlete_with_headshot

    assert_difference -> { ErrorLog.count }, 1 do
      result = DFH.new(api_key: "test-key-not-a-real-credential",
                       transport: ->(**) { raise IOError, "connection reset" },
                       downloader: ->(**) { "PNGBYTES" }).call(athlete)

      refute result.any?
    end

    assert_equal athlete.slug, ErrorLog.order(:id).last.target_name
  end

  test "a download failure degrades rather than raising" do
    assert_difference -> { ErrorLog.count }, 1 do
      result = DFH.new(api_key: "test-key-not-a-real-credential",
                       transport: ->(**) { GOOD_ANSWER },
                       downloader: ->(**) { raise Studio::S3::Error, "no such key" }).call(athlete_with_headshot)

      refute result.any?
    end
  end

  # WE PAID FOR THIS ONE AND COULD NOT READ IT — a different failure from an outage,
  # filed separately, and the usage is KEPT so the run's reported bill is honest.
  test "an unreadable answer keeps its cost and files a row" do
    answer = GOOD_ANSWER.merge("content" => [{ "type" => "text", "text" => "I'm afraid I can't help with that." }])

    assert_difference -> { ErrorLog.count }, 1 do
      result = describe(athlete_with_headshot, answer)

      refute result.any?
      assert result.billed?, "a run that drops the cost of what it could not read under-reports its bill"
      assert_equal({ "input" => 505, "output" => 38 }, result.usage)
    end
  end

  test "an answer that parses to a non-object is unreadable rather than accepted" do
    answer = GOOD_ANSWER.merge("content" => [{ "type" => "text", "text" => '["skin_tone", "medium"]' }])

    result = describe(athlete_with_headshot, answer)

    refute result.any?
  end

  test "a nil athlete is not an error" do
    refute DFH.new(api_key: "test-key-not-a-real-credential").call(nil).any?
  end

  private

  # Drives the real #call with both seams injected. Yields the request body when a
  # block is given, so a test can assert the shape the real builder produced.
  def describe(athlete, answer, downloader: nil, transport: nil)
    captured_transport = transport || lambda do |body:, api_key:|
      yield(body) if block_given?
      answer
    end

    DFH.new(api_key: "test-key-not-a-real-credential",
            transport: captured_transport,
            downloader: downloader || ->(key:) { "PNGBYTES" }).call(athlete)
  end

  def bare_athlete(**attrs)
    person = Person.create!(first_name: "Headshot", last_name: SecureRandom.hex(4), athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "WR", **attrs)
  end

  def athlete_with_headshot(variant: DFH::HEADSHOT_VARIANT, s3_key: nil, content_type: "image/png", **attrs)
    athlete = bare_athlete(**attrs)
    ImageCache.create!(owner: athlete, purpose: "headshot", variant: variant,
                       s3_key: s3_key || "headshots/nfl/free-agents/#{athlete.person_slug}/#{variant}.png",
                       content_type: content_type)
    athlete.reload
  end
end
