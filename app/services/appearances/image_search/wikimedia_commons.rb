module Appearances
  module ImageSearch
    # WIKIMEDIA COMMONS — THE KEYLESS PROVIDER, and the one the operator can
    # actually exercise today.
    #
    # WHY THIS EXISTS WHEN THE FAÇADE'S HEADER ARGUES FOR ONE PROVIDER. That
    # argument was about an UNSEEN response shape: a second parser written against
    # a body nobody has observed doubles the guessed surface with no credential to
    # measure either half against. It held while both providers were unmeasured.
    # It does not hold here, for two reasons that invert it:
    #
    #   1. THIS SHAPE WAS MEASURED, not assumed. Every field read below was
    #      observed in a live 200 on 2026-09-26, and the fixture in
    #      test/services/appearances/image_search/wikimedia_commons_test.rb is a
    #      TRIMMED REAL BODY rather than an invention. Read that test's name
    #      against Serper's `assumed_serper_body` — the difference is the point.
    #   2. IT NEEDS NO CREDENTIAL, and Serper's does not exist. `SERPER_API_KEY`
    #      is absent from production and from every desk, so with Serper alone
    #      `ImageSearch.available?` is false everywhere and "the AI goes out and
    #      pulls images" cannot run at all. A keyless provider is the only one the
    #      operator can use without buying something first.
    #
    # ORDERED AFTER SERPER IN THE REGISTRY, deliberately. The façade serves the
    # first AVAILABLE provider, and this one answers `available?` unconditionally —
    # so listing it first would mean a paid Serper key, once bought, is never used.
    # Commons is the floor that is always there, not the preference.
    #
    # WHAT IT IS GOOD AT, AND WHAT IT IS NOT. Commons is a free-licence media
    # archive with a CirrusSearch index, not an image search engine. Measured on
    # "Drew Lock", 2026-09-26: 20 results, of which 12 were scanned documents
    # (10 PDF, 2 DjVu) and one was an 1896 edition of *The Rape of the Lock*. The
    # name collides with a common noun and the archive answers with books. That is
    # a REAL property of this source and the reason the calibration page shows every
    # raw candidate: the operator is being asked to judge the search, and a search
    # that returns twelve books is exactly the finding.
    #
    # ⚠ DO NOT "IMPROVE" THE QUERY WITH FACE WORDS. Appending "portrait",
    # "headshot" or "press conference" was measured against this very API on
    # 2026-09-26 and REFUTED in every form — the OR spelling returns twenty
    # portraits of strangers, and two spellings return nothing at all. The table is
    # in docs/topics/content-pipeline.md. Re-measure before re-trying it.
    class WikimediaCommons
      ENDPOINT = "https://commons.wikimedia.org/w/api.php".freeze

      # WIKIMEDIA'S USER-AGENT POLICY ASKS FOR A DESCRIPTIVE AGENT WITH A CONTACT.
      # A generic agent answers 200 today (measured 2026-09-26) and is throttled or
      # blocked at their discretion, which would turn into "the search found
      # nothing" on the operator's page. Identifying ourselves is both the courtesy
      # and the cheapest way not to be mistaken for a scraper.
      USER_AGENT = "McRitchieStudio/1.0 (https://mcritchie.studio; team@mcritchie.studio)".freeze

      # The API accepts a much larger `gsrlimit`; this is our ceiling, so a typo in
      # a caller cannot ask the archive for hundreds of rows we would never rank.
      MAX_RESULTS = 50

      # HOW WIDE A DISPLAY RENDITION TO ASK FOR.
      #
      # MEASURED 2026-09-26, and this number is the whole reason the gallery paints.
      # Commons originals for one query ran 1-3 MB each; fetching them in a row, the
      # third onward answered **HTTP 429** and a third of the tiles rendered as grey
      # alt-text. The same eight files at 600px answered 200 every time, at 18-460 KB.
      # 600 is roughly twice the rendered tile edge, so it stays sharp on a retina
      # screen without going back into the range that got us throttled.
      #
      # It NEVER replaces the original: `image_url` is what Higgsfield fetches and what
      # the tile links to. See the migration for why those are two columns.
      THUMB_WIDTH = 600

      # NAMESPACE 6 IS `File:`. Without it the generator searches article text and
      # returns pages, not media, and every row comes back with no `imageinfo` at
      # all — which this parser would correctly report as unreadable, for a reason
      # that had nothing to do with the response shape.
      FILE_NAMESPACE = 6

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      class Error < StandardError; end

      def self.provider_name = "wikimedia-commons"

      # NO CREDENTIAL, SO ALWAYS AVAILABLE — and this is the method the façade's
      # whole `available?`-on-the-provider design was built to accommodate. It takes
      # no argument and reads no ENV because there is nothing to read: an
      # unconditional `true` is the honest answer, not a placeholder.
      def self.available? = true

      def self.search(query:, limit: 20) = new.search(query: query, limit: limit)

      # RAISES rather than degrading, exactly as Serper does. The façade owns the
      # decision to swallow — it catches, files an ErrorLog against the look, and
      # returns an empty Answer — and a provider that degraded on its own would make
      # an outage read as "the archive has no photographs of this person", which is
      # the one distinction the operator is on this page to make.
      def search(query:, limit: 20)
        query = query.to_s.strip
        raise ArgumentError, "an image search needs a query" if query.empty?

        parse(get(query, limit.to_i.clamp(1, MAX_RESULTS)))
      end

      private

      def get(query, limit)
        uri = URI.parse(ENDPOINT)
        uri.query = URI.encode_www_form(
          action: "query",
          format: "json",
          # `generator=search` runs CirrusSearch and feeds the hits straight into
          # `prop=imageinfo`, so one request answers both "what matched" and "where
          # is the file" — two round trips would be two chances to half-fail.
          generator: "search",
          gsrsearch: query,
          gsrnamespace: FILE_NAMESPACE,
          gsrlimit: limit,
          prop: "imageinfo",
          # `url` carries the file and its description page; `size` carries the
          # real pixel dimensions, which PhotoMerit's shape signals need; `mime`
          # is the free, deterministic "this is a PDF, not a photograph" tell.
          iiprop: "url|size|mime",
          # ASKS FOR A SMALL RENDITION ALONGSIDE THE ORIGINAL. Costs nothing extra —
          # same request — and is what keeps a twenty-tile gallery under the archive's
          # rate limiter. See THUMB_WIDTH.
          iiurlwidth: THUMB_WIDTH
        )

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "application/json"

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                       open_timeout: OPEN_TIMEOUT,
                                                       read_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "commons.wikimedia.org answered #{response.code}: #{response.body.to_s[0, 200]}"
        end

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise Error, "commons.wikimedia.org returned a body we could not parse: #{e.message}"
      end

      # THE TWO SHAPES THIS HAS TO TELL APART, and getting them backwards is the
      # bug this method is written to avoid.
      #
      #   {"batchcomplete":""}                  ZERO HITS. Measured: this is the
      #                                         entire body for a query that matches
      #                                         nothing ("Drew Lock headshot",
      #                                         2026-09-26). There is no `query` key
      #                                         at all.
      #   {"query":{"pages":{"<pageid>":{…}}}}  HITS.
      #
      # An absent `query` key is therefore an EMPTY ANSWER WITH ZERO UNPARSED, not a
      # parse failure. Counting it as unparsed would make every genuinely empty
      # search look like a parser that had stopped working, and the `unparsed_count`
      # on Answer exists precisely so that alarm means something.
      def parse(payload)
        pages = payload.is_a?(Hash) ? payload.dig("query", "pages") : nil
        return Answer.new(results: [], unparsed_count: 0,
                          provider_name: self.class.provider_name) unless pages.is_a?(Hash)

        # `pages` IS A HASH KEYED BY PAGEID AND ITS ORDER IS NOT THE SEARCH ORDER.
        # Measured 2026-09-26: the keys came back 112977876, 92147282, 97896363 …
        # for hits whose `index` values were 1, 2, 3 …, so iterating the hash
        # renders the archive's ranking scrambled. The calibration page's whole
        # first question is "what did the search return, IN THE ORDER IT RETURNED
        # IT", so the rank has to come from `index` and never from enumeration.
        rows = pages.values.sort_by { |page| page_index(page) }
        unparsed = 0

        results = rows.filter_map do |page|
          result = build_result(page)
          unparsed += 1 if result.nil?
          result
        end

        if results.empty? && unparsed.positive?
          Rails.logger.warn(
            "[Appearances::ImageSearch::WikimediaCommons] parsed 0 of #{rows.length} results — " \
            "the response shape has moved; capture a live body and fix the parser"
          )
        end

        Answer.new(results: results, unparsed_count: unparsed,
                   provider_name: self.class.provider_name)
      end

      # A ROW WITH NO `index` SORTS LAST rather than first. `to_i` on nil is 0,
      # which would promote an unranked row above hit 1 — the opposite of what an
      # absent rank means.
      def page_index(page)
        value = page.is_a?(Hash) ? page["index"] : nil
        value.is_a?(Integer) ? value : Float::INFINITY
      end

      def build_result(page)
        return nil unless page.is_a?(Hash)

        info = Array(page["imageinfo"]).first
        return nil unless info.is_a?(Hash)

        image_url = clean_url(info["url"])
        return nil if image_url.blank?

        Result.new(
          image_url: image_url,
          page_url: clean_url(info["descriptionurl"]),
          title: display_title(page["title"]),
          # THE ORIGINAL FILE'S DIMENSIONS, matching the URL above. `thumburl` and
          # `thumbwidth` describe a DIFFERENT image, so mixing the two would print a
          # caption that does not describe the photograph the tile links to — and
          # would feed PhotoMerit's aspect-ratio signals the wrong shape.
          width: integer_or_nil(info["width"]),
          height: integer_or_nil(info["height"]),
          position: integer_or_nil(page["index"]),
          mime: info["mime"].presence,
          # nil WHEN THE ARCHIVE DECLINED TO MAKE ONE, which happens for formats it
          # cannot rasterise. The reader falls back to the original rather than
          # rendering a broken tile.
          thumb_url: clean_url(info["thumburl"])
        )
      end

      # `utm_*` PARAMS COME BACK ON EVERY URL and they are decoration, not address.
      # Measured 2026-09-26: `url` arrives as
      # `…/Drew_Lock.JPG?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original`.
      # Two reasons to drop them. `image_url` is half of this table's unique index,
      # so a campaign tag that ever changes would file the same photograph twice and
      # let it occupy two slots in one identity. And the URL is handed to Higgsfield
      # to fetch, where a tracking tag is noise on a request we want to be boring.
      #
      # ONLY `utm_*` IS DROPPED, never the whole query string. Stripping wholesale
      # would be a guess about a URL shape this provider does not own.
      def clean_url(value)
        raw = value.to_s.strip
        return nil if raw.empty?

        uri = URI.parse(raw)
        return raw if uri.query.blank?

        kept = URI.decode_www_form(uri.query).reject { |key, _| key.to_s.start_with?("utm_") }
        uri.query = kept.empty? ? nil : URI.encode_www_form(kept)
        uri.to_s
      rescue URI::InvalidURIError, ArgumentError
        # The row is evidence of what the archive offered; an address we cannot
        # parse is not something to raise a whole batch over.
        raw
      end

      # `File:Drew Hutton.jpg` → `Drew Hutton.jpg`.
      #
      # THE NAMESPACE PREFIX IS OURS TO REMOVE and the EXTENSION IS NOT. The
      # operator reads this title to catch the one failure no score can — a clear
      # photograph of the WRONG PERSON — so the human-readable name is what matters
      # and `File:` is plumbing. The extension stays: it is how the documented
      # measurements name these files ("Drew Hutton.jpg"), and PhotoMerit's document
      # markers read `.pdf` and `.djvu` out of exactly this string.
      def display_title(value)
        title = value.to_s.strip
        return nil if title.empty?

        title.delete_prefix("File:")
      end

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
