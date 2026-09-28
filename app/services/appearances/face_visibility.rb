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
  # AND THAT OBLIGATION IS NOW STRICTER — PASS ONLY A URL WE SERVE. Measured on
  # production 2026-09-26, the first real run answered 400 on every image ("Unable to
  # download the file. Please verify the URL and try again") because Wikimedia refuses
  # a request that sends no User-Agent and Anthropic's fetcher was the party being
  # refused: against the exact failing URL, 403 with no UA and 200 with one. There is
  # no header of ours to set on someone else's fetch, so
  # Appearances::GatherReferencePhotos now mirrors every shortlisted candidate into our
  # own S3 (Appearances::MirrorCandidates) and hands this object the copy. Handing it a
  # remote URL again would reproduce the whole defect SILENTLY — the degrade below is
  # indistinguishable from a set of photographs that simply scored badly, and on that
  # run it put three photographs of AIRCRAFT into a character model.
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

    # ONE JSON OBJECT PER IMAGE, IN ONE ANSWER — so this ceiling scales with the
    # caller's shortlist and not with anything about this file.
    #
    # ⚠ IT WAS 512 AND THAT WAS ALREADY TOO LOW FOR TWELVE IMAGES. Measured 2026-09-27
    # with /v1/messages/count_tokens, which is free, over a realistic answer object
    # ({"index", "visibility", "fill", "faces", "reason"} with a short reason):
    #
    #   12 images  1,259 characters   523 tokens   against a MAX_TOKENS of 512
    #   24 images  2,519 characters  1,039 tokens
    #
    # AND TRUNCATION HERE IS NOT A SHORT ANSWER, IT IS NO ANSWER. `#parse` finds the
    # array with `text[/\[.*\]/m]`, which needs the CLOSING bracket; a response stopped
    # at `max_tokens` has none, the match is nil, `JSON.parse("")` raises, and the rescue
    # returns an EMPTY hash. Every image in the batch loses its judgement, the caller
    # reports `face_classifier_blind?`, and the page raises the alarm that says the
    # vendor saw nothing — for a batch the vendor saw perfectly and answered in full. The
    # failure names the wrong party, which is the one kind of alarm worse than silence.
    #
    # 2,048 IS TWICE WHAT 24 IMAGES MEASURED, and the headroom is free: output is billed
    # on tokens GENERATED, never on the ceiling, so a generous limit costs nothing and a
    # tight one costs the whole answer. It still bounds the run — "a classifier that can
    # run long is a classifier that can bill long" was the right instinct and the wrong
    # number. Raise it with Appearances::GatherReferencePhotos::VISION_SHORTLIST; the two
    # are one decision made in two files.
    MAX_TOKENS = 2048

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30

    # THREE NUMBERS PER IMAGE, AND THE SECOND ONE IS THE ONE THAT DECIDES A MINT.
    #
    # `visibility` — asked as a NUMBER rather than a yes/no because the caller RANKS
    #   rather than filters: "mostly visible, three-quarter profile" has to be able to
    #   beat "fully visible but 80 pixels wide" and lose to a clean head-on portrait,
    #   and a boolean collapses all three.
    #
    # `fill` — HOW MUCH OF THE FRAME THE HEAD FILLS, asked separately because
    #   visibility provably cannot be read back for it. Four real Higgsfield mints on
    #   2026-09-25 settled which one decides: a BARE-FACED 556x780 sideline shot failed
    #   at prepare and a tight ESPN headshot completed, so face size in frame is the
    #   variable and resolution is not. A single score cannot carry both, because this
    #   prompt used to give "small in frame" and "partly turned" the same 0.6 — so a
    #   0.6 could not be read as either judgement.
    #
    # `faces` — HOW MANY PEOPLE'S FACES ARE CLEARLY VISIBLE. An identity trained on a
    #   photograph of two players is trained on a blend of two faces, and the
    #   visibility score is beautiful for exactly that photograph.
    #
    # ⚠ THE TWO NEW FIELDS ARE UNVERIFIED AGAINST THE LIVE MODEL. The task that added
    # them forbade paid calls (`cost` risk tag), so `#parse` was written and tested
    # against fixtures instead. THE DEGRADE IS THEREFORE THE IMPORTANT PART: a field
    # the model does not return is ABSENT, never zero, and
    # Appearances::GatherReferencePhotos::Summary#face_size_blind? raises an alarm on
    # the page and files an ErrorLog row the first time a real answer comes back
    # without one. A silent degrade here would have made the whole gate inert in
    # production with nothing to read.
    #
    # The index is echoed back because the answer order is not guaranteed to match
    # the request order — keying on position would silently mis-attribute a score
    # to the wrong photograph, which is the failure a reviewer could not see.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You rate photographs that will be used as reference images for training a
      character likeness of ONE named person. Two things matter and they are
      separate: whether that person's FACE IS VISIBLE, and HOW BIG the head is in
      the frame.

      For each image report three numbers.

      "visibility" 0.0 to 1.0 - how clearly a face shows:
        1.0  a clear, well-lit, unobstructed view of the face
        0.6  face visible but partly turned or partly shadowed
        0.3  face mostly obscured - heavy shadow, partial occlusion
        0.15 a person IS present but their face is hidden - helmet, mask, back of
             head, hands over the face
        0.0  NO PERSON IS PRESENT AT ALL - a document scan, a book page, a logo, a
             diagram, a landscape, an empty stadium

      The 0.15 / 0.0 split matters and is not a rounding difference: 0.15 means
      "this is a photograph of the person, you just cannot see their face" and 0.0
      means "this is not a photograph of anybody". A sports helmet or a catcher's
      mask is 0.15 even when the person is obviously identifiable from their
      uniform. A scanned page is 0.0.

      "fill" 0.0 to 1.0 - HOW MUCH OF THE FRAME THE HEAD OCCUPIES. Judge the head
      itself, not the body, and judge SIZE only - a helmeted head that fills the
      frame is a high fill and a low visibility:
        1.0  a tight head crop - the head is most of the picture, as in a passport
             photograph or a sports headshot
        0.6  a head-and-shoulders portrait - the head is roughly a third of the
             frame's height
        0.3  upper body or mid-range - the head is under a fifth of the frame
        0.1  full body, or a distant sideline or crowd photograph - the head is a
             small part of the frame
        0.0  no head in the picture at all

      "faces" - a whole number: how many DIFFERENT people's faces are clearly
      visible. Count only faces you can actually see; a crowd blurred in the
      background is not a visible face. Most reference photographs are 1.

      Respond with ONLY a JSON array, no markdown and no explanation. One object
      per image, echoing the index you were given:
      [{"index": 0, "visibility": 0.9, "fill": 0.8, "faces": 1,
        "reason": "tight head-on portrait"}, ...]
    PROMPT

    # WHAT ONE IMAGE CAME BACK AS. A value object rather than three parallel Hashes,
    # because the three numbers are one answer about one photograph and parallel Hashes
    # drift — a caller that translated two of them and forgot the third would read as
    # "the classifier did not report a face size", which is the one state this lane
    # already went blind on once.
    #
    # EVERY MEMBER IS SEPARATELY NULLABLE. `visibility` without `fill` is the shape a
    # model that ignored the new field returns, and it must degrade to the old
    # behaviour rather than to a zero.
    #
    # NAMING: `visibility` is the number the COLUMN calls `face_score`. The column
    # keeps its name — renaming it is a migration and a rewrite of every reader for no
    # new fact — but the object says `visibility`, because reading `face_score` as face
    # SIZE is the defect this whole file now exists to separate.
    Judgement = Struct.new(:visibility, :fill, :subjects, keyword_init: true) do
      # ONLY THE QUESTION SOMEBODY ASKS. `sized?` is read by the ranker, the summary and the
      # mint gate; a companion `measured?` for `visibility` was written and never called,
      # because a Judgement with no visibility is dropped by the parser and never reaches a
      # caller at all — so the predicate could only ever answer true.
      def sized? = !fill.nil?
    end

    def self.available? = ENV[API_KEY_ENV].present?

    def self.call(image_urls, target: nil) = new.call(image_urls, target: target)

    def initialize(api_key: nil)
      @api_key = api_key || ENV[API_KEY_ENV].presence
    end

    # Returns { image_url => Judgement } for the images it could score. A URL absent
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
      # THE ONLY PLACE IN THIS OBJECT THAT SPENDS MONEY, so it is where the trap sits.
      # #call, #build_content and #parse are all reachable from a test for free and
      # should stay that way; this method must not be, and the suite's protection was
      # previously that every test remembered to inject a fake classifier.
      LiveCallTrap.refuse!(
        what: "A paid Anthropic face-classification call (#{self.class})",
        remedy: "Inject a classifier at the caller's seam: " \
                "Appearances::GatherReferencePhotos.new(look, faces: fake). To exercise " \
                "this object itself, drive #build_content or #parse directly — neither spends."
      )

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

    # READ THE ANSWER TOLERANTLY. A number we cannot read is an ABSENT member rather
    # than a zero: the caller reads absence as "unknown" and falls back to its free
    # ranking, while a zero would assert "this photograph has no face in it" on the
    # strength of a parse failure.
    #
    # A ROW WITH NO VISIBILITY IS DROPPED ENTIRELY, because visibility is the member
    # every caller keys on — a Judgement carrying only a fill would rank a photograph
    # nothing readable was said about. A row with a visibility and no fill is KEPT: it
    # is exactly the old answer shape, and losing it would turn a model that ignored
    # the new field into a total outage.
    #
    # `visibility` OR `score`, because the field was called `score` until face size
    # was split out of it, and a model echoing the older spelling back is answering the
    # same question. Tolerating both costs one `||` and removes a way for a correct
    # answer to be thrown away.
    def parse(payload, urls, target: nil)
      text = Array(payload["content"]).filter_map { |b| b["text"] if b["type"] == "text" }.join
      rows = JSON.parse(text[/\[.*\]/m].to_s)
      return {} unless rows.is_a?(Array)

      rows.each_with_object({}) do |row, judgements|
        next unless row.is_a?(Hash)

        index = Integer(row["index"], exception: false)
        url = urls[index] if index && index >= 0
        visibility = unit(row["visibility"] || row["score"])
        next if url.nil? || visibility.nil?

        judgements[url] = Judgement.new(visibility: visibility, fill: unit(row["fill"]),
                                        subjects: count(row["faces"]))
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

    # A 0.0..1.0 NUMBER, OR nil. Clamped rather than trusted — the scale is ours and a
    # model that answers 1.4 has not invented a new band — and nil for anything that is
    # not a number at all, which is how a missing field stays missing.
    def unit(value)
      number = Float(value, exception: false)
      number&.clamp(0.0, 1.0)
    end

    # A WHOLE COUNT, OR nil. A negative count is not a count, and 0 is meaningful: it
    # says the model looked and saw nobody's face, which the caller reads through
    # visibility anyway.
    def count(value)
      number = Integer(value, exception: false)
      number if number && !number.negative?
    end
  end
end
