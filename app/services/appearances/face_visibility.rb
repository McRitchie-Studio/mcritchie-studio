require "net/http"
require "json"

module Appearances
  # IS THIS PERSON'S FACE ACTUALLY VISIBLE? — a vision classifier over candidate
  # reference photographs.
  #
  # WHY THIS EXISTS RATHER THAN A METADATA HEURISTIC, and the measurement that
  # settled it. A character identity is built from faces; a helmet occludes
  # exactly the features it is built from. On the operator's own labelled example
  # (look `1943e690035b`, Drew Lock) the four photographs in the model were:
  #
  #   operator photo  936x1026  helmet
  #   hit 1           556x780   BARE FACE
  #   hit 2           686x930   helmet
  #   hit 3           3207x2135 helmet
  #
  # Aspect ratio separates hit 3 (1.50, landscape crowd shot) and nothing else:
  # the bare-faced hit 1 is 0.71 and the helmeted hit 2 is 0.74 — indistinguishable.
  # Their titles are "Drew Lock, 22 October 2023" and "Drew Lock, 18 December
  # 2023" — also indistinguishable. So NO metadata signal available to us can
  # order that pair correctly, and that pair IS the acceptance test. A cheap
  # ranker would have shipped green against a case it provably cannot solve.
  #
  # WHAT IT COSTS, and why it is not the first thing that runs. Every image scored
  # is billed. So the caller shortlists on a free metadata score first
  # (GatherReferencePhotos::VISION_SHORTLIST) and only the survivors are sent, in
  # ONE request rather than one request per photograph.
  #
  # ANTHROPIC FETCHES THE IMAGES SERVER-SIDE, from a `type: "url"` image source —
  # we never download the bytes. That is the same trust boundary Higgsfield's
  # create sits behind, and it carries the same obligation: only ever pass URLs
  # that have already cleared Appearances::FetchableUrl. The caller does.
  #
  # DEGRADES, NEVER RAISES. No credential, a refusal, a timeout, an unparseable
  # answer — every one of them returns an empty Hash, and the caller falls back to
  # its free ranking. The same contract Appearances::ImageSearch already holds: an
  # optional enrichment must never cost the operator the page.
  class FaceVisibility
    API_URL = "https://api.anthropic.com/v1/messages".freeze
    API_KEY_ENV = "ANTHROPIC_API_KEY".freeze

    # HAIKU, DELIBERATELY, and this is the one place in this feature where a
    # cheaper model is the right call rather than a shortcut: the job is a bulk
    # per-image classification with a one-word answer, run over up to a dozen
    # candidates per look, and the task carries a `cost` risk tag.
    #
    # NO DATE SUFFIX. The eight other Anthropic callers in this app pin
    # `claude-haiku-4-5-20251001`; the current published id is the bare
    # `claude-haiku-4-5`. Those pins are stale rather than wrong-here — migrating
    # them is its own change with its own blast radius, so this file uses the
    # current spelling and does not quietly rewrite theirs.
    MODEL = "claude-haiku-4-5".freeze
    ANTHROPIC_VERSION = "2023-06-01".freeze

    # A one-line JSON answer per image. Small on purpose — a classifier that can
    # run long is a classifier that can bill long.
    MAX_TOKENS = 512

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30

    # Asking for a NUMBER rather than a yes/no, because the caller RANKS rather
    # than filters: "mostly visible, three-quarter profile" has to be able to beat
    # "fully visible but 80 pixels wide" and lose to a clean head-on portrait, and
    # a boolean collapses all three.
    #
    # The index is echoed back because the answer order is not guaranteed to match
    # the request order — keying on position would silently mis-attribute a score
    # to the wrong photograph, which is the failure a reviewer could not see.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You rate photographs that will be used as reference images for building a
      character likeness. The only thing that matters is whether the person's FACE
      is clearly visible and unobstructed.

      Score each image from 0.0 to 1.0:
        1.0  a clear, well-lit, unobstructed view of the face
        0.6  face visible but partly turned, small in frame, or partly shadowed
        0.3  face mostly obscured - heavy shadow, far from camera, partial occlusion
        0.15 a person IS present but their face is hidden - helmet, mask, back of
             head, hands over the face
        0.0  NO PERSON IS PRESENT AT ALL - a document scan, a book page, a logo, a
             diagram, a landscape, an empty stadium

      The 0.15 / 0.0 split matters and is not a rounding difference: 0.15 means
      "this is a photograph of the person, you just cannot see their face" and 0.0
      means "this is not a photograph of anybody". A sports helmet or a catcher's
      mask is 0.15 even when the person is obviously identifiable from their
      uniform. A scanned page is 0.0.

      Respond with ONLY a JSON array, no markdown and no explanation. One object
      per image, echoing the index you were given:
      [{"index": 0, "score": 0.9, "reason": "clear head-on portrait"}, ...]
    PROMPT

    def self.available? = ENV[API_KEY_ENV].present?

    def self.call(image_urls, target: nil) = new.call(image_urls, target: target)

    def initialize(api_key: nil)
      @api_key = api_key || ENV[API_KEY_ENV].presence
    end

    # Returns { image_url => Float } for the images it could score. A URL absent
    # from the Hash was NOT judged — which the caller must treat as "unknown",
    # never as "no face", or an outage would quietly demote every photograph.
    #
    # EVERY DEGRADE IS ALSO AN ErrorLog ROW (`target:` names the look it happened
    # on). An empty Hash is the answer for "no credential", "refused", "timed out"
    # and "unreadable answer" alike, and on the page all four render as the same
    # sentence — "ranked on shape and relevance only (no face classifier)". That
    # sentence is TRUE of a machine with no key and MISLEADING of a machine whose key
    # was rejected, and only a row in /admin/error_logs tells the operator which one
    # they are looking at.
    def call(image_urls, target: nil)
      urls = Array(image_urls).map(&:to_s).uniq.reject(&:empty?)
      return {} if urls.empty? || @api_key.blank?

      parse(post(urls), urls, target: target)
    rescue StandardError => e
      Rails.logger.warn("[Appearances::FaceVisibility] #{e.class}: #{e.message}")
      FailureLog.file(e, target: target)
      {}
    end

    private

    # ONE REQUEST, EVERY IMAGE. N requests would multiply the per-call overhead by
    # N for an answer the model can give in one pass, and the images are all of the
    # same person — the comparison is part of the judgement.
    # ONE MESSAGE, EVERY IMAGE, each behind its own index label.
    #
    # Split out from #post so the suite can assert the REQUEST SHAPE without
    # stubbing the method that builds it — a test that stubs `post` and then
    # rebuilds the content itself proves only that the test can build content.
    def build_content(urls)
      urls.each_with_index.flat_map do |url, index|
        [
          { type: "text", text: "Image index #{index}:" },
          # A URL SOURCE, so Anthropic fetches the bytes server-side and we never
          # do. Same trust boundary as Higgsfield's create, same obligation: the
          # caller has already cleared every one of these through FetchableUrl.
          { type: "image", source: { type: "url", url: url } }
        ]
      end
    end

    def post(urls)
      content = build_content(urls)

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri.path)
      request["content-type"] = "application/json"
      request["x-api-key"] = @api_key
      request["anthropic-version"] = ANTHROPIC_VERSION
      request.body = {
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content: content }]
      }.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                     open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end

      raise "Anthropic answered #{response.code}: #{response.body.to_s[0, 200]}" unless
        response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body.to_s)
    end

    # READ THE ANSWER TOLERANTLY. A score we cannot read is an ABSENT key rather
    # than a zero: the caller reads absence as "unknown" and falls back to its free
    # ranking, while a zero would assert "this photograph has no face in it" on the
    # strength of a parse failure.
    def parse(payload, urls, target: nil)
      text = Array(payload["content"]).filter_map { |b| b["text"] if b["type"] == "text" }.join
      rows = JSON.parse(text[/\[.*\]/m].to_s)
      return {} unless rows.is_a?(Array)

      rows.each_with_object({}) do |row, scores|
        next unless row.is_a?(Hash)

        index = Integer(row["index"], exception: false)
        url = urls[index] if index && index >= 0
        score = Float(row["score"], exception: false)
        next if url.nil? || score.nil?

        scores[url] = score.clamp(0.0, 1.0)
      end
    rescue JSON::ParserError, TypeError => e
      Rails.logger.warn("[Appearances::FaceVisibility] unreadable answer: #{e.class}: #{e.message}")
      # LOGGED SEPARATELY FROM THE #call RESCUE because it means something different:
      # we PAID for this answer and could not read it. That is a parser bug on our
      # side, not a vendor outage, and it is the one failure here that recurs
      # silently on every search until somebody reads the row.
      FailureLog.file(e, target: target)
      {}
    end
  end
end
