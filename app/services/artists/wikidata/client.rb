require "net/http"
require "json"

module Artists
  module Wikidata
    # Minimal SPARQL client for query.wikidata.org. One request at a time, a
    # pause between requests, and backoff on 429/5xx/timeouts, per the
    # endpoint's usage policy (descriptive User-Agent required).
    class Client
      ENDPOINT = URI("https://query.wikidata.org/sparql")
      USER_AGENT = "McRitchieStudioArtistSeed/1.0 (https://mcritchie.studio)".freeze
      RETRYABLE = [429, 500, 502, 503, 504].freeze

      class Error < StandardError; end

      def initialize(pause: 1.0, attempts: 5, logger: nil)
        @pause = pause
        @attempts = attempts
        @logger = logger
      end

      # Returns the result bindings (an array of hashes).
      def select(query)
        attempt = 0
        begin
          attempt += 1
          sleep(@pause) if @pause.positive?
          response = post(query)
          code = response.code.to_i
          return JSON.parse(response.body).dig("results", "bindings") if code == 200
          raise Error, "HTTP #{code}: #{response.body.to_s[0, 200]}" unless RETRYABLE.include?(code)

          wait = response["Retry-After"].to_i
          raise Error, "HTTP #{code} after #{attempt} attempts" if attempt >= @attempts

          backoff(attempt, wait, "HTTP #{code}")
          retry
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, JSON::ParserError => e
          raise Error, "#{e.class} after #{attempt} attempts" if attempt >= @attempts

          backoff(attempt, 0, e.class.name)
          retry
        end
      end

      private

      def post(query)
        Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, open_timeout: 15, read_timeout: 90) do |http|
          request = Net::HTTP::Post.new(ENDPOINT)
          request["User-Agent"] = USER_AGENT
          request["Accept"] = "application/sparql-results+json"
          request.set_form_data("query" => query)
          http.request(request)
        end
      end

      def backoff(attempt, retry_after, reason)
        wait = [retry_after, 5 * (2**(attempt - 1))].max
        @logger&.call("wikidata: #{reason}, retrying in #{wait}s")
        sleep(wait)
      end
    end
  end
end
