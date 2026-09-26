module Appearances
  # ONE OPINION ABOUT WHICH URLs WE WILL HAND A REMOTE FETCHER.
  #
  # Extracted because there are now two callers with the same question and every
  # reason to answer it identically. Appearances::ReferenceImages asks it of the
  # URL the operator typed; Appearances::GatherReferencePhotos asks it of URLs a
  # third-party search engine handed us — which is the more dangerous of the two,
  # because nobody looked at them.
  #
  # WHAT THE QUESTION ACTUALLY IS, and it is not "is this a valid URL". Higgsfield
  # pulls these bytes SERVER-SIDE, from their network. A `localhost` or
  # private-range URL reaching them is us asking someone else's infrastructure to
  # probe its own; a malformed one costs a paid 422 (`url_parsing`, measured
  # 2026-09-24). Both are refused here, for free, before anything is sent.
  #
  # IT DELEGATES RATHER THAN DECIDES. Studio::ImageCache.validate_source_url! is
  # the engine's SSRF guard and already encodes this judgement for the fetches WE
  # make — scheme allow-list, internal-hostname blocklist, loopback/private/
  # link-local/metadata IP ranges. A second opinion living here would be a second
  # thing to keep in step with it, and the day the engine tightens its ranges the
  # copy would silently keep letting the old ones through.
  #
  # ITS LIMIT, stated because a reader will otherwise assume more: the engine's
  # own comment notes this does NOT defend against DNS rebinding, which needs the
  # resolved IP pinned and handed to the HTTP client. We do not fetch these bytes
  # at all — Higgsfield does — so that hardening is theirs to have, not ours to
  # fake.
  module FetchableUrl
    # True when this URL is one we would hand a remote fetcher. Never raises: a
    # candidate list is filtered, not aborted, and one bad URL among twenty must
    # not lose the other nineteen.
    def self.ok?(url)
      return false if url.blank?

      Studio::ImageCache.validate_source_url!(url)
      true
    rescue Studio::ImageCache::InvalidSourceURL, URI::InvalidURIError
      false
    end
  end
end
