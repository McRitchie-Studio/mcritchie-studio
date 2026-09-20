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

  # The model used to be a body field (`dop-turbo`); it is now part of the path.
  # Passing it must not put an unknown field on the wire.
  test "a legacy model argument is ignored rather than sent" do
    c = client
    calls = recording(c)

    c.generate_video(image_url: "https://example.com/a.png", prompt: "p", model: "dop-turbo")

    assert_not calls.first[:body].key?("model")
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
end
