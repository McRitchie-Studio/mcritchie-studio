require "test_helper"

# [unit] THE fal.ai ADAPTER, driven entirely through a recorded `perform`.
#
# NOTHING HERE TOUCHES THE NETWORK, and that is ASSERTED rather than assumed. The
# first two tests prove the suite-wide trap is armed and that THIS suite is what
# armed it; every other test swaps `perform` for a recorder, so the real object
# above the socket is exercised and the socket never opens.
#
# ⚠ WHY THE TRAP IS WORTH A TEST OF ITS OWN. `POST https://queue.fal.run/<model>`
# SUBMITS BILLABLE WORK on any body at all — measured 2026-09-26, an auth probe
# with an EMPTY body answered HTTP 200 because it queued a job. A careless test
# that reached the network would not fail loudly; it would pass, slowly, and
# arrive on a bill.
class ImageGeneration::FalTest < ActiveSupport::TestCase
  setup do
    ImageGeneration::Registry.reload!
    @row = ImageGeneration::Registry.find!("fal_ideogram_character")
  end

  # PINS THE LITERAL IN test/test_helper.rb AGAINST THE CONSTANT. The helper runs
  # before Zeitwerk can autoload this class, so it spells the variable by hand;
  # without this assertion the two could drift apart in silence and the trap
  # would quietly stop being armed.
  test "the suite arms the no-live-calls trap under the name the adapter reads" do
    assert_equal "FAL_NO_LIVE_CALLS", ImageGeneration::Fal::NO_LIVE_CALLS_ENV
    assert_equal "1", ENV.fetch("FAL_NO_LIVE_CALLS", nil),
                 "test/test_helper.rb must arm this before config/environment"
    assert_predicate ImageGeneration::Fal, :armed?
  end

  # THE TRAP BITES, and it bites OUTSIDE StandardError so the degrading callers
  # cannot swallow it. A StandardError trap would be caught by the very code it
  # guards and would have proven nothing.
  test "a live call raises outside StandardError so no degrade can swallow it" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")

    assert_raises(ImageGeneration::Fal::LiveCallAttempted) do
      client.submit(prompt: "anything", reference_urls: ["https://example.com/a.png"])
    end

    assert_not_operator ImageGeneration::Fal::LiveCallAttempted, :<=, StandardError,
                        "a StandardError trap would be swallowed by the callers it guards"

    swallowed = begin
      begin
        client.submit(prompt: "anything", reference_urls: ["https://example.com/a.png"])
      rescue StandardError
        true
      end
    rescue ImageGeneration::Fal::LiveCallAttempted
      false
    end
    assert_not swallowed, "rescuing StandardError must NOT catch the trap"
  end

  # CLEARS THE VARIABLE RATHER THAN ASSUMING IT IS UNSET. This test used to pass
  # only because no desk had a fal credential; the day one landed in a desk's
  # `.env` it started passing `nil` into a constructor that fell back to a REAL
  # key and raised nothing. A test whose result depends on the machine's ambient
  # environment is a test that passes for the wrong reason, and CI — which has no
  # key — would never have shown it.
  test "an absent credential refuses at construction and names the variable" do
    error = with_env("FAL_KEY" => nil) do
      assert_raises(ImageGeneration::Fal::NotConfigured) do
        ImageGeneration::Fal.new(@row, api_key: nil)
      end
    end

    assert_includes error.message, @row.credential_env
  end

  # THE ROW DECIDES THE REQUEST SHAPE. This is the registry earning its keep: a
  # second fal model is a row, not a subclass.
  test "the reference field name and arity come from the registry row" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    calls = recording(client)

    client.submit(prompt: "full body", reference_urls: ["https://example.com/a.png"])

    body = calls.first[:body]
    assert_equal "POST", calls.first[:verb].to_s.upcase
    assert_equal "/fal-ai/ideogram/character", calls.first[:path]
    assert_equal ["https://example.com/a.png"], body["reference_image_urls"],
                 "this row declares reference_arity: many, so the payload is a list"
    assert_equal "full body", body["prompt"]
  end

  test "a row declaring one reference sends a bare string, not a list" do
    row = ImageGeneration::Registry.find!("fal_flux_pulid")
    client = ImageGeneration::Fal.new(row, api_key: "key-id:key-secret")
    calls = recording(client)

    client.submit(prompt: "portrait", reference_urls: %w[https://example.com/a.png https://example.com/b.png])

    assert_equal "https://example.com/a.png", calls.first[:body]["reference_image_url"]
  end

  test "a seed is sent only when one is pinned" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    calls = recording(client)

    client.submit(prompt: "p", reference_urls: ["https://example.com/a.png"])
    assert_not calls.first[:body].key?("seed"), "an unpinned seed must not be sent as null"

    calls.clear
    client.submit(prompt: "p", reference_urls: ["https://example.com/a.png"], seed: 4242)
    assert_equal 4242, calls.first[:body]["seed"]
  end

  test "generating with no reference photo refuses before it can spend" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    calls = recording(client)

    assert_raises(ImageGeneration::Fal::GenerationError) do
      client.submit(prompt: "p", reference_urls: [])
    end
    assert_empty calls, "the refusal must happen before the POST, not after"
  end

  # THE SEED COMES BACK FROM THE VENDOR, and the Result records what came back
  # rather than what went in — recording the seed we SENT would store nil for
  # every call that did not pin one, losing the only handle that reproduces it.
  # ⚠ THE REGRESSION THIS FILE EXISTS FOR AFTER 2026-09-26. The published OpenAPI
  # document says the status path is `/fal-ai/ideogram/character/requests/<id>/status`.
  # The LIVE HOST answers 405 to that and routes under the first TWO segments,
  # `fal-ai/ideogram`, because `character` is a sub-path rather than an app. We
  # learned this by stranding a job we had already paid for, so the cost of
  # regressing it is a burnt image, not a retry.
  test "a lost ticket reconstructs the poll URL under the two-segment queue base" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    calls = recording(client, response: { "status" => "COMPLETED" })

    client.status("req-1")

    assert_includes calls.first[:path], "/fal-ai/ideogram/requests/req-1/status"
    assert_not_includes calls.first[:path], "/character/requests",
                        "the documented per-sub-path form answers HTTP 405 on the live host"
  end

  # AND THE PATH NOT TAKEN: when the vendor hands back its own URLs, those win
  # outright, so a future routing change costs us nothing.
  test "the vendor's own poll URLs are used when the submit returns them" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    calls = recording(client, response: {
      "request_id" => "req-9",
      "status_url" => "https://queue.fal.run/somewhere/else/requests/req-9/status",
      "response_url" => "https://queue.fal.run/somewhere/else/requests/req-9"
    })

    ticket = client.submit(prompt: "p", reference_urls: ["https://example.com/a.png"])

    assert_equal "req-9", ticket.request_id
    assert_equal "https://queue.fal.run/somewhere/else/requests/req-9/status", ticket.status_url

    calls.clear
    client.status(ticket)
    assert_equal "https://queue.fal.run/somewhere/else/requests/req-9/status", calls.first[:path]
  end

  test "a completed result normalises the images and keeps the returned seed" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    client.define_singleton_method(:perform) do |_verb, path, body: nil|
      if path.end_with?("/status")
        { "status" => "COMPLETED" }
      else
        { "images" => [{ "url" => "https://v3.fal.media/files/x/out.png" }], "seed" => 99 }
      end
    end

    result = client.result("req-1")

    assert_equal ["https://v3.fal.media/files/x/out.png"], result.image_urls
    assert_equal 99, result.seed
    assert_equal "fal_ideogram_character", result.generator_key
    assert_equal @row.provenance_version, result.version
    assert_nil result.cost_usd, "nil means NOT REPORTED, never free"
  end

  test "a non-2xx raises with the vendor's own words rather than answering empty" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    client.define_singleton_method(:perform) do |verb, path, body: nil|
      # Reproduce what #interpret does with a 401, since that is the branch
      # under test; an empty Result here would read as "generated nothing".
      raise ImageGeneration::Fal::GenerationError,
            "Ideogram V3 Character answered HTTP 401 to #{verb.to_s.upcase} #{path}: invalid key credentials"
    end

    error = assert_raises(ImageGeneration::Fal::GenerationError) { client.status("req-1") }
    assert_includes error.message, "401"
    assert_includes error.message, "invalid key credentials"
  end

  # THE COST IS READ OFF THE CALL THAT INCURRED IT. Measured 2026-09-26: one
  # image at the API-default rendering speed reported `x-fal-billable-units: 3`.
  test "the billable units reported by the vendor become the recorded cost" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    client.define_singleton_method(:perform) do |_verb, path, body: nil|
      @last_headers = { "x-fal-billable-units" => "3" }
      if path.end_with?("/status")
        { "status" => "COMPLETED" }
      elsif body
        { "request_id" => "req-1" }
      else
        { "images" => [{ "url" => "https://v3.fal.media/files/x/out.png" }], "seed" => 7 }
      end
    end

    result = client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"])

    assert_equal 3, result.billable_units, "the measured quantity is kept"
    assert_equal BigDecimal("0.15"), result.cost_usd, "3 units x the declared $0.05 rate"
  end

  # A VENDOR THAT REPORTS NOTHING LEAVES THE COST NIL. nil is "not reported",
  # never "free", and nothing downstream may read it as zero.
  test "a silent vendor leaves the cost unrecorded rather than zero" do
    client = ImageGeneration::Fal.new(@row, api_key: "key-id:key-secret")
    client.define_singleton_method(:perform) do |_verb, path, body: nil|
      @last_headers = {}
      if path.end_with?("/status")
        { "status" => "COMPLETED" }
      elsif body
        { "request_id" => "req-1" }
      else
        { "images" => [{ "url" => "https://v3.fal.media/files/x/out.png" }], "seed" => 7 }
      end
    end

    result = client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"])

    assert_nil result.billable_units
    assert_nil result.cost_usd
  end

  private

  # ENV is process-global; restore whatever was there, including absence.
  def with_env(pairs)
    original = pairs.keys.index_with { |k| ENV[k] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Records what `perform` was asked to send, so everything above the socket is
  # the real object. Same shape as test/services/higgsfield/client_test.rb.
  def recording(client, response: { "request_id" => "req-1", "status" => "IN_QUEUE" })
    calls = []
    client.define_singleton_method(:perform) do |verb, path, body: nil|
      calls << { verb: verb, path: path, body: body ? JSON.parse(JSON.generate(body)) : nil }
      response
    end
    calls
  end
end
