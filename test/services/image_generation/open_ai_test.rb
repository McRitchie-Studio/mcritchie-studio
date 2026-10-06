require "test_helper"

# [unit] THE OpenAI ADAPTER — the Responses API with the `image_generation` tool.
#
# NOTHING HERE TOUCHES THE NETWORK, and that is ASSERTED rather than assumed. The
# first tests prove the suite-wide trap is armed and that THIS suite is what armed
# it; every other test swaps `perform` for a recorder, so the real object above
# the socket is exercised and the socket never opens.
#
# ⚠ WHY THE TRAP MATTERS MORE HERE THAN ANYWHERE ELSE: one call to this adapter
# buys a ten-panel character sheet. It is the most expensive single request the
# app can make.
class ImageGeneration::OpenAITest < ActiveSupport::TestCase
  # 1x1 transparent PNG, so the reference fetch has real bytes to base64 without
  # reaching S3.
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    ImageGeneration::Registry.reload!
    @row = ImageGeneration::Registry.find!("openai_gpt5_sheet")
  end

  # THE ROW IS SHARED. `Registry.find!` hands back the process-wide memoized row, and
  # two cases below stub `reference_arity` on it with a singleton method. The setup
  # above reloads before each case HERE, but nothing reloaded after the last one, so
  # whichever case ran last left its stub on the row every later test in the process
  # reads. When that was the "many" case, GeneratorRecordTripwireTest's arity guard
  # went red on a registry file nobody had touched (accepted CI, 2026-09-30, twice,
  # after new tests reshuffled the shards). Reproduce on the pre-fix file with
  # `--seed 13` over this file and that one.
  teardown do
    ImageGeneration::Registry.reload!
  end

  # PINS THE LITERAL IN test/test_helper.rb AGAINST THE CONSTANT. The helper runs
  # before Zeitwerk can autoload this class, so it spells the variable by hand;
  # without this the two could drift and the trap would quietly stop being armed.
  test "the suite arms the no-live-calls trap under the name the adapter reads" do
    assert_equal "OPENAI_NO_LIVE_CALLS", ImageGeneration::OpenAI::NO_LIVE_CALLS_ENV
    assert_equal "1", ENV.fetch("OPENAI_NO_LIVE_CALLS", nil),
                 "test/test_helper.rb must arm this before config/environment"
    assert_predicate ImageGeneration::OpenAI, :armed?
  end

  test "a live call raises outside StandardError so no degrade can swallow it" do
    client = client_with_reference

    assert_raises(ImageGeneration::OpenAI::LiveCallAttempted) do
      client.generate_and_wait(prompt: "sheet", reference_urls: ["https://example.com/a.png"])
    end

    assert_not_operator ImageGeneration::OpenAI::LiveCallAttempted, :<=, StandardError,
                        "a StandardError trap would be swallowed by the callers it guards"
  end

  test "an absent credential refuses at construction and names the variable" do
    error = with_env("OPENAI_API_KEY" => nil) do
      assert_raises(ImageGeneration::OpenAI::NotConfigured) do
        ImageGeneration::OpenAI.new(@row, api_key: nil)
      end
    end

    assert_includes error.message, "OPENAI_API_KEY"
  end

  # ⚠ THE SHAPE IS THE FINDING. /v1/images/edits was measured to lose identity on
  # a single portrait with one reference AND with five. This request must be the
  # Responses tool call, with the reference INLINED as a data URI.
  test "the request is a Responses tool call carrying the reference as a data URI" do
    client = client_with_reference
    calls = recording(client)

    client.generate_and_wait(prompt: "the sheet prompt", reference_urls: ["https://example.com/a.png"])

    body = calls.sole
    assert_equal [{ "type" => "image_generation" }], body["tools"],
                 "the image_generation TOOL is what carries identity across panels"
    content = body.dig("input", 0, "content")
    assert_equal "input_image", content[0]["type"]
    assert content[0]["image_url"].start_with?("data:image/png;base64,"),
           "the reference is sent as BYTES, not as a URL for the vendor to fetch"
    assert_equal "the sheet prompt", content[1]["text"]
  end

  # ---- how many references ride, and why -----------------------------------------
  #
  # THE DEFECT THESE THREE CASES CLOSE. The signature was plural, the body took
  # `urls.first`, and `request_body` emitted ONE `input_image` block — so a caller handing
  # over a distilled set of four photographs had three dropped with nothing logged,
  # nothing raised and nothing on the page. The truncation is now the ROW'S DECLARED
  # ARITY, which is a sentence a reader can go and check.

  # THE PLURAL PATH, BUILT AND TESTED THOUGH THE SHEET ROW DOES NOT YET USE IT. The
  # registry row declares `one`; when a measurement justifies `many`, this is the shape
  # that ships, and it is asserted now so the two never have to be written at once.
  test "a row that accepts many references sends one input_image block per photograph" do
    client = client_with_reference
    client.row.define_singleton_method(:reference_arity) { "many" }
    calls = recording(client)

    client.generate_and_wait(prompt: "the sheet prompt",
                             reference_urls: %w[https://example.com/a.png
                                                https://example.com/b.png
                                                https://example.com/c.png])

    content = calls.sole.dig("input", 0, "content")
    images = content.select { |block| block["type"] == "input_image" }
    assert_equal 3, images.length, "every reference the caller vetted must actually ride"
    assert images.all? { |block| block["image_url"].start_with?("data:image/png;base64,") }
    assert_equal "input_text", content.last["type"],
                 "the instruction refers to references it has just been shown, so it goes LAST"
  end

  # THE ROW'S WORD IS HONOURED, exactly as ImageGeneration::Fal honours it. This is the
  # behaviour that ships today for the sheet generator.
  test "a row that accepts one reference sends the first and only the first" do
    client = client_with_reference
    assert_equal "one", client.row.reference_arity,
                 "if the registry row ever changes this, the case below is asserting nothing"
    calls = recording(client)

    client.generate_and_wait(prompt: "p",
                             reference_urls: %w[https://example.com/a.png https://example.com/b.png])

    images = calls.sole.dig("input", 0, "content").select { |b| b["type"] == "input_image" }
    assert_equal 1, images.length
  end

  # AN UNDECLARED ARITY SENDS EVERYTHING, which is the opposite of the old default and is
  # the safer way round: a row that forgot to declare it earns a loud vendor error rather
  # than quietly building a likeness from a fifth of the evidence.
  test "a row declaring no arity at all sends every reference" do
    client = client_with_reference
    client.row.define_singleton_method(:reference_arity) { nil }
    calls = recording(client)

    client.generate_and_wait(prompt: "p",
                             reference_urls: %w[https://example.com/a.png https://example.com/b.png])

    images = calls.sole.dig("input", 0, "content").select { |b| b["type"] == "input_image" }
    assert_equal 2, images.length
  end

  # A DATED SNAPSHOT, NOT THE ALIAS. An alias that silently rolls forward is
  # exactly what the operator's "deterministic" forbids.
  test "the pinned model snapshot is sent, not a moving alias" do
    client = client_with_reference
    calls = recording(client)

    client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"])

    assert_equal "gpt-5-2025-08-07", calls.sole["model"]
    assert_not_equal "gpt-5", calls.sole["model"], "the alias is not deterministic"
  end

  # THE OUTPUT ARRAY CARRIES REASONING AND MESSAGE ITEMS ALONGSIDE THE IMAGE, so
  # the image is selected BY TYPE. A positional read breaks the day the vendor
  # appends anything.
  test "the image is found by type among other output items" do
    client = client_with_reference
    client.define_singleton_method(:perform) do |body:|
      {
        "id" => "resp_1",
        "output" => [
          { "type" => "reasoning", "summary" => [] },
          { "type" => "image_generation_call", "result" => Base64.strict_encode64("PNGBYTES") },
          { "type" => "message", "content" => [] }
        ],
        "usage" => { "total_tokens" => 18_432 }
      }
    end

    result = client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"])

    assert_equal 1, result.image_urls.length
    assert result.primary_url.start_with?("data:image/png;base64,")
    assert_equal "resp_1", result.request_id
    assert_equal @row.provenance_version, result.version
  end

  # THE VENDOR REPORTS TOKENS, NOT IMAGES, and the two must never be read as one
  # number. The row declares no price, so the cost is NOT REPORTED rather than
  # invented from a made-up token rate.
  test "usage is recorded as tokens and no dollar cost is invented" do
    client = client_with_reference
    client.define_singleton_method(:perform) do |body:|
      { "id" => "resp_1",
        "output" => [{ "type" => "image_generation_call", "result" => Base64.strict_encode64("X") }],
        "usage" => { "total_tokens" => 18_432 } }
    end

    result = client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"])

    assert_equal 18_432, result.billable_units
    assert_nil result.cost_usd, "no unit price is declared, so a price would be fabricated"
    assert_equal "tokens", @row.billing_unit_name
  end

  # A SEED THAT CANNOT BE HONOURED MUST NOT BE RECORDED. The Responses image tool
  # exposes no seed, so stamping one on the artifact would assert a reproducibility
  # that does not exist.
  test "a seed is neither sent nor recorded, because the tool has none" do
    client = client_with_reference
    calls = recording(client)

    result = client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"], seed: 42)

    assert_not calls.sole.key?("seed")
    assert_nil result.seed, "recording a seed the vendor ignored would be a false determinism claim"
  end

  # THE HEADER ROW'S SIZE, and only when asked. The sheet's measured request
  # shape must stay byte-identical: no size key unless a caller passes one.
  test "the tool size is sent only when a valid one is asked for" do
    client = client_with_reference
    calls = recording(client)

    client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"], image_size: "1536x1024")
    client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"])
    client.generate_and_wait(prompt: "p", reference_urls: ["https://example.com/a.png"], image_size: "landscape_16_9")

    assert_equal [{ "type" => "image_generation", "size" => "1536x1024" }], calls[0]["tools"]
    assert_equal [{ "type" => "image_generation" }], calls[1]["tools"]
    assert_equal [{ "type" => "image_generation" }], calls[2]["tools"], "a fal preset name is not this vendor's size"
  end

  test "an inline data URI reference is sent as given, without a download" do
    client = ImageGeneration::OpenAI.new(@row, api_key: "sk-test")
    client.define_singleton_method(:fetch_reference) { |_url| raise "an inline reference must not be fetched" }
    calls = recording(client)
    inline = "data:image/png;base64,#{Base64.strict_encode64(PNG)}"

    client.generate_and_wait(prompt: "p", reference_urls: [inline])

    assert_equal inline, calls.sole.dig("input", 0, "content", 0, "image_url")
  end

  test "no reference refuses before it can spend" do
    client = client_with_reference
    calls = recording(client)

    assert_raises(ImageGeneration::OpenAI::GenerationError) do
      client.generate_and_wait(prompt: "p", reference_urls: [])
    end
    assert_empty calls, "the refusal must happen before the POST"
  end

  # A CALLER SHOULD NEVER HAVE TO ENUMERATE ADAPTERS. That list goes stale in the
  # direction that lets an exception escape as a 500.
  test "the adapter's failure is rescuable as the shared ImageGeneration error" do
    assert_operator ImageGeneration::OpenAI::GenerationError, :<, ImageGeneration::GenerationFailed
    assert_operator ImageGeneration::Fal::GenerationError, :<, ImageGeneration::GenerationFailed
  end

  # ZEITWERK RESOLVES open_ai.rb TO OpenAI ONLY BECAUSE AN INFLECTION SAYS SO.
  # Without config/initializers/inflections.rb this constant is OpenAi and every
  # reference above is a NameError at boot.
  test "the autoloader resolves the adapter's constant name" do
    assert_equal "ImageGeneration::OpenAI", ImageGeneration::OpenAI.name
    assert_equal ImageGeneration::OpenAI, ImageGeneration::Adapter.for(@row)
  end

  private

  def client_with_reference
    client = ImageGeneration::OpenAI.new(@row, api_key: "sk-test")
    # Stub only the reference DOWNLOAD, so the data-URI construction under test is
    # the real code path while nothing leaves the process.
    client.define_singleton_method(:fetch_reference) { |_url| [PNG, "image/png"] }
    client
  end

  def recording(client, response: nil)
    bodies = []
    payload = response || {
      "id" => "resp_1",
      "output" => [{ "type" => "image_generation_call", "result" => Base64.strict_encode64("X") }],
      "usage" => { "total_tokens" => 100 }
    }
    client.define_singleton_method(:perform) do |body:|
      bodies << JSON.parse(JSON.generate(body))
      payload
    end
    bodies
  end

  def with_env(pairs)
    original = pairs.keys.index_with { |k| ENV[k] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
