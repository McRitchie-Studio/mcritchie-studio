require "net/http"
require "json"
require "base64"

module ImageGeneration
  # THE OpenAI ADAPTER — the Responses API with the `image_generation` TOOL.
  #
  # ⚠ THE ENDPOINT IS THE WHOLE FINDING, and the obvious one is wrong.
  #
  # DO NOT USE /v1/images/edits. Measured 2026-09-26 on the same reference and the
  # same prompt: it lost identity even on a SINGLE portrait — "different facial
  # structure, age, and facial hair" — and five reference photos were no better.
  # That endpoint EDITS a picture. The Responses tool LOOKS at the reference,
  # REASONS, then generates, and that reasoning step is what carries a likeness
  # across ten panels. It is the only path measured to hold a character sheet.
  #
  # THE SHAPE, measured rather than read off a doc:
  #
  #   POST https://api.openai.com/v1/responses
  #   { model: "<pinned snapshot>",
  #     tools: [{ type: "image_generation" }],
  #     input: [{ role: "user", content: [
  #       { type: "input_image", image_url: "data:image/png;base64,..." },
  #       { type: "input_text",  text: "<prompt>" }] }] }
  #
  # The image comes back BASE64 in `output[].result` on the element whose `type`
  # is `image_generation_call`.
  #
  # THE REFERENCE IS INLINED AS A DATA URI, which is the one structural difference
  # from ImageGeneration::Fal and the reason this is a separate adapter rather
  # than another row. fal is handed a URL and fetches it server-side; this is
  # handed the BYTES. So the adapter downloads our own S3 object and base64s it —
  # and that download is the only place this class touches a URL we did not build.
  #
  # ONE REFERENCE IS ENOUGH. Five measured no better than one, so `reference_arity`
  # is `one` and extra URLs are dropped rather than concatenated into a bigger,
  # slower, no-better request.
  class OpenAI
    OPEN_TIMEOUT = 10

    # GENEROUS ON PURPOSE. A ten-panel sheet is a reasoning pass plus an image
    # generation, and the measured runs took minutes rather than seconds. A
    # timeout here costs the call we already paid for — the work completes on the
    # vendor's side either way.
    READ_TIMEOUT = 600

    # The reference download. Short, because it is our own S3 object and a slow
    # one means something is wrong rather than something is big.
    REFERENCE_OPEN_TIMEOUT = 5
    REFERENCE_READ_TIMEOUT = 30
    MAX_REFERENCE_BYTES = 20 * 1024 * 1024

    NO_LIVE_CALLS_ENV = "OPENAI_NO_LIVE_CALLS".freeze

    IMAGE_CALL_TYPE = "image_generation_call".freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # DESCENDS FROM THE SHARED ANCESTOR — see ImageGeneration::GenerationFailed.
    class GenerationError < ImageGeneration::GenerationFailed; end

    # DELIBERATELY OUTSIDE StandardError, for the reason written up at length on
    # ImageGeneration::Fal::LiveCallAttempted: every caller of this adapter
    # degrades rather than raises, so a StandardError trap would be swallowed by
    # the very code it guards and the careless test would pass quietly while the
    # bill arrived anyway.
    class LiveCallAttempted < Exception; end # rubocop:disable Lint/InheritException

    def self.armed? = ENV[NO_LIVE_CALLS_ENV].to_s == "1"

    attr_reader :row, :last_usage

    def initialize(row, api_key: nil, clock: Time)
      @row = row
      @api_key = api_key || ENV[row.credential_env.to_s]
      @clock = clock
      raise NotConfigured, row.unconfigured_message if @api_key.blank?
    end

    # ⚠ SPENDS MONEY. One call, one image. Admin-gated at every call site.
    #
    # SYNCHRONOUS, unlike the fal adapter's queue-and-poll — the Responses API
    # answers on the original request, which is why READ_TIMEOUT is measured in
    # minutes rather than seconds and why there is no Ticket here.
    #
    # `seed:` IS ACCEPTED AND DELIBERATELY NOT SENT. The Responses image tool
    # exposes no seed parameter, so passing one through would record a pinned seed
    # on the artifact that had no effect on the output — a determinism claim that
    # is not true. It is accepted so the shared use case can call every adapter
    # the same way; it lands in the Result as nil, which reads as "not reported".
    def generate_and_wait(prompt:, reference_urls:, seed: nil, image_size: nil, num_images: 1)
      urls = Array(reference_urls).compact_blank
      raise GenerationError, "#{row.label} needs a reference image" if urls.empty?

      payload = perform(body: request_body(prompt: prompt, reference_url: urls.first))
      images = extract_images(payload)
      raise GenerationError, "#{row.label} returned no image" if images.empty?

      Result.new(
        image_urls: images,
        seed: nil,
        request_id: payload["id"].presence,
        generator_key: row.key,
        version: row.provenance_version,
        billable_units: total_tokens(payload),
        cost_usd: row.price_for(total_tokens(payload)),
        raw: payload.except("output")
      )
    end

    # THE REFERENCE, AS BYTES. Public so a caller can pre-flight a reference
    # without buying a generation — the failure it catches (an S3 key that moved)
    # is otherwise only visible after paying.
    def data_uri_for(url)
      bytes, content_type = fetch_reference(url)
      "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
    end

    private

    attr_reader :api_key, :clock

    def request_body(prompt:, reference_url:)
      {
        model: row.model.presence || "gpt-5",
        tools: [{ type: "image_generation" }],
        input: [{
          role: "user",
          content: [
            { type: "input_image", image_url: data_uri_for(reference_url) },
            { type: "input_text", text: prompt }
          ]
        }]
      }
    end

    # EVERY image_generation_call's base64 result, decoded into a data URI.
    #
    # THE OUTPUT ARRAY CARRIES MORE THAN IMAGES — reasoning items and message
    # items sit alongside — so this selects by `type` rather than taking the last
    # element. A positional read would break the day the vendor appends anything.
    def extract_images(payload)
      Array(payload["output"]).filter_map do |item|
        next unless item.is_a?(Hash) && item["type"] == IMAGE_CALL_TYPE

        b64 = item["result"].to_s
        next if b64.blank?

        "data:image/png;base64,#{b64}"
      end
    end

    # WHAT THE CALL COST, in the only unit this vendor reports on the response:
    # total tokens. It is NOT an image count and must not be read as one — a
    # single sheet is one image and many thousands of tokens.
    def total_tokens(payload)
      usage = payload["usage"]
      return nil unless usage.is_a?(Hash)

      @last_usage = usage
      usage["total_tokens"]
    end

    # OUR OWN S3 OBJECT, FETCHED AS BYTES.
    #
    # SIZE-CAPPED, because the bytes are about to be base64'd into a request body
    # and held in memory twice. A capped read that refuses is a clear error; an
    # uncapped one is a dyno falling over on a file nobody expected to be large.
    def fetch_reference(url)
      uri = URI.parse(url)
      raise GenerationError, "reference #{url.inspect} is not http(s)" unless uri.is_a?(URI::HTTP)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: REFERENCE_OPEN_TIMEOUT,
                                                     read_timeout: REFERENCE_READ_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise GenerationError, "reference #{url} answered HTTP #{response.code}"
      end

      body = response.body.to_s
      if body.bytesize > MAX_REFERENCE_BYTES
        raise GenerationError,
              "reference #{url} is #{body.bytesize} bytes, over the #{MAX_REFERENCE_BYTES} cap"
      end

      [body, response["content-type"].presence || "image/png"]
    end

    # THE ONE PLACE A SOCKET OPENS TO THE VENDOR, which is why the trap lives here
    # rather than on the public method: a future method that forgets to check is
    # still caught.
    def perform(body:)
      if self.class.armed?
        raise LiveCallAttempted, <<~WHY
          A live OpenAI image call was attempted with #{NO_LIVE_CALLS_ENV}=1 armed.
          Every paid call to this vendor goes through ImageGeneration::OpenAI#perform,
          and the suite arms this so no test can spend. Drive the recorded seam instead:

            client = ImageGeneration::OpenAI.new(row, api_key: "test")
            client.define_singleton_method(:perform) { |body:| { ... } }

          If you are NOT in a test, something set #{NO_LIVE_CALLS_ENV}=1 in your
          environment.
        WHY
      end

      uri = URI.parse(row.endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                     open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
      interpret(response)
    end

    # A NON-2XX RAISES WITH THE VENDOR'S OWN WORDS. An HTTP 401 that returned an
    # empty Result would be indistinguishable from a model that generated nothing,
    # and those two send an operator to completely different places.
    def interpret(response)
      parsed = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end
      return parsed if response.is_a?(Net::HTTPSuccess)

      detail = parsed.dig("error", "message") || response.body.to_s.truncate(200)
      raise GenerationError, "#{row.label} answered HTTP #{response.code}: #{detail}"
    end
  end
end
