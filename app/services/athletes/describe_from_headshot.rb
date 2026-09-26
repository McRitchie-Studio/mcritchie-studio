require "base64"

module Athletes
  # WHAT IS VISIBLE IN ONE ATHLETE'S CACHED HEADSHOT — skin tone and hair, and
  # nothing else.
  #
  # These are descriptions of REAL PEOPLE, written by a machine, stored in a
  # database, and then fed to an image generator through
  # Athlete#physical_brief. Three rules follow from that, and all three are
  # enforced here rather than left to the prompt:
  #
  #   1. ONLY WHAT THE PHOTOGRAPH SHOWS. The prompt below forbids inferring
  #      ethnicity, nationality or origin, and asks for skin tone in the register a
  #      portrait photographer or illustrator uses — the vocabulary of rendering a
  #      face, not of classifying a person.
  #   2. BLANK BEATS A GUESS. Every field can come back nil, and #normalize turns
  #      the model's hedges ("unknown", "not visible", "n/a") into nil too. A nil
  #      shows as an empty field on the person page, which invites a human to fill
  #      it; a hedge written into the column reads as a description and silently
  #      poisons every prompt built from it.
  #   3. BUILD IS NOT ASKED FOR. A headshot is head and shoulders — it cannot see a
  #      body. Build comes from the athlete's recorded height and weight
  #      (Athletes::BuildFromMeasurements), which production has for every athlete.
  #
  # ONE ATHLETE PER CALL, DELIBERATELY, and this is the one place a cheaper design
  # was available and refused. Batching ten headshots into one request would share
  # the system prompt and cut the run's cost by roughly $0.65 (measured: ~350 system
  # tokens x 2,043 calls). It would also bind each answer to its athlete by an INDEX
  # the model echoes back — and an off-by-one there writes one man's hair onto
  # another man's row, permanently and invisibly. This feature exists because a
  # bulk write mis-filed 2,043 rows once already. The saving is not worth a second
  # mechanism whose failure mode is undetectable; here the athlete is the request.
  #
  # THE IMAGE IS READ BY ITS RECORDED s3_key, NEVER BY RECOMPUTING THE PREFIX, and
  # that is not a style preference. Measured on production 2026-09-26: all 6,129
  # cached headshot objects sit under `headshots/nfl/free-agents/...`, while
  # `team_slug` is populated for all 2,051 athletes — so Athlete#headshot_key_prefix
  # computes `headshots/nfl/seattle-seahawks/jaxon-smith-njigba` for a file that is
  # actually at `headshots/nfl/free-agents/jaxon-smith-njigba`. The ImageCache row
  # knows where the bytes are; the deriver does not.
  #
  # DEGRADES, NEVER RAISES. No credential, no headshot, a refusal, a timeout, an
  # unreadable answer — every one returns a blank Result and files an ErrorLog row.
  # A backfill over 2,000 rows must not die on one of them.
  class DescribeFromHeadshot
    API_KEY_ENV = "ANTHROPIC_API_KEY".freeze

    # HAIKU 4.5, and the operator asked for it in as many words: "use the cheapest
    # model that does the job; this is description, not reasoning." It is also what
    # Appearances::FaceVisibility already runs for the neighbouring vision job, so
    # the two halves of this feature bill at one rate.
    #
    # NO DATE SUFFIX — the current published id is the bare name. The eight older
    # Anthropic callers in this app pin `claude-haiku-4-5-20251001`; those pins are
    # stale rather than wrong-here, and re-pointing them is its own change with its
    # own blast radius.
    MODEL = "claude-haiku-4-5".freeze

    # THE 400px VARIANT. Measured: the cached variants are 400x291 and 100x73, which
    # the Messages API bills at roughly (w x h)/750 = ~155 and ~10 image tokens. The
    # 100px crop is cheaper by ~$0.00015 a call and far too coarse to read hair
    # texture or a beard; the original (266 KB) buys no accuracy the 400 lacks,
    # since the API downsamples anything larger anyway.
    HEADSHOT_VARIANT = "400".freeze
    HEADSHOT_PURPOSE = "headshot".freeze

    # A two-field JSON answer needs no room to ramble, and a model that can run long
    # is a model that can bill long.
    MAX_TOKENS = 300

    # Each column is a varchar with no database limit, so the cap is ours to set. A
    # paragraph in `hair_description` would not be wrong so much as unusable: these
    # strings are concatenated into an image prompt, where a run-on sentence
    # crowds out the rest of the brief.
    MAX_FIELD_LENGTH = 120

    # THE HEDGES A MODEL REACHES FOR INSTEAD OF SAYING NOTHING. Compared after
    # downcasing and stripping; each one becomes nil. Without this the column
    # ends up holding "not visible", which renders on the person page as though
    # it described the man.
    BLANK_ANSWERS = [
      "", "unknown", "not visible", "not applicable", "n/a", "na", "none",
      "null", "nil", "no hair visible", "cannot tell", "can't tell", "unclear",
      "indeterminate", "not determinable", "no", "-"
    ].freeze

    # THE PROMPT IS THE FEATURE. Everything careful about this change lives here,
    # so read it as policy rather than as string content.
    #
    # WHY IT SPELLS OUT WHAT IS *NOT* A DEMOGRAPHIC CLAIM. An instruction to avoid
    # inferring ethnicity, given alone, makes a well-aligned model refuse to
    # describe visible hair and visible skin at all — which would spend the whole
    # run to write 2,043 nulls. The distinction it needs is that "deep brown skin,
    # warm undertone" and "short locs" are RENDERING instructions an illustrator
    # works from, while "African-American" is a label about a person. The first is
    # what this field is for; the second is what it must never hold.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are writing reference notes for an illustrator who must draw a person they
      have never met, working from one photograph. The notes describe how to RENDER
      the person's skin and hair. They are stored beside the photograph and read by
      whoever draws it.

      These are real people. Describe ONLY what is visible in this photograph.

      NEVER state or imply ethnicity, nationality, race, ancestry or origin. Do not
      name a country, a region or a people. If you find yourself about to write a
      word that identifies a group, you are answering the wrong question.

      What you ARE asked for is the visual vocabulary a portrait photographer or a
      figure illustrator uses. "Deep brown skin with a warm undertone" and "short
      locs, faded at the sides" are rendering instructions and are exactly right.
      "African-American" or "Polynesian" are labels about a person and are wrong
      here. The difference is the point: describe the surface you can see, in the
      words someone would use to paint it, and claim nothing about who the person
      is or where they come from.

      SKIN TONE. Use this scale, optionally with one undertone word:
        very fair, fair, light, light-medium, medium, olive, tan, medium-deep,
        deep, very deep
        undertones: warm, cool, neutral, golden, olive, ruddy
      Write at most a short phrase, e.g. "medium-deep, warm undertone". Judge the
      face, not the lighting: a photograph lit hard from one side is still the same
      person. If the exposure makes you unsure, say nothing rather than guess.

      HAIR. What is visible of it: colour, length, texture and how it is worn, plus
      visible facial hair. A visible hairstyle is a visual fact, so name it plainly
      — braids, locs, an afro, a buzz cut, cornrows, a fade, a topknot, shaved,
      bald. Include a beard, moustache or clean-shaven face if you can see it.
      A short phrase, e.g. "short black fade, full beard".

      IF THE HAIR IS COVERED — a helmet, a cap, a hood, a skullcap — then you cannot
      see it, and the answer for hair is null. Do not describe the headwear; this
      field is about the person, not their kit. Bald and shaved ARE visible, and are
      a real answer rather than null.

      IF NO PERSON IS CLEARLY VISIBLE — a placeholder silhouette, a logo, a crowd,
      an empty frame — set person_visible to false and both fields to null.

      PREFER NULL TO A GUESS, always, for either field independently. An empty field
      is read by a human later. A confident wrong one is not, and it is worse.

      Respond with ONLY a JSON object, no markdown and no explanation:
      {"person_visible": true, "skin_tone": "medium-deep, warm undertone", "hair_description": "short black fade, full beard"}
    PROMPT

    # What one athlete's headshot yielded. Every field is optional: a Result with
    # both descriptions nil is the honest answer for a covered face, an unreadable
    # answer, or an outage, and the caller writes nothing for it.
    #
    # `usage` carries the call's token counts so the caller can price the run at
    # UsagePricing list rates rather than estimate it. It is nil when no call was
    # made (no credential, no cached headshot), which is how the caller tells
    # "described nothing, spent nothing" from "described nothing, paid for it".
    Result = Data.define(:skin_tone, :hair_description, :person_visible, :usage, :model) do
      def any? = skin_tone.present? || hair_description.present?
      def billed? = usage.present?
    end

    BLANK = Result.new(skin_tone: nil, hair_description: nil, person_visible: nil,
                       usage: nil, model: MODEL).freeze

    def self.available? = ENV[API_KEY_ENV].present?

    def self.call(athlete) = new.call(athlete)

    # `transport` and `downloader` are seams, not configuration. The suite injects
    # both; production passes neither. Athletes::VisionTransport is the ONLY paid
    # path out of this process and it is armed to raise under the test suite, so a
    # test that forgets to inject one fails rather than spends.
    def initialize(api_key: nil, transport: nil, downloader: nil)
      @api_key = api_key || ENV[API_KEY_ENV].presence
      @transport = transport || VisionTransport.method(:call)
      @downloader = downloader || ->(key:) { Studio::S3.download(key: key) }
    end

    def call(athlete)
      return BLANK if athlete.nil? || @api_key.blank?

      cache = headshot_row(athlete)
      return BLANK if cache.nil?

      # BY THE RECORDED KEY. See the class comment: recomputing the prefix looks in
      # a folder the bytes are not in.
      image = @downloader.call(key: cache.s3_key)
      return BLANK if image.blank?

      parse(@transport.call(body: request_body(image, cache.content_type), api_key: @api_key), target: athlete)
    rescue StandardError => e
      Rails.logger.warn("[Athletes::DescribeFromHeadshot] #{athlete&.slug}: #{e.class}: #{e.message}")
      Appearances::FailureLog.file(e, target: athlete)
      BLANK
    end

    private

    # Read off the loaded association when the caller preloaded it (a backfill over
    # 2,000 rows does), so a warm run issues no query per athlete.
    def headshot_row(athlete)
      athlete.image_caches.detect do |c|
        c.purpose == HEADSHOT_PURPOSE && c.variant == HEADSHOT_VARIANT
      end
    end

    # Split out so the suite can assert the REQUEST SHAPE without stubbing the
    # method that builds it — a test that stubs the post and then rebuilds the body
    # itself proves only that the test can build a body.
    def request_body(image_bytes, content_type)
      {
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: SYSTEM_PROMPT,
        messages: [{
          role: "user",
          content: [
            # BASE64, NOT A URL SOURCE, unlike Appearances::FaceVisibility — which
            # passes arbitrary web URLs it has cleared through FetchableUrl. These
            # bytes are ours, in our own bucket, and reading them with our own
            # credentials means the pass does not depend on the bucket staying
            # publicly readable. It is public today (measured: a plain GET returns
            # 200), but the CDN rollout plans an origin lockdown, and a URL source
            # would start failing 2,043 times the day that lands.
            { type: "image",
              source: { type: "base64",
                        media_type: content_type.presence || "image/png",
                        data: Base64.strict_encode64(image_bytes) } },
            { type: "text", text: "Describe this person's skin tone and hair." }
          ]
        }]
      }
    end

    # READ THE ANSWER TOLERANTLY, and write nothing we cannot read. A parse failure
    # yields nil fields rather than a raise, but it still carries the `usage` — we
    # PAID for that answer, and a run that silently drops the cost of what it could
    # not read under-reports its own bill.
    def parse(payload, target: nil)
      usage = usage_from(payload)
      text = Array(payload["content"]).filter_map { |b| b["text"] if b["type"] == "text" }.join
      row = JSON.parse(text[/\{.*\}/m].to_s)
      raise JSON::ParserError, "answer was not a JSON object" unless row.is_a?(Hash)

      visible = row["person_visible"]
      # FALSE MEANS NOTHING IS WRITTEN, for either field. `nil` (the key absent) is
      # NOT false — an older or terser answer that omits the flag but describes a
      # face is still a usable answer, so only an explicit false suppresses it.
      return Result.new(skin_tone: nil, hair_description: nil, person_visible: false,
                        usage: usage, model: MODEL) if visible == false

      Result.new(
        skin_tone: normalize(row["skin_tone"]),
        hair_description: normalize(row["hair_description"]),
        person_visible: visible,
        usage: usage,
        model: MODEL
      )
    rescue JSON::ParserError, TypeError => e
      # FILED SEPARATELY FROM THE #call RESCUE because it means something different:
      # the call SUCCEEDED and we could not read it. That is a parser bug on our
      # side, not a vendor outage, and it is the one failure here that would recur
      # on every athlete — 2,043 paid calls writing nothing — until somebody read
      # the row.
      Rails.logger.warn("[Athletes::DescribeFromHeadshot] unreadable answer: #{e.class}: #{e.message}")
      Appearances::FailureLog.file(e, target: target)
      Result.new(skin_tone: nil, hair_description: nil, person_visible: nil,
                 usage: usage, model: MODEL)
    end

    # nil for anything that is not a real description — blank, a hedge, or a
    # non-string. See BLANK_ANSWERS: the hedges are the dangerous case, because
    # they are truthy and would be written.
    def normalize(value)
      return nil unless value.is_a?(String)

      text = value.strip.squeeze(" ")
      return nil if BLANK_ANSWERS.include?(text.downcase.delete_suffix("."))

      text.truncate(MAX_FIELD_LENGTH)
    end

    # The two buckets UsagePricing needs, keyed as it expects. Absent counts read as
    # zero rather than nil so a partial usage block still prices.
    def usage_from(payload)
      usage = payload["usage"]
      return nil unless usage.is_a?(Hash)

      { "input" => usage["input_tokens"].to_i, "output" => usage["output_tokens"].to_i }
    end
  end
end
