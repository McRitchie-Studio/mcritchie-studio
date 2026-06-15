require "json"
require "net/http"
require "uri"

module Github
  class Client
    class HttpError < StandardError; end
    class RateLimitError < HttpError; end

    DEFAULT_BASE_URL = "https://api.github.com".freeze
    TRANSIENT_STATUSES = [500, 502, 503, 504].freeze

    attr_reader :request_count

    def initialize(token: ENV["GITHUB_TOKEN"], base_url: DEFAULT_BASE_URL, logger: Rails.logger,
      executor: nil, sleeper: ->(seconds) { sleep(seconds) }, max_retries: 2)
      @token = token.to_s.strip.presence
      @base_url = base_url
      @logger = logger
      @executor = executor
      @sleeper = sleeper
      @max_retries = max_retries
      @request_count = 0
    end

    def get(path, params: {}, headers: {})
      response = request(path, params: params, headers: headers)
      parse_json(response.body)
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

    def request(path, params:, headers:)
      uri = build_uri(path, params)
      req = Net::HTTP::Get.new(uri)
      default_headers.merge(headers).each { |key, value| req[key] = value }

      attempts = 0
      loop do
        begin
          @request_count += 1
          response = execute(uri, req)
          log_response(uri, response)
          raise_rate_limit!(response)

          status = response.code.to_i
          if TRANSIENT_STATUSES.include?(status) && attempts < @max_retries
            attempts += 1
            @sleeper.call(2**(attempts - 1))
            next
          end

          unless status.between?(200, 299)
            raise HttpError, "GitHub API HTTP #{status}: #{response.body}"
          end

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

    def raise_rate_limit!(response)
      remaining = response["x-ratelimit-remaining"]
      return unless response.code.to_i == 403 && remaining.present? && remaining.to_i.zero?

      reset = response["x-ratelimit-reset"].to_i
      reset_at = reset.positive? ? Time.at(reset).utc.iso8601 : "unknown"
      raise RateLimitError, "GitHub API rate limit exhausted; resets at #{reset_at}"
    end

    def log_response(uri, response)
      @logger&.info(
        "GitHub API request=#{@request_count} status=#{response.code} " \
        "rate_remaining=#{response['x-ratelimit-remaining'] || 'unknown'} path=#{uri.path}"
      )
    end
  end
end
