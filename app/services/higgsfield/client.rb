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

    def generate_image(prompt:, width_and_height: VERTICAL_9_16, quality: nil, enhance_prompt: nil)
      body = { prompt: prompt }
      body[:width_and_height] = width_and_height if width_and_height.present?
      body[:quality] = quality if quality.present?
      body[:enhance_prompt] = enhance_prompt unless enhance_prompt.nil?

      post(IMAGE_PATH, body)
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

    def generate_image_and_wait(prompt:, width_and_height: VERTICAL_9_16, quality: nil, enhance_prompt: nil)
      response = generate_image(prompt: prompt, width_and_height: width_and_height,
                                quality: quality, enhance_prompt: enhance_prompt)
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
