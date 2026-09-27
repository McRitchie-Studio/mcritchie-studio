module Appearances
  # EVERY PHOTOGRAPH A LOOK HAS, AND WHICH OF THEM THE IDENTITY IS BUILT FROM.
  #
  # This is the object the mint path is injected with once a search has run:
  #
  #   Appearances::CreateCharacterReference.new(look, references: Appearances::ReferenceSet)
  #
  # It implements exactly the contract Appearances::ReferenceImages documents —
  # `.call(appearance)` returning an Array of absolute http(s) URLs, most
  # authoritative first, de-duplicated, possibly empty — so the create service
  # does not change and its seam test still describes the truth.
  #
  # THE FLOOR STILL LEADS. Appearances::ReferenceImages answers first and its
  # answer is not reordered: the cached headshot is the one URL whose public
  # reachability we control and have measured, the operator's URL is one a human
  # looked at, and a search hit is one nobody has seen. Leading with the measured
  # one keeps the first image in every list one we can vouch for, which was a
  # deliberate property of the floor and would have been quietly lost by
  # concatenating the other way round.
  #
  # AND THE HEADSHOT LEADS A SET OTHERS MAY JOIN — the product question this object is
  # the answer to, settled deliberately on task `reference-photos-wrong-person`.
  #
  # The alternative was to keep scouted photographs OPERATOR-FACING ONLY: the cached
  # headshot mints alone, and the scouting page is pure taste calibration. That is
  # defensible on the mint measurements — the headshot is the only input that has ever
  # completed a reference — and it was rejected, because it makes every search a
  # purchase with no product behind it and because the acceptance criterion says the
  # headshot *leads*, which implies something follows.
  #
  # SO A SCOUTED PHOTOGRAPH MAY JOIN, BUT IT HAS TO EARN IT: Appearances::ReferenceEligibility
  # refuses a document, a stranger, a crowd, a hidden face, a face MEASURED to be too small
  # in frame — and a photograph NOTHING LOOKED AT, which is the refusal production evidence
  # added on 2026-09-27 after five of five unjudged candidates were chosen for one look.
  #
  # TWO LISTS, BECAUSE THE TWO GENERATORS DO NOT ACCEPT THE SAME SET:
  #
  #   #generation_urls — the ZERO-SHOT sheet (Appearances::GenerateArtifact). Every
  #     chosen photograph, floor first. No preparation stage exists to refuse them, so a
  #     weak reference costs a weaker sheet and never a failed purchase.
  #   #call            — HIGGSFIELD'S TRAINER (Appearances::CreateCharacterReference).
  #     The same list minus every photograph whose face size nobody measured, because
  #     four of six measured mints failed at prepare and face size is the variable they
  #     turned on.
  #
  # `#call` STAYS THE STRICT ONE because it is the injected `references:` contract, and
  # the injected list is the one that gets BILLED FOR A TRAINING RUN. A caller that
  # forgets which reader it wants should get the conservative answer.
  #
  # THE FLOOR IS NOT PERSISTED, and that is why this object exists rather than a
  # scope on the model. The headshot is derived from the athlete's ImageCache rows
  # and the operator's URL is a column on the look; copying either into
  # appearance_reference_photos would be a second home for a fact that already has
  # one, and it would need a WRITE on every page view to stay current. So the
  # gallery composes them in memory instead — #gallery builds unsaved rows for the
  # floor and renders them beside the persisted search hits.
  class ReferenceSet
    # SYNTHETIC SLUGS for the two unsaved floor rows. Distinct from the model's own
    # `refphoto-<hex>` so a slug in a log or a DOM id can never be mistaken for a
    # row somebody could go and look up.
    FLOOR_SLUG_PREFIX = "floor-".freeze

    # HOW MANY REFERENCES A ZERO-SHOT SHEET IS GIVEN.
    #
    # OURS, NOT THE VENDOR'S — no limit was read off a doc and none was measured. Every
    # reference is bytes inlined into one request body plus another image for the model to
    # reason over, and the sheet call already runs in minutes. Four is the cached headshot
    # plus three, which is "a few headshots" in the operator's own words.
    GENERATION_LIMIT = 4

    def self.call(appearance) = new(appearance).call

    def initialize(appearance)
      @appearance = appearance
    end

    # THE TRAINER'S LIST. Floor first, then the chosen search hits that today's rule
    # still stands behind AND whose face size something actually measured.
    #
    # TWO GUARDS RUN AGAIN HERE, over rows GatherReferencePhotos already judged, and
    # for one reason: ROWS OUTLIVE THE RULE THAT JUDGED THEM.
    #
    #   `FetchableUrl` — a tightening of the engine's SSRF ranges would otherwise apply
    #   only to photographs found AFTER the change, and a year-old row would keep being
    #   handed to a remote fetcher under a rule nobody holds any more.
    #
    #   `mint_eligible?` — every row filed before Appearances::ReferenceEligibility existed
    #   was chosen by a ranking that never asked how big the face was or whose face it
    #   was. Four real mints on 2026-09-25 say those rows fail at prepare, and one of
    #   them was a photograph of a DIFFERENT MAN that ranked second. Re-judging here is
    #   what stops a stale verdict spending money, and it is deterministic for the free
    #   half of the rule: a title naming somebody else is refused today even on a row
    #   nothing ever classified.
    #
    # Both are free, and this is the last place either can run before the purchase.
    def call
      (floor_urls + offerable_urls(:mint_eligible?)).uniq
    end

    # THE ZERO-SHOT SHEET'S LIST — what the operator asked for on 2026-09-27: "it would
    # be better if we provided a few headshots when submitting for the character model
    # ... more context on facial structure and expressions".
    #
    # OUR OWN MIRRORED COPY IS PREFERRED OVER THE PROVIDER'S URL, and on this path that
    # is not a nicety. ImageGeneration::OpenAI downloads the bytes ITSELF and inlines them
    # as a data URI, and Wikimedia answers 403 to a request that sends no User-Agent —
    # measured 2026-09-26, when Anthropic's fetcher was refused on exactly these URLs. A
    # Commons candidate handed over raw would raise "reference ... answered HTTP 403" and
    # cost the operator the whole sheet; the mirrored copy sits on our own S3 and needs no
    # headers of anybody's.
    #
    # ⚠ WHETHER MORE REFERENCES MAKE A BETTER SHEET IS UNMEASURED ON THIS PATH. The "five
    # references were no better than one" finding in this repo is attributed to three
    # different endpoints in three different places — config/image_generators.yml credits
    # this Responses row, ImageGeneration::OpenAI credits /v1/images/edits, and the
    # 2026-09-27 operator relay credits the Higgsfield training path — so it cannot be
    # relied on for any of them. No credential for this vendor exists on the machine this
    # was built on, so nothing here was measured against the live API.
    def generation_urls
      (floor_urls + offerable_urls(:reference_eligible?, prefer_hosted: true))
        .uniq
        .first(GENERATION_LIMIT)
    end

    # CHOSEN ROWS TODAY'S RULE WOULD NOT SPEND ON — the difference between what the
    # gallery calls "in the model" and what #call actually offers the vendor.
    #
    # NORMALLY EMPTY, and it exists so that when it is not, the page can SAY so. A
    # search run after this rule shipped stamps `chosen` with the same verdict this
    # method re-checks, so the two agree by construction; a row from before it does not,
    # and an "In the model (6)" heading above an identity built from 1 is exactly the
    # kind of quietly disagreeing pair of counts this lane has already shipped once.
    def refused_rows
      persisted_rows.select { |photo| photo.chosen? && !offerable?(photo, :mint_eligible?) }
    end

    # WHAT THE PAGE SHOWS: every candidate, chosen first, floor included.
    #
    # Returns AppearanceReferencePhoto instances — persisted for the search hits,
    # UNSAVED for the two floor entries — so one partial renders all of them and
    # the gallery cannot drift from the list the identity was built from.
    def gallery
      floor = floor_rows
      seen = floor.map(&:image_url).to_set
      # THE SAME PHOTOGRAPH IS ONE TILE, NOT TWO.
      #
      # A search routinely re-finds the URL the operator already typed, so the same
      # image exists both as a floor row and as a persisted search row. #call
      # de-duplicates (the vendor must not be billed twice for one picture), and
      # without the same collapse here the gallery said "IN THE MODEL (6)" beside an
      # identity built from 5 — two counts of one thing, on one screen, disagreeing.
      #
      # THE FLOOR WINS, because the source chip is the more trustworthy of the two
      # claims: "you added this" is a fact about a human, "a search found it" is a
      # fact about a machine, and both are true of this row.
      floor + persisted_rows.reject { |photo| seen.include?(photo.image_url) }
    end

    # The rows the operator is judging the SEARCH by. Split out because the page
    # counts them separately: "4 of 20 chosen" is the sentence, and the floor is
    # not part of either number.
    def persisted_rows
      return @persisted_rows if defined?(@persisted_rows)
      return @persisted_rows = [] if @appearance.nil?

      @persisted_rows =
        AppearanceReferencePhoto.where(appearance_slug: @appearance.slug).gallery_order.to_a
    end

    private

    # Memoised because #call and #gallery each ask for the floor, and on a look
    # with no search hits the floor IS the answer — re-deriving it would re-read
    # the athlete's ImageCache rows for no new information.
    def floor_urls
      @floor_urls ||= Array(ReferenceImages.call(@appearance))
    end

    # THE CHOSEN ROWS ONE GENERATOR MAY HAVE, in gallery order.
    #
    # `prefer_hosted` PICKS WHICH URL, NOT WHICH ROW. The eligibility question is always
    # asked of the row; only the answer's spelling changes — our mirrored copy for a
    # vendor whose bytes we fetch ourselves, the provider's URL for one that fetches them
    # server-side from wherever it likes.
    def offerable_urls(rule, prefer_hosted: false)
      rows = persisted_rows.select { |photo| photo.chosen? && offerable?(photo, rule) }
      return rows.map(&:image_url) unless prefer_hosted

      rows.map { |photo| photo.hosted_url.presence || photo.image_url }
    end

    # MAY THIS PERSISTED ROW BE HANDED TO THIS GENERATOR, judged by today's rules rather
    # than by the run that filed it. One predicate so every reader is provably answering
    # the same question — computed separately they drift, and the page then reports a
    # refusal that did not happen.
    def offerable?(photo, rule)
      FetchableUrl.ok?(photo.image_url) && photo.public_send(rule, person_name)
    end

    # THE NAME THE WRONG-PERSON CHECK IS AGAINST. Memoised because it is asked once per
    # row and the walk is two associations deep; `nil` is a real answer (a look whose
    # person record is gone) and Appearances::PersonNaming reads it as "no opinion
    # available" rather than as a mismatch.
    def person_name
      return @person_name if defined?(@person_name)

      @person_name = @appearance&.person&.full_name
    end

    # The headshot and the operator's URL, as unsaved rows so they render through
    # the same partial as everything else.
    #
    # DERIVED FROM THE FLOOR'S OWN ANSWER rather than re-read from the athlete and
    # the column, so the two can never disagree: whatever ReferenceImages offers
    # the vendor is exactly what the gallery labels as the floor. The consequence
    # worth knowing — an operator URL the SSRF guard refuses does not appear here,
    # because ReferenceImages already dropped it. That is correct for a gallery
    # whose job is "what the identity is built from", and it is the one candidate
    # the page cannot show you being rejected.
    def floor_rows
      operator_url = @appearance&.reference_url.presence

      floor_urls.map do |url|
        source = if url == operator_url
          AppearanceReferencePhoto::SOURCE_OPERATOR
        else
          AppearanceReferencePhoto::SOURCE_HEADSHOT
        end

        AppearanceReferencePhoto.new(
          slug: "#{FLOOR_SLUG_PREFIX}#{source}",
          appearance_slug: @appearance&.slug,
          image_url: url,
          source: source,
          chosen: true
        )
      end
    end
  end
end
