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
  # make. A second opinion living here would be a second thing to keep in step
  # with it, and the day the engine tightens its ranges the copy would silently
  # keep letting the old ones through.
  #
  # WHAT THE GUARD CHECKS DEPENDS ON THE ENGINE THE HUB LOCKS, and this module
  # runs on both:
  #
  #   The engine locked when this was written (0.94.0) reads the URL's TEXT and
  #   resolves nothing: http or https, a few internal host names, and dotted
  #   IPv4 or bracketed IPv6 literals in the loopback, private and link-local
  #   ranges. A public name that points at a private address passes, and so
  #   does a loopback written `127.1` or as an integer.
  #
  #   The next engine (studio-engine PR 436) also decodes every spelling of an
  #   address and LOOKS THE NAME UP: every A and AAAA record, refused if any
  #   one is non-public. A name that cannot be looked up raises
  #   Studio::ImageCache::UnresolvedSourceHost. The lookup is uncached, two
  #   seconds an attempt and up to six for a name that never answers. It does
  #   none of this under a Rails test environment.
  #
  # So a judgement here may be a DNS lookup, and everything below the first two
  # methods exists to keep that off the hot paths: one lookup per host per
  # request, a budget per web request, and "could not look it up" kept apart
  # from "not a public address".
  #
  # ITS LIMIT ON EITHER ENGINE: the answer is true when it is given. A name can
  # point somewhere else a moment later (DNS rebinding), and closing that needs
  # the vetted address handed to the HTTP client. Most of these bytes are
  # fetched by Higgsfield, not by us, so that hardening is theirs to have. The
  # two fetches the hub makes itself by name are named in FOLLOW-UP below.
  #
  # FOLLOW-UP (needs the published gem, so it is not done here): move
  # Appearances::MirrorCandidates::LiveCache.fetch and
  # MusicVideos::AssetZip::Fetcher#remote to the engine's `vet_source_url!` +
  # `pinned_http`, so each connects to the address that was vetted.
  # /tasks/url-guard-off-hot-paths, epic recast-video-pipeline piece 23.
  module FetchableUrl
    OK = :ok                 # hand it to a fetcher
    REFUSED = :refused       # not a public http(s) address, on its text or where it points
    UNRESOLVED = :unresolved # the name could not be looked up; nothing is known about it

    # Named, never referenced: the class exists only on the next engine.
    UNRESOLVED_ERROR = "Studio::ImageCache::UnresolvedSourceHost".freeze

    # Seconds a remembered verdict may be reused where no request or job ends to
    # clear it: a console, a rake task, one long job, a streaming download.
    MEMO_TTL = 60

    # Seconds of lookups one web request may spend (ApplicationController sets
    # it). Past it, a name not yet asked about is answered UNRESOLVED unasked.
    # The lookup in flight when the budget is crossed still finishes, so the
    # ceiling is this plus one lookup: 10 + 6 = 16 seconds, under Heroku's 30.
    REQUEST_LOOKUP_BUDGET = 10

    # THE MEMO, AND ITS LIFETIME. Rails resets CurrentAttributes when a request
    # or a job ends, so a verdict never crosses from one to the next. It is not
    # a process-wide cache on purpose: DNS answers change, and a stale "ok" is
    # exactly the thing the guard exists to prevent.
    class Memo < ActiveSupport::CurrentAttributes
      # verdicts: { host => [verdict, clock] } · left_out: Set of [look, what, host]
      attribute :verdicts, :left_out, :budget, :spent, :budget_logged
    end

    # True when this URL is one we would hand a remote fetcher. Never raises: a
    # candidate list is filtered, not aborted, and one bad URL among twenty must
    # not lose the other nineteen.
    def self.ok?(url) = verdict(url) == OK

    # OK, REFUSED or UNRESOLVED. Never raises.
    #
    # REMEMBERED PER HOST, because on both engines the guard's answer for an
    # http or https URL depends on the host and nothing else (not the path, the
    # port or the query). Any other scheme is refused on its text before a
    # lookup, so it goes straight to the guard and is never remembered: an ok
    # host must not clear `ftp://` on the same name.
    def self.verdict(url)
      return REFUSED if url.blank?

      uri = URI.parse(url.to_s)
      host = uri.host.to_s.downcase
      return judge(url) unless %w[http https].include?(uri.scheme) && host.present?

      remembered(host) { |text_only = false| judge(url, text_only: text_only) }
    rescue URI::InvalidURIError
      REFUSED
    end

    # What an operator is told when `https_verdict` refuses, and when it could
    # not look the host up. Two sentences because they ask for two different
    # things: fix the address, or try again.
    HTTPS_REFUSAL = "Image not attached: the address must be an https:// URL on a public host.".freeze
    HTTPS_UNCHECKED = "Image not attached: the address's host could not be looked up just now, so it was " \
                      "not checked. Confirm the host name, or try again in a moment.".freeze

    # THE STRICTER QUESTION: will we FILE this URL as a picture of someone?
    #
    # `ok?` answers for a URL a remote fetcher pulls once. A filed image URL is
    # also rendered into an operator's page and handed out as a swap reference,
    # so on top of `ok?` it must be https: plain http is refused, as is anything
    # with no scheme (a relative path, `//host/x`). Never raises.
    #
    # ITS LIMITS ARE `verdict`'s, and so they are the locked engine's (see the
    # head of this module). On the engine that resolves nothing, a public name
    # pointing at a private address passes and `127.1` is not recognised; on the
    # next one both are refused. On neither is a redirect the address later
    # serves followed or checked here.
    def self.https?(url) = https_verdict(url) == OK

    # OK, REFUSED or UNRESOLVED for the stricter question. The scheme is read
    # first, so plain http is refused without a lookup.
    def self.https_verdict(url)
      return REFUSED if url.blank?
      return REFUSED unless URI.parse(url.to_s).scheme.to_s.casecmp?("https")

      verdict(url)
    rescue URI::InvalidURIError
      REFUSED
    end

    # `ok?` FOR A PHOTOGRAPH A LOOK IS BUILT FROM, which must not vanish
    # silently. When the host could not be looked up the photograph is still
    # left out (nothing is known about where it points), and one warn line per
    # look, role and host says so. The line names the host only: a signed URL's
    # path and query are credentials.
    def self.ok_for?(url, look:, what:)
      answer = verdict(url)
      note_left_out(url, look: look, what: what) if answer == UNRESOLVED
      answer == OK
    end

    # [[what, host]] left out of this look in this request because the host
    # could not be looked up. What the look page reads to say so.
    def self.left_out(look:)
      Array(Memo.left_out).select { |noted, _what, _host| noted == look }.map { |_look, what, host| [what, host] }
    end

    # Give this request (or job) a lookup budget, in seconds.
    def self.limit_lookups(seconds = REQUEST_LOOKUP_BUDGET)
      Memo.budget = seconds
    end

    # A monotonic clock, as a method so a test can move it.
    def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def self.remembered(host)
      verdicts = (Memo.verdicts ||= {})
      answer, at = verdicts[host]
      return answer if answer && clock - at < MEMO_TTL
      return over_budget(host) { yield(true) } if Memo.budget && Memo.spent.to_f >= Memo.budget

      started = clock
      answer = yield
      now = clock
      Memo.spent = Memo.spent.to_f + (now - started)
      verdicts[host] = [answer, now]
      answer
    end
    private_class_method :remembered

    # THE BUDGET IS SPENT. The URL's text is still judged, which costs nothing, so
    # `https://127.0.0.1/` stays REFUSED; a name that passes on its text is
    # UNRESOLVED, because where it points was never asked. Not remembered: the
    # answer is the budget's, not the host's.
    def self.over_budget(host)
      unless Memo.budget_logged
        Memo.budget_logged = true
        Rails.logger.warn("[fetchable_url] lookup budget of #{Memo.budget}s spent in this request; " \
                          "host #{host} and any name after it are answered as not looked up")
      end
      yield == OK ? UNRESOLVED : REFUSED
    end
    private_class_method :over_budget

    # `text_only` asks the next engine to skip the lookup (`resolver: nil`). The
    # engine locked today takes no such keyword and never looks anything up, so
    # its ArgumentError falls back to the plain call. InvalidSourceURL is itself
    # an ArgumentError, hence the order of the rescues.
    def self.judge(url, text_only: false)
      begin
        text_only ? Studio::ImageCache.validate_source_url!(url, resolver: nil) : Studio::ImageCache.validate_source_url!(url)
      rescue Studio::ImageCache::InvalidSourceURL
        raise
      rescue ArgumentError
        raise unless text_only

        Studio::ImageCache.validate_source_url!(url)
      end
      OK
    rescue Studio::ImageCache::InvalidSourceURL => e
      unresolved_error?(e) ? UNRESOLVED : REFUSED
    rescue URI::InvalidURIError
      REFUSED
    end
    private_class_method :judge

    # The next engine's class, looked up by name each time: on the engine
    # locked today it does not exist, and every refusal is REFUSED.
    def self.unresolved_error?(error)
      unresolved = UNRESOLVED_ERROR.safe_constantize
      !unresolved.nil? && error.is_a?(unresolved)
    end
    private_class_method :unresolved_error?

    def self.note_left_out(url, look:, what:)
      host = URI.parse(url.to_s).host.to_s.downcase
      return unless (Memo.left_out ||= Set.new).add?([look, what, host])

      Rails.logger.warn("[fetchable_url] #{what} left out of look #{look || 'unknown'}: " \
                        "host #{host} could not be looked up")
    rescue URI::InvalidURIError
      nil
    end
    private_class_method :note_left_out
  end
end
