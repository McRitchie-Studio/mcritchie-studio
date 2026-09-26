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

    def self.call(appearance) = new(appearance).call

    def initialize(appearance)
      @appearance = appearance
    end

    # THE MINT PATH'S LIST. Floor first, then the chosen search hits.
    #
    # `FetchableUrl` runs over the search hits AGAIN here, although
    # GatherReferencePhotos already refused the unsafe ones at file time. That is
    # not belt-and-braces for its own sake: rows outlive the rule that judged them,
    # so a tightening of the engine's SSRF ranges would otherwise be applied only
    # to photographs found AFTER the change, and a year-old row would keep being
    # handed to a remote fetcher under a rule nobody holds any more. The check is
    # free and it is the one that runs immediately before we spend money.
    def call
      (floor_urls + chosen_search_urls).uniq
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

    def chosen_search_urls
      persisted_rows.select { |photo| photo.chosen? && FetchableUrl.ok?(photo.image_url) }
                    .map(&:image_url)
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
