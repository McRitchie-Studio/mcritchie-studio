module Appearances
  # COPY EACH CANDIDATE INTO OUR OWN S3 BEFORE ANYTHING ELSE IS ASKED TO LOOK AT IT.
  #
  # THE BUG THIS EXISTS FOR, measured on production 2026-09-26 during the first real
  # scouting run (jaxon-smith-njigba). Every face score came back empty:
  #
  #   [Appearances::FaceVisibility] Anthropic answered 400:
  #     "Unable to download the file. Please verify the URL and try again."
  #
  # Against the exact URL that failed:
  #
  #   curl WITH a User-Agent  -> HTTP 200, image/png
  #   curl with NO User-Agent -> HTTP 403
  #
  # Wikimedia refuses a request that sends no User-Agent. It is not an outage and not
  # a bad URL — it is hotlink policy on the source host, and Anthropic's fetcher was
  # the party being refused.
  #
  # THE CONSEQUENCE WAS NOT A VISIBLE FAILURE, which is why the fix is here rather
  # than in a retry. The classifier degrades to an empty Hash by contract, so the run
  # continued with no face scores at all, ranking fell back to title-match and aspect
  # ratio, and six photographs went into the character model — three of them
  # AIRCRAFT. `9V-JSN` and `HB-JSN` are aircraft registration codes that happen to
  # share the athlete's initials. A silent degrade produced a confidently wrong
  # result and the operator read it off the page before we did.
  #
  # WHY MIRRORING RATHER THAN A USER-AGENT. We are not the party being refused. The
  # fetch happens on Anthropic's network from a `type: "url"` image source, so there
  # is no header of ours to set — the only move available is to stop handing a third
  # party's URL to a third party's fetcher. That fixes EVERY downstream consumer at
  # once instead of one vendor, and any source host may hotlink-protect.
  #
  # THE ASYMMETRY THIS EXPLAINS, and it is invisible until it bites: Higgsfield
  # fetches the same Wikimedia URLs SUCCESSFULLY (its `reference_media` comes back
  # with the images re-hosted on its own CDN), so today one consumer works and
  # another does not, from the same URL and with nothing in our code to tell them
  # apart.
  #
  # OUR OWN FETCHER IS NOT REFUSED, and that is the measurement the whole fix rests
  # on rather than an assumption. LiveCache.fetch (like ImageCache.fetch_remote) uses
  # `URI.open`, which sends Net::HTTP's default `User-Agent: Ruby`; measured against
  # the failing URL on 2026-09-26 it answered 200 with 222,045 bytes. A UA Wikimedia
  # accepts is all its policy asks for.
  #
  # ── WHAT IS MIRRORED, AND WHAT IS DELIBERATELY NOT ──────────────────────────────
  #
  # THE SHORTLIST ONLY (GatherReferencePhotos::VISION_SHORTLIST), not every
  # candidate the provider returned. The number is NOT repeated here: it moved from 12 to
  # 24 with the query fan-out, and a figure copied into prose beside a constant is a
  # figure that goes stale without failing anything. The choice, stated because the
  # cheaper option
  # gives something up:
  #
  #   * The shortlist IS the set handed to the classifier, so it is exactly the set
  #     that needs a URL we serve. Mirroring past it fixes nothing about this bug.
  #   * A reject OUTSIDE the shortlist was rejected by the FREE metadata score
  #     (Appearances::PhotoMerit — deterministic, no spend), so re-judging it later
  #     costs a re-derivation rather than money. A reject INSIDE the shortlist was
  #     judged by a PAID classifier, and every one of those is mirrored — so no
  #     judgement we paid for becomes unrepeatable.
  #   * It reuses the constant that already bounds the bill, so the fetch cost and
  #     the classifier cost scale together under one ceiling instead of the mirror
  #     scaling with however many results the provider felt like returning.
  #
  # ── WHY ImageCache IS THE MIRROR AND NOT THE RECORD ─────────────────────────────
  #
  # A previous builder rejected Studio::ImageCache as the home for REJECTED
  # candidates and was right: `ImageCache` validates presence of `s3_key`, so a
  # candidate we never uploaded could have no row at all, and it validates `variant`
  # unique per (owner, purpose), so twenty candidates cannot live under one
  # (appearance, "reference_photo"). That reasoning still stands and is respected
  # here — AppearanceReferencePhoto remains the record of every candidate, mirrored
  # or not, chosen or not.
  #
  # SO THE OWNER IS THE CANDIDATE ROW, not the look. One photograph, one owner, one
  # "original" variant: the uniqueness constraint is satisfied by construction rather
  # than worked around. It is the same shape Athlete and Coach already use
  # (`has_many :image_caches, as: :owner`), which is why the row gets a `hosted_url`
  # reader that reads like every other cached image in the app.
  #
  # `widths: []` ASKS FOR THE ORIGINAL AND NOTHING ELSE. A resized variant would buy
  # a second S3 object and a MiniMagick decode per candidate to serve a consumer that
  # wants the full frame — the classifier is judging how much of the frame the face
  # fills, and the page already has the archive's own thumbnail in `thumb_url`.
  #
  # DEGRADES, NEVER RAISES, per photograph. One dead candidate costs one photograph;
  # it must never cost the other eleven or the page. A candidate that could not be
  # mirrored is simply never classified, which the caller already reads as "nobody
  # looked" — the honest answer, and NOT the same as "looked and saw no face".
  #
  # A RESPONSE THAT IS NOT AN IMAGE is the one exception: it is refused before any
  # bytes are stored and filed as its own ErrorLog row naming the served content type.
  #
  # OTHERWISE IT DOES NOT FILE ITS OWN ErrorLog ROWS, and that is a judgement about noise
  # rather than an omission. A single S3 outage would file twelve identical rows and
  # bury the one fact worth reading. The caller knows how many it shortlisted and how
  # many came back, so it files ONE row naming both numbers when the lane went blind
  # (see GatherReferencePhotos#report_blind_classifier). Per-photograph failures warn
  # to the log, and the flash reports "n of m mirrored" so a partial failure is on
  # the page rather than only in a log nobody tails.
  class MirrorCandidates
    # THE ImageCache NAMESPACE for these copies. Distinct from "headshot" so the two
    # consumers can never collide on one owner, and so `rekey_headshots` — which
    # queries `purpose: "headshot"` — cannot reach them.
    PURPOSE = "reference_photo".freeze

    # The S3 key root. One folder per look, one file per candidate row, so an object
    # in the bucket names the look and the row it belongs to without a lookup.
    KEY_ROOT = "reference-photos".freeze

    # EXTENSION -> CONTENT TYPE, spelled out rather than inverted from the engine's
    # own EXT_BY_TYPE. That Hash maps type->ext and carries BOTH "image/jpeg" and the
    # nonstandard "image/jpg" onto "jpg", so `.invert` silently elects whichever came
    # last and it would have been "image/jpg". It also has no "jpeg" key at all,
    # which is the commoner spelling in a URL path. A test pins every value here
    # against Studio::ImageCache::ALLOWED_CONTENT_TYPES so the two cannot drift.
    CONTENT_TYPE_BY_EXTENSION = {
      "png" => "image/png",
      "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg",
      "webp" => "image/webp",
      "gif" => "image/gif"
    }.freeze

    # WHAT A SOURCE HOST MAY ANSWER WITH. Blank and generic binary types say nothing,
    # so the claims below decide; anything else must be an image type we can store.
    GENERIC_CONTENT_TYPES = ["", "application/octet-stream", "binary/octet-stream"].freeze

    # A source host answered with something that is not an image.
    class NotAnImage < StandardError; end

    # THE LIVE CACHE: our own fetch, so the response's Content-Type is read before the
    # bytes are handed to Studio::ImageCache as a local file.
    module LiveCache
      def self.fetch(url)
        require "open-uri"
        # FOLLOW-UP (needs the published gem, so it is not done here): this
        # checks the URL and then URI.open resolves the name AGAIN and follows
        # redirects unchecked. Move it to the engine's `vet_source_url!` +
        # `pinned_http`. /tasks/url-guard-off-hot-paths, epic
        # recast-video-pipeline piece 23. It asks the guard directly rather than
        # through Appearances::FetchableUrl, so it is one lookup per mirrored
        # photograph, in a job.
        Studio::ImageCache.validate_source_url!(url)
        URI.open(url, read_timeout: 30, redirect: true) do |io|
          body = io.read(Studio::ImageCache::MAX_REMOTE_BYTES + 1).to_s
          if body.bytesize > Studio::ImageCache::MAX_REMOTE_BYTES
            raise Studio::ImageCache::SourceTooLarge, "remote payload exceeds #{Studio::ImageCache::MAX_REMOTE_BYTES} bytes"
          end

          [body, io.content_type]
        end
      end

      def self.cache!(**) = Studio::ImageCache.cache!(**)
    end

    def self.call(photos, target: nil, cache: nil) = new(photos, target: target, cache: cache).call

    # `photos` are persisted AppearanceReferencePhoto rows — this object never writes
    # that table. GatherReferencePhotos stays its only writer, so the guard that
    # protects a headshot or operator row from being demoted by a search hit lives in
    # exactly one place and cannot be half-applied by a second author.
    #
    # `cache:` IS INJECTED so the suite can hand over something that neither fetches
    # nor uploads: it answers `fetch(url) -> [body, content_type]` and `cache!`. Unresolved and armed, the trap refuses rather than reaching out.
    def initialize(photos, target: nil, cache: nil)
      @photos = Array(photos)
      @target = target
      @cache = cache || default_cache
    end

    # Returns { remote_url => our_url } for the candidates it mirrored. A candidate
    # ABSENT from the Hash was not mirrored, and the caller must not fall back to its
    # remote URL — that is the bug.
    def call
      @photos.each_with_object({}) do |photo, hosted|
        next if photo.nil? || photo.image_url.blank?

        url = mirror(photo)
        hosted[photo.image_url] = url if url.present?
      end
    end

    private

    def default_cache
      LiveCallTrap.refuse!(
        what: "A live image fetch and S3 upload through #{self.class}",
        remedy: "Inject a cache: Appearances::MirrorCandidates.call(photos, cache: fake), " \
                "or inject the whole mirror at the caller's seam: " \
                "Appearances::GatherReferencePhotos.new(look, mirror: fake)."
      )
      LiveCache
    end

    def mirror(photo)
      # A copy we already hold is reused: re-fetching would let a dead source drop it.
      return photo.hosted_url if photo.mirrored?

      content_type = content_type_for(photo)
      return nil if content_type.nil?

      body, served = @cache.fetch(photo.image_url)
      refuse_unless_image!(photo, served)

      # `cache!` RETURNS A HASH KEYED BY VARIANT, both when it uploaded and when it
      # found the object already cached — it is idempotent per (owner, purpose,
      # variant), so a re-search re-uses the stored copy.
      variants = Tempfile.create(["mirror", ".bin"], binmode: true) do |file|
        file.write(body)
        file.flush
        @cache.cache!(owner: photo, purpose: PURPOSE, key_prefix: key_prefix(photo), widths: [],
                      source_url: photo.image_url, source_path: file.path, content_type: content_type)
      end
      variants["original"]&.url
    rescue NotAnImage => e
      Rails.logger.warn("[#{self.class}] refused: #{e.message}")
      FailureLog.file(e, target: @target)
      nil
    rescue StandardError => e
      Rails.logger.warn(
        "[#{self.class}] could not mirror #{photo.image_url}: #{e.class}: #{e.message}"
      )
      nil
    end

    def refuse_unless_image!(photo, served)
      type = served.to_s.split(";").first.to_s.strip.downcase
      return if GENERIC_CONTENT_TYPES.include?(type) || Studio::ImageCache::ALLOWED_CONTENT_TYPES.include?(type)

      raise NotAnImage, "#{photo.image_url} served #{type.inspect}, not an image we store"
    end

    def key_prefix(photo) = "#{KEY_ROOT}/#{photo.appearance_slug}/#{photo.slug}"

    # WHAT WE TELL S3 THE BYTES ARE: the archive's own `mime_type` first, then the
    # URL path's extension. NEITHER RESOLVES -> NO MIRROR, and the candidate goes
    # unclassified; guessing would put a wrong Content-Type on an object we serve.
    #
    # Both are claims ABOUT the bytes. The response's own Content-Type is checked
    # separately (#refuse_unless_image!): on 2026-09-27 a `.jpg` URL served
    # `text/html`, and an earlier comment here wrongly called that uncatchable.
    def content_type_for(photo)
      claimed = photo.mime_type.to_s.downcase.strip
      return claimed if Studio::ImageCache::ALLOWED_CONTENT_TYPES.include?(claimed)

      CONTENT_TYPE_BY_EXTENSION[extension(photo.image_url)]
    end

    # The path's extension, lowercased, with no dot. READ OFF THE PATH rather than
    # the whole URL so a `?format=png` query string cannot masquerade as one.
    def extension(url)
      File.extname(URI.parse(url.to_s).path.to_s).delete_prefix(".").downcase
    rescue URI::InvalidURIError
      ""
    end
  end
end
