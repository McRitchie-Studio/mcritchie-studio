require "net/http"
require "json"

module Higgsfield
  # HTTP client for Higgsfield media generation.
  #
  # REWRITTEN 2026-09-20 against the current API. The previous version targeted
  # `platform.higgsfield.ai` with `hf-api-key`/`hf-secret` headers, which is a
  # partly-decommissioned surface: it still AUTHENTICATES our key and still
  # serves `GET /v1/motions`, so a shallow probe looks healthy, but
  # `/v1/text2image/soul` answers `400 {"detail":"Unavailable model"}` and its
  # `1024x1792` size is no longer accepted. That is why the feature read as
  # "built but untested" for months rather than as broken.
  #
  # WHAT IS MEASURED AND WHAT IS NOT. Everything about the REQUEST side below
  # was measured against the live API on 2026-09-20 — host, auth header, paths,
  # and which fields are required (an empty POST returns a 422 naming them).
  # The RESPONSE side is NOT measured: the account has no credits, so every
  # well-formed request answers `not_enough_credits` and no successful payload
  # was ever seen. Response parsing is therefore written tolerantly and marked
  # UNVERIFIED. Confirm it against one real generation before trusting it.
  class Client
    # VERIFIED: the current host. `api.higgsfield.ai`, not `platform.`.
    BASE_URL = "https://api.higgsfield.ai".freeze

    # VERIFIED: paths, and the fields each one requires.
    IMAGE_PATH = "/higgsfield-ai/soul/v2/standard".freeze          # requires: prompt
    VIDEO_PATH = "/kling-video/v2.5-turbo/pro/image-to-video".freeze # requires: prompt, image_url

    # The model is part of the PATH now, so selecting one means picking a path.
    # Named rather than free-form: the old client took `model: "dop-turbo"` as a
    # body field, and a rewrite that quietly ignored that value would turn a
    # working argument into a no-op the caller could not see.
    IMAGE_PATHS = {
      "soul-v2" => IMAGE_PATH,
      "soul"    => "/higgsfield-ai/soul/standard"
    }.freeze

    VIDEO_PATHS = {
      "kling-pro"      => VIDEO_PATH,
      "kling-standard" => "/kling-video/v2.5-turbo/standard/image-to-video",
      "hailuo"         => "/minimax/hailuo-2.3/standard/image-to-video"
    }.freeze
    STATUS_PATH = "/requests/%<id>s/status".freeze
    CANCEL_PATH = "/requests/%<id>s/cancel".freeze

    # CHARACTER IDENTITY — the "custom reference". Post a set of reference
    # photos once, get a UUID, then every generation that names that UUID renders
    # the SAME face instead of re-inventing the person each call.
    #
    # MEASURED 2026-09-24 against the live API with the production credential,
    # request AND response — unlike the generation endpoints above, this one has
    # been driven to a 200 and its payload is pinned from the real answer:
    #
    #   POST /v1/custom-references
    #     {"name": "...", "input_images": [{"type":"image_url","image_url":"https://..."}]}
    #   -> 200 {"id":"1af15765-…","model_version":"v1","name":"…",
    #           "status":"not_ready","thumbnail_url":null,
    #           "created_at":"…","in_progress_at":null,"fail_reason":null}
    #
    # THE PUBLISHED SPEC DOES NOT LIST THIS PATH. docs.higgsfield.ai's
    # openapi.json carries 8 paths and `/v1/custom-references` is not among them.
    # The spec is incomplete; the endpoint is live. Do not delete this on the
    # strength of the spec's silence — probe it.
    CUSTOM_REFERENCE_PATH = "/v1/custom-references".freeze
    CUSTOM_REFERENCE_READ_PATH = "/v1/custom-references/%<id>s".freeze

    # The item wrapper is not decoration. A bare URL string answers 422
    # `model_attributes_type`; an item missing `type` answers 422 `missing`; and
    # `type` is a single-member literal — a wrong value answers
    # `Input should be <InputImageType.IMAGE_URL: 'image_url'>`. All three
    # measured 2026-09-24.
    CUSTOM_REFERENCE_IMAGE_TYPE = "image_url".freeze

    # `input_images` has min_length 1 — `[]` answers 422 `too_short`.
    CUSTOM_REFERENCE_MIN_IMAGES = 1

    # HOW HARD THE IDENTITY PULLS, and it is a FLOAT in 0..1, not a level.
    # Measured 2026-09-24: 99 answers `less_than_equal` (ctx le 1.0), -5 answers
    # `greater_than_equal` (ctx ge 0.0), and "banana" answers `float_parsing`.
    # Worth pinning because "strength" invites an integer, and an integer above
    # 1 is a paid round-trip to a 422.
    CUSTOM_REFERENCE_STRENGTH_RANGE = (0.0..1.0).freeze

    # The id Higgsfield mints is a UUID, and the generation endpoint VALIDATES it
    # as one (a non-uuid answers 422 `uuid_parsing`, which is how we know the
    # field is wired rather than silently ignored). Checking the shape here turns
    # a paid 422 into a free local raise.
    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # 9:16 for TikTok and Reels. 1152x2048 is the exact 9:16 member of the size
    # set the API named when it rejected the old 1024x1792 — note that rejection
    # came from the LEGACY endpoint's validator, so treat this as the best known
    # value rather than a confirmed one for the path above.
    VERTICAL_9_16 = "1152x2048".freeze

    POLL_INTERVAL = 3
    MAX_POLL_TIME = 300

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    class Error < StandardError; end
    class GenerationError < Error; end
    class TimeoutError < Error; end

    # Raised on its own so a caller can tell "the integration is broken" apart
    # from "the account needs topping up" — the state this rewrite was done in,
    # and the one most likely to recur.
    class InsufficientCreditsError < Error; end

    TERMINAL_STATUSES = %w[completed succeeded failed error cancelled canceled nsfw].freeze
    FAILED_STATUSES   = %w[failed error cancelled canceled nsfw].freeze

    def initialize(api_key: nil, api_secret: nil)
      @api_key = api_key || ENV["HIGGSFIELD_API_KEY"]
      @api_secret = api_secret || ENV["HIGGSFIELD_API_SECRET"]
      raise GenerationError, "HIGGSFIELD_API_KEY not set" if @api_key.blank?
      raise GenerationError, "HIGGSFIELD_API_SECRET not set" if @api_secret.blank?
    end

    def generate_image(prompt:, width_and_height: VERTICAL_9_16, quality: nil, enhance_prompt: nil,
                       custom_reference_id: nil, custom_reference_strength: nil)
      body = { prompt: prompt }
      body[:width_and_height] = width_and_height if width_and_height.present?
      body[:quality] = quality if quality.present?
      body[:enhance_prompt] = enhance_prompt unless enhance_prompt.nil?
      body.merge!(custom_reference_body(custom_reference_id, custom_reference_strength))

      post(IMAGE_PATH, body)
    end

    # CREATE A CHARACTER IDENTITY from a set of reference photos. Returns the
    # UUID, which is the only part of the answer a caller needs to keep — pass it
    # back to #generate_image as `custom_reference_id`.
    #
    # THE IDENTITY IS NOT USABLE THE MOMENT THIS RETURNS. The response's
    # `status` is `not_ready`, and a read of #custom_reference walks it
    # `queued` → `in_progress` (measured 2026-09-24). Pin a generation to a
    # reference that is still training and you have paid for a face we did not
    # wait for. The caller owns that wait; this method owns the create.
    #
    # EVERY IMAGE URL MUST BE PUBLICLY FETCHABLE BY HIGGSFIELD, not merely by us.
    # They pull the bytes server-side and re-host them on their own CDN — a read
    # of the created reference comes back with a `reference_media` array of
    # `d3snorpfx4xhv8.cloudfront.net` URLs, which is the proof the fetch
    # succeeded. A signed or private URL does not survive that hop.
    def create_custom_reference(name:, image_urls:)
      urls = Array(image_urls).map { |url| url.to_s.strip }.reject(&:empty?)
      if urls.length < CUSTOM_REFERENCE_MIN_IMAGES
        raise ArgumentError,
              "a custom reference needs at least #{CUSTOM_REFERENCE_MIN_IMAGES} image URL " \
              "(the API answers 422 too_short on an empty list); got #{urls.length}"
      end

      response = post(CUSTOM_REFERENCE_PATH, {
        name: name.to_s,
        input_images: urls.map { |url| { type: CUSTOM_REFERENCE_IMAGE_TYPE, image_url: url } }
      })

      custom_reference_id_from(response)
    end

    # READ ONE CHARACTER IDENTITY — the only read there is. `GET
    # /v1/custom-references` (the collection) answers 405 Method Not Allowed, so
    # there is no way to list what we have created: the id we store IS the
    # record. Measured 2026-09-24, along with this path's 200.
    #
    # The payload carries `status`, `fail_reason`, `thumbnail_url` and
    # `reference_media`.
    def custom_reference(custom_reference_id)
      get(format(CUSTOM_REFERENCE_READ_PATH, id: custom_reference_id))
    end

    def generate_video(image_url:, prompt:, model: nil, duration: nil)
      body = { prompt: prompt, image_url: image_url }
      body[:duration] = duration if duration.present?

      post(video_path_for(model), body)
    end

    # A nil model takes the default. A KNOWN name selects its path. Anything
    # else — including the old client's `dop-turbo`, which used to be a
    # functional body field — RAISES, because silently ignoring it would
    # convert a working argument into a no-op that reads like a switch.
    def video_path_for(model)
      return VIDEO_PATH if model.nil?

      VIDEO_PATHS.fetch(model.to_s) do
        raise ArgumentError,
              "unknown Higgsfield video model #{model.inspect} — " \
              "the model is part of the path now; use one of #{VIDEO_PATHS.keys.join(', ')} or nil"
      end
    end

    def status(request_id)
      get(format(STATUS_PATH, id: request_id))
    end

    def cancel(request_id)
      post(format(CANCEL_PATH, id: request_id), {})
    end

    def generate_image_and_wait(prompt:, width_and_height: VERTICAL_9_16, quality: nil, enhance_prompt: nil,
                                custom_reference_id: nil, custom_reference_strength: nil)
      response = generate_image(prompt: prompt, width_and_height: width_and_height,
                                quality: quality, enhance_prompt: enhance_prompt,
                                custom_reference_id: custom_reference_id,
                                custom_reference_strength: custom_reference_strength)
      await_result(request_id_from(response))
    end

    def generate_video_and_wait(image_url:, prompt:, model: nil, duration: nil)
      response = generate_video(image_url: image_url, prompt: prompt, model: model, duration: duration)
      await_result(request_id_from(response))
    end

    # Submit + poll, returning the finished asset's URL.
    def await_result(request_id, clock: Time)
      started_at = clock.now

      loop do
        payload = status(request_id)
        state = extract_status(payload)

        if FAILED_STATUSES.include?(state)
          raise GenerationError, "Higgsfield request #{request_id} ended #{state}: #{payload['error'] || payload['detail']}"
        end

        return extract_url(payload) if TERMINAL_STATUSES.include?(state)

        if clock.now - started_at > MAX_POLL_TIME
          raise TimeoutError, "Higgsfield request #{request_id} timed out after #{MAX_POLL_TIME}s"
        end

        sleep POLL_INTERVAL
      end
    end

    private

    # THE TWO CHARACTER-IDENTITY FIELDS, OR NOTHING AT ALL. Absent keys are not
    # the same as null keys: a body carrying `"custom_reference_id": null` asks
    # the validator a question it did not have to answer, so an unpinned
    # generation sends neither key.
    #
    # `nil?` rather than `present?` on the strength because 0.0 is a LEGAL value
    # with a meaning — pull the identity in as weakly as the API allows — and
    # Ruby's falsiness is not involved: `0.0.present?` is true, so `present?`
    # would happen to work here and would break the day this reads a plain
    # `false`-ish sentinel. Say what is meant.
    #
    # A STRENGTH WITHOUT AN ID IS REFUSED rather than dropped, on the same rule
    # #video_path_for follows: silently ignoring an argument converts a working
    # knob into a no-op the caller cannot see. The API would ignore it too, which
    # is precisely why we must not.
    def custom_reference_body(custom_reference_id, custom_reference_strength)
      if custom_reference_id.blank?
        unless custom_reference_strength.nil?
          raise ArgumentError,
                "custom_reference_strength #{custom_reference_strength.inspect} was given with no " \
                "custom_reference_id — the strength scales an identity, so with nothing to scale it " \
                "does nothing; pass both or neither"
        end

        return {}
      end

      id = custom_reference_id.to_s
      unless id.match?(UUID_FORMAT)
        raise ArgumentError,
              "custom_reference_id #{id.inspect} is not a UUID — the API validates it as one " \
              "(422 uuid_parsing), so this would be a paid round-trip to a rejection"
      end

      body = { custom_reference_id: id }
      body[:custom_reference_strength] = coerce_strength(custom_reference_strength) unless custom_reference_strength.nil?
      body
    end

    # THE CONVERSION AND THE RANGE CHECK ARE SEPARATE STATEMENTS on purpose. A
    # single `rescue ArgumentError` around both would swallow the range raise —
    # it is an ArgumentError too — and report an out-of-range number as
    # unparseable, which names the wrong defect to whoever reads the message.
    def coerce_strength(value)
      strength =
        begin
          Float(value)
        rescue TypeError, ArgumentError
          raise ArgumentError,
                "custom_reference_strength must be a number (the API answers 422 float_parsing " \
                "otherwise); got #{value.inspect}"
        end

      unless CUSTOM_REFERENCE_STRENGTH_RANGE.cover?(strength)
        raise ArgumentError,
              "custom_reference_strength must fall in #{CUSTOM_REFERENCE_STRENGTH_RANGE} — " \
              "the API answers 422 (le 1.0 / ge 0.0) outside it; got #{value.inspect}"
      end

      strength
    end

    # VERIFIED against a real 200 on 2026-09-24: the create answers `{"id":
    # "<uuid>", …}`. Pinned to the one key rather than walked tolerantly like the
    # generation reads below, because this shape was MEASURED and guessing extra
    # spellings would pretend otherwise.
    #
    # The UUID check is not belt-and-braces. The id's whole job is to be handed
    # back to a generation that validates it as a UUID, so an id we cannot use is
    # a failure at the create, not three steps later inside a paid call.
    def custom_reference_id_from(response)
      id = response["id"]
      if id.blank?
        raise GenerationError,
              "no id in custom-reference response: #{response.inspect[0, 300]}"
      end

      unless id.to_s.match?(UUID_FORMAT)
        raise GenerationError,
              "custom-reference id #{id.inspect} is not a UUID, and only a UUID is accepted " \
              "by the generation endpoint: #{response.inspect[0, 300]}"
      end

      id.to_s
    end

    # UNVERIFIED, and given the SAME loud treatment as `extract_url` — the two
    # reads used to be asymmetric and it mattered. `payload["status"]` alone
    # meant a state under any other key (`{"state":"completed"}`) parsed as "",
    # matched neither terminal nor failed, and polled the full 300s before
    # raising TimeoutError naming no payload. A FINISHED asset then reported as
    # a timeout and the true shape was never printed — the exact opposite of why
    # the response side is marked unverified.
    def extract_status(payload)
      raw = payload["status"] || payload["state"] || payload.dig("data", "status")
      if raw.nil?
        raise GenerationError,
              "no recognisable status key in poll payload: #{payload.inspect[0, 300]}"
      end

      raw.to_s.downcase
    end

    # UNVERIFIED — no successful submit was ever observed. The docs call it a
    # request id; accept the plausible spellings rather than pin one.
    def request_id_from(response)
      id = response["id"] || response["request_id"] || response.dig("data", "id")
      raise GenerationError, "no request id in response: #{response.inspect[0, 200]}" if id.blank?

      id
    end

    # UNVERIFIED — same reason. Walks the shapes the API is likely to use for a
    # finished asset and fails loudly, with the payload, when none matches, so
    # the first real generation reports the true shape instead of a nil URL.
    def extract_url(payload)
      candidates = [
        payload.dig("results", "raw", "url"),
        payload.dig("results", "min", "url"),
        payload.dig("result", "url"),
        payload["url"],
        payload["output_url"],
        Array(payload["outputs"]).first.is_a?(Hash) ? Array(payload["outputs"]).first["url"] : Array(payload["outputs"]).first,
        Array(payload["results"]).first.is_a?(Hash) ? Array(payload["results"]).first["url"] : nil
      ]

      url = candidates.compact.find(&:present?)
      raise GenerationError, "no asset URL in completed payload: #{payload.inspect[0, 300]}" if url.blank?

      url
    end

    # VERIFIED: `Authorization: Key <id>:<secret>`.
    def headers
      {
        "Authorization" => "Key #{@api_key}:#{@api_secret}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def post(path, body)
      perform(Net::HTTP::Post, path) { |req| req.body = body.to_json }
    end

    def get(path)
      perform(Net::HTTP::Get, path)
    end

    def perform(verb, path)
      uri = URI("#{BASE_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = verb.new(uri.request_uri, headers)
      yield request if block_given?

      interpret(http.request(request), path)
    end

    def interpret(response, path)
      body = parse_body(response)

      return body if response.is_a?(Net::HTTPSuccess)

      detail = body.is_a?(Hash) ? body["detail"] : nil
      if detail.to_s.tr("_", " ").casecmp?("not enough credits")
        raise InsufficientCreditsError,
              "Higgsfield has no credits — top up the account; no code change reaches past this"
      end

      raise GenerationError, "Higgsfield API error on #{path}: #{response.code} — #{response.body.to_s[0, 300]}"
    end

    def parse_body(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      {}
    end
  end
end
