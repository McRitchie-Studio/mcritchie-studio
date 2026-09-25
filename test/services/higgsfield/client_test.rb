require "test_helper"

# [unit] The REQUEST side of the Higgsfield client — host, auth header, paths,
# and the fields each endpoint requires. All of that was measured against the
# live API on 2026-09-20 and is what this suite pins.
#
# The RESPONSE side cannot be measured: the account answers not_enough_credits
# for every media type on every host, so no successful payload has ever been
# seen. Those tests pin the client's TOLERANCE (it accepts the plausible shapes
# and fails loudly on none of them), not the API's actual answer.
class Higgsfield::ClientTest < ActiveSupport::TestCase
  def client
    Higgsfield::Client.new(api_key: "key-id", api_secret: "key-secret")
  end

  # Records what `perform` was asked to send, so everything above the socket is
  # the real object.
  def recording(service, response: {})
    calls = []
    service.define_singleton_method(:perform) do |verb, path, &blk|
      req = Struct.new(:body).new(nil)
      blk&.call(req)
      calls << { verb: verb, path: path, body: req.body && JSON.parse(req.body) }
      response
    end
    calls
  end

  test "requires both halves of the credential" do
    assert_raises(Higgsfield::Client::GenerationError) { Higgsfield::Client.new(api_key: "", api_secret: "s") }
    assert_raises(Higgsfield::Client::GenerationError) { Higgsfield::Client.new(api_key: "k", api_secret: "") }
  end

  test "authenticates with a single Key header, not the retired pair" do
    headers = client.send(:headers)

    assert_equal "Key key-id:key-secret", headers["Authorization"]
    assert_nil headers["hf-api-key"], "hf-api-key belonged to the decommissioned host"
    assert_nil headers["hf-secret"]
  end

  test "targets the current host" do
    assert_equal "https://api.higgsfield.ai", Higgsfield::Client::BASE_URL
  end

  test "image generation posts a prompt to the soul endpoint" do
    c = client
    calls = recording(c)

    c.generate_image(prompt: "a stadium at dusk")

    assert_equal 1, calls.length
    assert_equal Net::HTTP::Post, calls.first[:verb]
    assert_equal "/higgsfield-ai/soul/v2/standard", calls.first[:path]
    assert_equal "a stadium at dusk", calls.first[:body]["prompt"]
  end

  test "image generation defaults to exact 9:16, not the retired size" do
    c = client
    calls = recording(c)

    c.generate_image(prompt: "x")

    assert_equal "1152x2048", calls.first[:body]["width_and_height"]
    assert_not_equal "1024x1792", calls.first[:body]["width_and_height"]
  end

  test "video generation posts prompt and image_url to the kling endpoint" do
    c = client
    calls = recording(c)

    c.generate_video(image_url: "https://example.com/a.png", prompt: "slow push in")

    assert_equal "/kling-video/v2.5-turbo/pro/image-to-video", calls.first[:path]
    assert_equal "slow push in", calls.first[:body]["prompt"]
    assert_equal "https://example.com/a.png", calls.first[:body]["image_url"]
  end

  # The model used to be a FUNCTIONAL body field (`dop-turbo`); it is now part of
  # the path. Silently ignoring it would convert a working argument into a no-op
  # that still reads like a switch at the call site.
  test "the retired dop-turbo model is refused, not ignored" do
    error = assert_raises ArgumentError do
      client.generate_video(image_url: "https://example.com/a.png", prompt: "p", model: "dop-turbo")
    end

    assert_match "dop-turbo", error.message
    assert_match "kling-pro", error.message, "the refusal should name the valid models"
  end

  test "a nil model takes the default path" do
    c = client
    calls = recording(c)

    c.generate_video(image_url: "https://example.com/a.png", prompt: "p", model: nil)

    assert_equal "/kling-video/v2.5-turbo/pro/image-to-video", calls.first[:path]
    assert_not calls.first[:body].key?("model")
  end

  test "known model names select their own paths" do
    { "kling-pro" => "/kling-video/v2.5-turbo/pro/image-to-video",
      "kling-standard" => "/kling-video/v2.5-turbo/standard/image-to-video",
      "hailuo" => "/minimax/hailuo-2.3/standard/image-to-video" }.each do |name, path|
      c = client
      calls = recording(c)
      c.generate_video(image_url: "https://example.com/a.png", prompt: "p", model: name)
      assert_equal path, calls.first[:path], "model #{name}"
    end
  end

  test "status reads the requests status endpoint" do
    c = client
    calls = recording(c)

    c.status("req-42")

    assert_equal Net::HTTP::Get, calls.first[:verb]
    assert_equal "/requests/req-42/status", calls.first[:path]
  end

  # --- refusals ----------------------------------------------------------

  FakeResponse = Struct.new(:code, :body) do
    def is_a?(klass) = klass == Net::HTTPSuccess ? code.to_i.between?(200, 299) : super
  end

  test "an empty credit pool raises its own error, not a generic one" do
    error = assert_raises Higgsfield::Client::InsufficientCreditsError do
      client.send(:interpret, FakeResponse.new("402", '{"detail":"not_enough_credits"}'), "/x")
    end

    assert_match "top up", error.message
  end

  test "the spaced spelling of the credit error is recognised too" do
    assert_raises Higgsfield::Client::InsufficientCreditsError do
      client.send(:interpret, FakeResponse.new("400", '{"detail":"Not enough credits"}'), "/x")
    end
  end

  test "any other failure is a generation error carrying the body" do
    error = assert_raises Higgsfield::Client::GenerationError do
      client.send(:interpret, FakeResponse.new("400", '{"detail":"Unavailable model"}'), "/x")
    end

    assert_match "Unavailable model", error.message
  end

  test "a success returns the parsed body" do
    assert_equal({ "id" => "r1" }, client.send(:interpret, FakeResponse.new("200", '{"id":"r1"}'), "/x"))
  end

  # --- polling (UNVERIFIED shapes) ---------------------------------------

  test "a completed request returns its asset url" do
    c = client
    c.define_singleton_method(:status) { |_| { "status" => "completed", "results" => { "raw" => { "url" => "https://cdn/a.mp4" } } } }

    assert_equal "https://cdn/a.mp4", c.await_result("r1")
  end

  test "url extraction accepts the plausible payload shapes" do
    c = client

    assert_equal "u1", c.send(:extract_url, { "results" => { "raw" => { "url" => "u1" } } })
    assert_equal "u2", c.send(:extract_url, { "results" => { "min" => { "url" => "u2" } } })
    assert_equal "u3", c.send(:extract_url, { "url" => "u3" })
    assert_equal "u4", c.send(:extract_url, { "output_url" => "u4" })
    assert_equal "u5", c.send(:extract_url, { "outputs" => [{ "url" => "u5" }] })
  end

  # A nil URL would surface far downstream as a broken video; fail where the
  # true shape is still in hand.
  test "an unrecognised completed payload fails loudly with the payload" do
    error = assert_raises Higgsfield::Client::GenerationError do
      client.send(:extract_url, { "status" => "completed", "surprise" => "shape" })
    end

    assert_match "surprise", error.message
  end

  test "a failed request raises rather than polling forever" do
    c = client
    c.define_singleton_method(:status) { |_| { "status" => "failed", "error" => "nope" } }

    error = assert_raises(Higgsfield::Client::GenerationError) { c.await_result("r1") }
    assert_match "nope", error.message
  end

  test "an nsfw verdict is terminal" do
    c = client
    c.define_singleton_method(:status) { |_| { "status" => "nsfw" } }

    assert_raises(Higgsfield::Client::GenerationError) { c.await_result("r1") }
  end

  test "polling gives up after the maximum wait" do
    c = client
    c.define_singleton_method(:status) { |_| { "status" => "queued" } }
    c.define_singleton_method(:sleep) { |_| nil }

    clock = Object.new
    times = [Time.at(0), Time.at(1), Time.at(10_000)]
    clock.define_singleton_method(:now) { times.shift || Time.at(10_000) }

    assert_raises(Higgsfield::Client::TimeoutError) { c.await_result("r1", clock: clock) }
  end

  test "a submit with no request id fails before polling" do
    c = client
    recording(c, response: { "unexpected" => true })

    assert_raises(Higgsfield::Client::GenerationError) { c.generate_image_and_wait(prompt: "x") }
  end

  # --- the status read, given the same loud treatment as the URL read ------

  test "status is read from the plausible keys" do
    c = client

    assert_equal "completed", c.send(:extract_status, { "status" => "Completed" })
    assert_equal "queued",    c.send(:extract_status, { "state" => "QUEUED" })
    assert_equal "running",   c.send(:extract_status, { "data" => { "status" => "running" } })
  end

  # The asymmetry that mattered: a finished asset under an unexpected key used
  # to parse as "", match nothing, and poll the full 300s before raising a
  # TimeoutError that named no payload.
  test "an unreadable status raises immediately with the payload, not a timeout" do
    c = client
    c.define_singleton_method(:status) { |_| { "phase" => "completed", "asset" => "x" } }
    c.define_singleton_method(:sleep) { |_| flunk("should not have polled") }

    error = assert_raises(Higgsfield::Client::GenerationError) { c.await_result("r1") }

    assert_match "no recognisable status key", error.message
    assert_match "phase", error.message, "the payload must be printed so the true shape is learned"
  end

  # --- character identity (custom references) -----------------------------
  #
  # UNLIKE EVERY OTHER RESPONSE ASSERTION IN THIS FILE, these pin a shape that
  # was MEASURED. On 2026-09-24 one real create was made against the live API
  # with the production credential and driven to rest:
  #
  #   POST /v1/custom-references
  #     {"name":"mcritchie-probe-alec-anderson",
  #      "input_images":[{"type":"image_url","image_url":"https://turf-monster-production.s3…/400.png"}]}
  #   -> 200 {"id":"1af15765-27b3-461a-8804-b2de098c72c3","model_version":"v1",
  #           "name":"…","status":"not_ready","thumbnail_url":null,
  #           "created_at":"2026-09-25T02:03:42.811608Z","in_progress_at":null,
  #           "fail_reason":null}
  #
  # and a poll of GET /v1/custom-references/<id> walked
  # not_ready -> queued -> in_progress -> completed.
  #
  # Nothing below touches the network. Every call to this API costs money, so
  # the suite drives the recorded `perform` and asserts what would have gone out.

  test "a custom reference wraps each URL in the object the API demands" do
    c = client
    calls = recording(c, response: { "id" => "1af15765-27b3-461a-8804-b2de098c72c3" })

    c.create_custom_reference(name: "Josh Allen home", image_urls: ["https://example.com/a.png"])

    assert_equal 1, calls.length
    assert_equal Net::HTTP::Post, calls.first[:verb]
    assert_equal "/v1/custom-references", calls.first[:path]
    assert_equal "Josh Allen home", calls.first[:body]["name"]
    assert_equal [{ "type" => "image_url", "image_url" => "https://example.com/a.png" }],
                 calls.first[:body]["input_images"],
                 "a bare URL string answers 422 model_attributes_type — the item MUST be an object"
  end

  test "every reference image is wrapped, not just the first" do
    c = client
    calls = recording(c, response: { "id" => "1af15765-27b3-461a-8804-b2de098c72c3" })

    c.create_custom_reference(name: "sheet", image_urls: %w[https://e.com/1.png https://e.com/2.png https://e.com/3.png])

    types = calls.first[:body]["input_images"].map { |i| i["type"] }
    urls  = calls.first[:body]["input_images"].map { |i| i["image_url"] }
    assert_equal %w[image_url image_url image_url], types
    assert_equal %w[https://e.com/1.png https://e.com/2.png https://e.com/3.png], urls
  end

  test "the created reference returns its uuid" do
    c = client
    recording(c, response: { "id" => "1af15765-27b3-461a-8804-b2de098c72c3", "status" => "not_ready" })

    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3",
                 c.create_custom_reference(name: "x", image_urls: ["https://e.com/1.png"])
  end

  # The API answers 422 too_short on an empty list. Refusing locally is the
  # difference between a free raise and a paid rejection.
  test "an empty reference list is refused before it reaches the wire" do
    c = client
    c.define_singleton_method(:perform) { |*| flunk("nothing should have been sent") }

    assert_raises(ArgumentError) { c.create_custom_reference(name: "x", image_urls: []) }
    assert_raises(ArgumentError) { c.create_custom_reference(name: "x", image_urls: [nil, "", "  "]) }
  end

  test "an id that is not a uuid fails at the create, not inside a paid generation" do
    c = client
    recording(c, response: { "id" => "reference_1234" })

    error = assert_raises(Higgsfield::Client::GenerationError) do
      c.create_custom_reference(name: "x", image_urls: ["https://e.com/1.png"])
    end
    assert_match "not a UUID", error.message
  end

  test "a create with no id in the answer raises with the payload" do
    c = client
    recording(c, response: { "status" => "not_ready" })

    error = assert_raises(Higgsfield::Client::GenerationError) do
      c.create_custom_reference(name: "x", image_urls: ["https://e.com/1.png"])
    end
    assert_match "no id in custom-reference response", error.message
    assert_match "not_ready", error.message, "the payload must be printed so the true shape is learned"
  end

  test "one reference is read by id, because the collection cannot be listed" do
    c = client
    calls = recording(c, response: { "status" => "completed" })

    c.custom_reference("1af15765-27b3-461a-8804-b2de098c72c3")

    assert_equal Net::HTTP::Get, calls.first[:verb]
    assert_equal "/v1/custom-references/1af15765-27b3-461a-8804-b2de098c72c3", calls.first[:path]
  end

  # --- pinning a generation to an identity --------------------------------

  test "a generation pinned to an identity carries both fields" do
    c = client
    calls = recording(c)

    c.generate_image(prompt: "a stadium at dusk",
                     custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                     custom_reference_strength: 0.8)

    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3", calls.first[:body]["custom_reference_id"]
    assert_in_delta 0.8, calls.first[:body]["custom_reference_strength"], 0.0001
  end

  # Absent is not null. A body carrying an explicit null asks the validator a
  # question an unpinned generation never had to ask.
  test "an unpinned generation sends neither key, not null ones" do
    c = client
    calls = recording(c)

    c.generate_image(prompt: "x")

    assert_not_includes calls.first[:body].keys, "custom_reference_id"
    assert_not_includes calls.first[:body].keys, "custom_reference_strength"
  end

  test "an identity may be pinned without naming a strength" do
    c = client
    calls = recording(c)

    c.generate_image(prompt: "x", custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3")

    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3", calls.first[:body]["custom_reference_id"]
    assert_not_includes calls.first[:body].keys, "custom_reference_strength"
  end

  # 0.0 is a legal value with a meaning, and it is the one a `present?` guard
  # would be most likely to swallow.
  test "a strength of zero is sent, not dropped as blank" do
    c = client
    calls = recording(c)

    c.generate_image(prompt: "x", custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                     custom_reference_strength: 0)

    assert_equal 0.0, calls.first[:body]["custom_reference_strength"]
  end

  # Measured: 99 answers less_than_equal (le 1.0), -5 answers greater_than_equal
  # (ge 0.0), "banana" answers float_parsing. Each is a paid round-trip.
  test "a strength outside nought-to-one is refused locally" do
    c = client
    c.define_singleton_method(:perform) { |*| flunk("nothing should have been sent") }

    %w[1.0 0.0].each do |ok|
      # sanity: the ends of the range are legal, so the guard is not off-by-one
      inner = client
      calls = recording(inner)
      inner.generate_image(prompt: "x", custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                           custom_reference_strength: ok.to_f)
      assert_equal ok.to_f, calls.first[:body]["custom_reference_strength"]
    end

    [99, -5, 1.01].each do |bad|
      error = assert_raises(ArgumentError) do
        c.generate_image(prompt: "x", custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                         custom_reference_strength: bad)
      end
      assert_match "must fall in", error.message, "an out-of-range value must not be reported as unparseable"
    end
  end

  test "an unparseable strength names parsing, not range" do
    c = client
    c.define_singleton_method(:perform) { |*| flunk("nothing should have been sent") }

    error = assert_raises(ArgumentError) do
      c.generate_image(prompt: "x", custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                       custom_reference_strength: "banana")
    end
    assert_match "must be a number", error.message
  end

  test "a non-uuid identity is refused before it costs a 422" do
    c = client
    c.define_singleton_method(:perform) { |*| flunk("nothing should have been sent") }

    error = assert_raises(ArgumentError) { c.generate_image(prompt: "x", custom_reference_id: "reference_1") }
    assert_match "not a UUID", error.message
  end

  # The same rule #video_path_for follows: an argument that would be silently
  # ignored is a knob the caller thinks they turned.
  test "a strength with no identity is refused rather than dropped" do
    c = client
    c.define_singleton_method(:perform) { |*| flunk("nothing should have been sent") }

    error = assert_raises(ArgumentError) { c.generate_image(prompt: "x", custom_reference_strength: 0.8) }
    assert_match "no custom_reference_id", error.message
  end

  test "the waiting form forwards the identity too" do
    c = client
    calls = recording(c, response: { "id" => "req-1" })
    c.define_singleton_method(:await_result) { |id, **| "url-for-#{id}" }

    c.generate_image_and_wait(prompt: "x",
                              custom_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                              custom_reference_strength: 0.5)

    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3", calls.first[:body]["custom_reference_id"],
                 "the wait wrapper must not drop what generate_image accepts"
    assert_in_delta 0.5, calls.first[:body]["custom_reference_strength"], 0.0001
  end
end
