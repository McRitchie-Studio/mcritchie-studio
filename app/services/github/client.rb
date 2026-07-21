require "json"
require "net/http"
require "uri"

module Github
  class Client
    class HttpError < StandardError; end
    class RateLimitError < HttpError; end

    DEFAULT_BASE_URL = "https://api.github.com".freeze
    TRANSIENT_STATUSES = [500, 502, 503, 504].freeze
    RATE_LIMIT_HEADER_NAMES = %w[
      retry-after
      x-github-request-id
      x-ratelimit-limit
      x-ratelimit-remaining
      x-ratelimit-reset
      x-ratelimit-resource
      x-ratelimit-used
    ].freeze
    INSPECTABLE_HEADER_NAMES = (RATE_LIMIT_HEADER_NAMES + %w[
      content-type
      etag
      last-modified
      link
    ]).freeze

    Response = Struct.new(:url, :status, :headers, :body, :raw_body, keyword_init: true) do
      def success?
        status.to_i.between?(200, 299)
      end

      def to_h
        {
          url: url,
          status: status,
          headers: headers,
          body: body,
          raw_body: raw_body
        }
      end
    end

    attr_reader :request_count

    def initialize(token: ENV["GITHUB_TOKEN"], base_url: DEFAULT_BASE_URL, logger: Rails.logger,
      executor: nil, sleeper: ->(seconds) { sleep(seconds) }, max_retries: 2,
      request_pause_seconds: ENV.fetch("GITHUB_REQUEST_PAUSE_SECONDS", 0).to_f,
      rate_limit_pause_seconds: ENV.fetch("GITHUB_RATE_LIMIT_PAUSE_SECONDS", 60).to_f,
      rate_limit_retries: ENV.fetch("GITHUB_RATE_LIMIT_RETRIES", 1).to_i)
      @token = token.to_s.strip.presence
      @base_url = base_url
      @logger = logger
      @executor = executor
      @sleeper = sleeper
      @max_retries = max_retries
      @request_pause_seconds = request_pause_seconds.to_f
      @rate_limit_pause_seconds = rate_limit_pause_seconds.to_f
      @rate_limit_retries = [rate_limit_retries.to_i, 0].max
      @request_count = 0
    end

    def get(path, params: {}, headers: {})
      response = request(path, params: params, headers: headers)
      parse_json(response.body)
    end

    # A JSON POST, sharing the same retry / rate-limit / error machinery as GET.
    # +body+ is JSON-encoded (a Hash) or sent verbatim (a String).
    def post(path, body: nil, params: {}, headers: {})
      response = request(path, params: params, headers: headers, method: :post, body: body)
      parse_json(response.body)
    end

    def get_response(path, params: {}, headers: {})
      response = request(path, params: params, headers: headers)
      Response.new(
        url: build_uri(path, params).to_s,
        status: response.code.to_i,
        headers: inspectable_headers(response),
        body: parse_json(response.body),
        raw_body: response.body
      )
    end

    def paginate(path, params: {}, headers: {})
      records = []
      next_path = path
      next_params = params.merge(per_page: params[:per_page] || params["per_page"] || 100)

      loop do
        response = request(next_path, params: next_params, headers: headers)
        body = parse_json(response.body)
        page_records = body.is_a?(Hash) && body.key?("items") ? body.fetch("items") : body
        records.concat(Array(page_records))

        next_path = next_link(response)
        break unless next_path

        next_params = {}
      end

      records
    end

    private

    def request(path, params:, headers:, method: :get, body: nil)
      uri = build_uri(path, params)
      req = build_request(uri, method, headers, body)

      attempts = 0
      rate_limit_attempts = 0
      loop do
        begin
          @request_count += 1
          response = execute(uri, req)
          log_response(uri, response)

          if (rate_limit_message = rate_limit_error_message(response))
            log_rate_limit_response(uri, response, rate_limit_message)

            if rate_limit_attempts < @rate_limit_retries && @rate_limit_pause_seconds.positive?
              rate_limit_attempts += 1
              @logger&.warn(
                "GitHub API rate limited request=#{@request_count} " \
                "retry=#{rate_limit_attempts}/#{@rate_limit_retries} " \
                "sleep=#{@rate_limit_pause_seconds}s path=#{uri.path}"
              )
              @sleeper.call(@rate_limit_pause_seconds)
              next
            end

            raise RateLimitError, rate_limit_message
          end

          status = response.code.to_i
          if TRANSIENT_STATUSES.include?(status) && attempts < @max_retries
            attempts += 1
            @sleeper.call(2**(attempts - 1))
            next
          end

          unless status.between?(200, 299)
            raise HttpError, "GitHub API HTTP #{status}: #{response.body}"
          end

          pause_after_request
          return response
        rescue HttpError
          raise
        rescue StandardError => e
          if attempts < @max_retries
            attempts += 1
            @sleeper.call(2**(attempts - 1))
            next
          end

          raise HttpError, "GitHub API request failed: #{e.class}: #{e.message}"
        end
      end
    end

    # Build the Net::HTTP request for the verb, applying default + caller headers.
    # A POST body is JSON-encoded (Hash) or passed through (String) with the
    # matching Content-Type.
    def build_request(uri, method, headers, body)
      req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      default_headers.merge(headers).each { |key, value| req[key] = value }
      if body
        req["Content-Type"] = "application/json"
        req.body = body.is_a?(String) ? body : body.to_json
      end
      req
    end

    def execute(uri, request)
      if @executor
        @executor.call(uri, request)
      else
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 30) do |http|
          http.request(request)
        end
      end
    end

    def build_uri(path, params)
      uri = path.to_s.start_with?("http") ? URI(path) : URI.join(@base_url, path)
      query_parts = []
      query_parts << uri.query if uri.query.present?
      query_parts << URI.encode_www_form(params) if params.present?
      uri.query = query_parts.join("&") if query_parts.any?
      uri
    end

    def default_headers
      headers = {
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "McRitchie-Studio-AI-Builder-Multiple",
        "X-GitHub-Api-Version" => "2022-11-28"
      }
      headers["Authorization"] = "Bearer #{@token}" if @token
      headers
    end

    def parse_json(body)
      return {} if body.blank?

      JSON.parse(body)
    end

    def next_link(response)
      link_header = response["link"]
      return nil if link_header.blank?

      link_header.split(",").each do |part|
        url, rel = part.split(";").map(&:strip)
        return url.delete_prefix("<").delete_suffix(">") if rel == 'rel="next"'
      end

      nil
    end

    def rate_limit_error_message(response)
      remaining = response["x-ratelimit-remaining"]
      status = response.code.to_i
      message = parsed_body_message(response.body)

      if status == 403 && remaining.present? && remaining.to_i.zero?
        reset = response["x-ratelimit-reset"].to_i
        reset_at = reset.positive? ? Time.at(reset).utc.iso8601 : "unknown"
        return "GitHub API rate limit exhausted; resets at #{reset_at}"
      end

      if status == 403 && secondary_rate_limit_message?(message)
        return "GitHub API secondary rate limit: #{message}"
      end

      return "GitHub API rate limited: #{message.presence || response.body}" if status == 429

      nil
    end

    def secondary_rate_limit_message?(message)
      normalized = message.to_s.downcase
      normalized.include?("secondary rate limit") || normalized.include?("abuse detection")
    end

    def parsed_body_message(body)
      return "" if body.blank?

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed.fetch("message", "").to_s : ""
    rescue JSON::ParserError
      ""
    end

    def log_rate_limit_response(uri, response, message)
      @logger&.warn(
        "GitHub API rate limit response request=#{@request_count} " \
        "status=#{response.code} path=#{uri.path} " \
        "headers=#{safe_rate_limit_headers(response).to_json} " \
        "message=#{message} body=#{response.body}"
      )
    end

    def safe_rate_limit_headers(response)
      RATE_LIMIT_HEADER_NAMES.to_h do |header_name|
        [header_name, response[header_name]]
      end.compact
    end

    def inspectable_headers(response)
      INSPECTABLE_HEADER_NAMES.to_h do |header_name|
        [header_name, response[header_name]]
      end.compact
    end

    def pause_after_request
      @sleeper.call(@request_pause_seconds) if @request_pause_seconds.positive?
    end

    def log_response(uri, response)
      @logger&.info(
        "GitHub API request=#{@request_count} status=#{response.code} " \
        "rate_remaining=#{response['x-ratelimit-remaining'] || 'unknown'} path=#{uri.path}"
      )
    end
  end
end
