require "net/http"
require "json"

module Appearances
  module ImageSearch
    # GOOGLE IMAGES OVER PLAIN REST, via serper.dev.
    #
    # ⚠ THE RESPONSE SHAPE BELOW IS UNVERIFIED, and this is the first thing to
    # know about this file. No credential for serper.dev exists — not in
    # 1Password, not in Heroku config — so NOTHING here has been driven against
    # the live API. Compare that with Higgsfield::Client, whose character-identity
    # endpoints carry a payload pinned from an observed 200; this file carries a
    # payload pinned from public write-ups.  `docs.serper.dev` did not resolve
    # when this was written and the playground page served only a cookie banner.
    #
    # THE REQUEST, as the public sources agree on it:
    #
    #   POST https://google.serper.dev/images
    #     X-API-KEY: <key>
    #     Content-Type: application/json
    #     {"q": "Drew Lock Seattle Seahawks", "num": 20}
    #
    #   -> 200 {"images": [{"imageUrl": "https://...", "source": "espn.com", ...}]}
    #
    # `imageUrl` is the ONLY field this parser requires. Everything else — title,
    # link, thumbnail, width, height — is read if present and shrugged off if
    # absent, because a field list nobody has seen is a field list that will be
    # wrong somewhere, and a missing `width` must not throw away an otherwise good
    # photograph.
    #
    # WHAT TO DO WHEN THE KEY LANDS, in order: probe ONCE with one query, capture
    # the real body, and replace the fixture in
    # test/services/appearances/image_search/serper_test.rb with it. The parser
    # test is green against the GUESS until someone does that, and a green test
    # over a guessed fixture proves only that the guess is self-consistent. That
    # test's own name says `assumed_fixture` so nobody mistakes it for measurement.
    class Serper
      ENDPOINT = "https://google.serper.dev/images".freeze

      # THE CREDENTIAL, and the exact name to put in 1Password and in Heroku
      # config. `SERPER_API_KEY` matches the house pattern beside it —
      # HIGGSFIELD_API_KEY, HIGGSFIELD_API_SECRET — read straight from ENV with no
      # Rails.credentials indirection, because that is what every other vendor
      # client in this app does and a second convention is a second place to look.
      API_KEY_ENV = "SERPER_API_KEY".freeze

      # serper.dev's own documented cap per request is 100. Twenty is what the
      # caller asks for; this is the ceiling that stops a typo in a caller from
      # buying a hundred results.
      MAX_RESULTS = 100

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      class Error < StandardError; end

      # THE PROVIDER'S STABLE NAME, stored on every photograph it finds so a row
      # can be traced to what produced it after a provider swap.
      #
      # NOT `self.name`. Overriding `Class#name` is how a class starts lying to
      # every reflective reader it has — backtraces, `inspect`, anything doing a
      # constantize round-trip — and the protocol gains nothing from the shorter
      # spelling.
      def self.provider_name = "serper"

      # IS THERE A KEY? That is the whole question, and it is asked OF THE PROVIDER
      # rather than of the façade, so a provider needing no credential can answer
      # `true` without the layer above it being rewritten.
      #
      # PRESENCE, NOT VALIDITY. A key that is present but wrong is a 403 at search
      # time, caught by the façade and logged; a key that is absent is a clean
      # degrade to the headshot floor with an honest note on the page. Conflating
      # them would mean a live round-trip just to render the page — a paid request
      # on every page view, to answer a question the page does not need answered.
      def self.available? = api_key.present?

      def self.api_key = ENV[API_KEY_ENV].presence

      def self.search(query:, limit: 20)
        new.search(query: query, limit: limit)
      end

      def initialize(api_key: nil)
        @api_key = api_key || self.class.api_key
      end

      # ONE QUERY, ONE HTTP CALL, ONE ANSWER.
      #
      # RAISES rather than swallowing, on purpose. The façade owns the decision to
      # degrade — it catches, logs and returns an empty answer — and a provider
      # that also swallowed would make an outage indistinguishable from a search
      # that found nothing, which is exactly the distinction the operator is
      # looking at this page to make.
      def search(query:, limit: 20)
        raise Error, "#{API_KEY_ENV} not set" if @api_key.blank?

        query = query.to_s.strip
        raise ArgumentError, "an image search needs a query" if query.empty?

        parse(post(q: query, num: limit.to_i.clamp(1, MAX_RESULTS)))
      end

      private

      def post(body)
        uri = URI.parse(ENDPOINT)
        request = Net::HTTP::Post.new(uri)
        request["X-API-KEY"] = @api_key
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                       open_timeout: OPEN_TIMEOUT,
                                                       read_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "serper.dev answered #{response.code}: #{response.body.to_s[0, 200]}"
        end

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise Error, "serper.dev returned a body we could not parse: #{e.message}"
      end

      # READ WHAT WE RECOGNISE; COUNT WHAT WE DO NOT.
      #
      # A result missing `imageUrl` is SKIPPED AND COUNTED, never raised on. The
      # shape is a guess, so the likeliest failure is not "the API is down" but
      # "one of these fields is called something else" — and a raise there loses
      # every good result in the batch to one odd one.
      #
      # THE COUNT IS WHAT STOPS THE SKIP BEING SILENT, which is why it rides home
      # on the Answer rather than sitting in a reader on a discarded instance: a
      # query that returns twenty rows and parses zero is a PARSER BUG, and a bare
      # empty list reports that as "found nothing".
      def parse(payload)
        rows = payload.is_a?(Hash) ? Array(payload["images"]) : []
        unparsed = 0

        results = rows.each_with_index.filter_map do |row, index|
          result = build_result(row, index)
          unparsed += 1 if result.nil?
          result
        end

        if results.empty? && unparsed.positive?
          Rails.logger.warn(
            "[Appearances::ImageSearch::Serper] parsed 0 of #{rows.length} results — the response " \
            "shape has moved or was never right; capture a live body and fix the parser"
          )
        end

        Answer.new(results: results, unparsed_count: unparsed,
                   provider_name: self.class.provider_name)
      end

      def build_result(row, index)
        return nil unless row.is_a?(Hash)

        image_url = row["imageUrl"].presence
        return nil if image_url.blank?

        Result.new(
          image_url: image_url,
          # `link` is the page in the shapes that have been written up; `source`
          # is a bare domain in some of them. Preferring `link` and accepting
          # either keeps the gallery's "where did this come from" link working
          # wherever the field landed.
          page_url: row["link"].presence || row["source"].presence,
          title: row["title"].presence,
          width: integer_or_nil(row["imageWidth"] || row["width"]),
          height: integer_or_nil(row["imageHeight"] || row["height"]),
          # The provider's own rank. Read from the payload when it volunteers one
          # and otherwise taken from the array order, which is the rank whether or
          # not the field exists.
          position: integer_or_nil(row["position"]) || (index + 1)
        )
      end

      # A DIMENSION WE CANNOT TRUST IS NO DIMENSION. `to_i` would turn "large"
      # into 0, and a 0-pixel-wide photograph reads as a broken image rather than
      # as an unreported one.
      def integer_or_nil(value)
        return nil if value.nil?
        return value if value.is_a?(Integer)

        Integer(value.to_s, 10)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
