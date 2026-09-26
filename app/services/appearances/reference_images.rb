module Appearances
  # THE PHOTOS A CHARACTER IDENTITY IS BUILT FROM — today's floor, and the seam
  # the richer version plugs into.
  #
  # Higgsfield's create takes a LIST of reference images, and the quality of the
  # identity is the quality of that list: a detailed character sheet wants a
  # head-on shot, a profile, a back view and a few expressions. We have one of
  # those today — the cached ESPN headshot — and one is the API's minimum, so
  # the lane is buildable and testable now.
  #
  # THAT IS WHY THIS IS A SEPARATE OBJECT rather than a `headshot_url` call
  # inside the create service. The list is the part that will change: an
  # image-search step will supply the profile and the expressions once there is
  # a credential for one. Whoever builds it writes a new callable with the same
  # one-method shape and injects it —
  # `Appearances::CreateCharacterReference.new(look, references: ImageSearch)` —
  # and nothing else in the lane moves. A hardcoded lookup would have made that
  # a rewrite of the create service instead.
  #
  # THE CONTRACT, so a replacement can be written against it rather than against
  # this file: `.call(appearance)` returns an Array of absolute http(s) URLs,
  # ordered most-authoritative first, de-duplicated, possibly empty. The caller
  # treats empty as a refusal to build, never as "build it from nothing".
  #
  # EVERY URL MUST BE FETCHABLE BY HIGGSFIELD, not by us. They pull the bytes
  # server-side. Verified 2026-09-24 that the cached headshots satisfy this: a
  # real object
  # (`headshots/nfl/buffalo-bills/alec-anderson/400.png`) answers 200 to an
  # unauthenticated `curl -sI`, Studio::S3#url builds a plain virtual-host URL
  # with no signature, and Higgsfield's own read of the created reference came
  # back with the image re-hosted on their CDN — which only happens if their
  # fetch succeeded.
  class ReferenceImages
    HEADSHOT_PURPOSE = "headshot".freeze

    # Widest first. The identity is built from what the model can see, and a
    # 100px crop of a face carries less of it than a 400px one. The list is a
    # PREFERENCE, not a requirement — a variant we never cached is skipped.
    HEADSHOT_VARIANTS = %w[400 100].freeze

    def self.call(appearance) = new(appearance).call

    def initialize(appearance)
      @appearance = appearance
    end

    # ORDER: the cached headshot leads, the operator's URL follows.
    #
    # Not an arbitrary choice and not a judgement about which photo is better.
    # The headshot is the one URL whose public reachability we CONTROL and have
    # measured; `reference_url` is free text the operator typed into a form and
    # could point anywhere, including somewhere Higgsfield cannot reach. Leading
    # with the measured one means the first image in every list is one we can
    # vouch for.
    def call
      [headshot_url, operator_reference_url].compact_blank.uniq.select { |url| fetchable?(url) }
    end

    private

    # THE FIRST READER `appearances.reference_url` HAS EVER HAD.
    #
    # The column has been written by the look form since it was created and read
    # by nothing (measured 2026-09-24: `permit` in people_controller, a
    # `url_field` in people/show, and the schema — no consumer). The operator has
    # been recording a reference photo into a hole. This is the hole's bottom:
    # when they name one, it joins the identity.
    def operator_reference_url = @appearance&.reference_url

    # The cached ESPN headshot, via the athlete record hanging off the person.
    # Nothing here reaches ESPN — Nflverse::SeedPlayers already mirrored the
    # image into our own S3 (`Studio::ImageCache`, purpose "headshot", variants
    # 100/400), and it is OUR copy we hand out, so the identity does not depend
    # on a third party's hotlinking policy.
    def headshot_url
      athlete = @appearance&.person&.athlete_profile
      return nil if athlete.nil?

      HEADSHOT_VARIANTS.filter_map { |width| athlete.headshot_url(width: width) }.first
    end

    # A URL WE WOULD NOT HAND A REMOTE FETCHER. The API url-validates the field
    # (422 `url_parsing` on a relative URL, measured 2026-09-24), so a malformed
    # entry costs a paid round-trip; worse, a `localhost` or private-range URL
    # from the operator's form would be asking someone else's server to probe our
    # network.
    #
    # THE JUDGEMENT ITSELF MOVED TO Appearances::FetchableUrl once the image
    # search gained the same question about URLs a third party handed us — and
    # those are the more dangerous of the two, because nobody looked at them. One
    # opinion, two callers; this delegates rather than keeping a private copy that
    # would drift the day the engine tightens its ranges.
    def fetchable?(url) = FetchableUrl.ok?(url)
  end
end
