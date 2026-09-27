require "open-uri"

module Athletes
  # A DEAD SOURCE IS NOT A BROKEN UPLOADER. `nfl:upload_headshots` fetches an
  # ESPN headshot and puts it in S3, and those are two different parties: a 404
  # from a.espncdn.com is a fact about ESPN, and a failed `put_object` is a fact
  # about us. Only the second one is the lane not working, and only the second
  # one may redden a rebuild.
  #
  # ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────────
  #
  # The task counted both through one bare `rescue => e` into one `failed`
  # counter, and then graded itself on that counter. MEASURED ON PRODUCTION
  # 2026-09-27, read-only:
  #
  #     TOTAL=2051  WITH_ESPN_ID=2048  COMPLETE_CANDIDATES=2043
  #     FETCHABLE=5  SOURCELESS_CANDIDATES=0
  #
  # Production's ENTIRE fetchable population is five athletes, all five carry an
  # `espn_headshot_url`, and all five of those URLs answer 404. So the healthy
  # steady-state run is `cached: 0, failed: 5`, the rule `failed > cached` fires,
  # and the abort's first named cause is "usually AWS credentials: check
  # AWS_ACCESS_KEY_ID..." — credentials that are fine. That is a red rebuild on a
  # healthy run pointing at the wrong thing, which is how an operator learns to
  # stop reading the line.
  #
  # ── WHY IT READS THE EXCEPTION AND NOT A COUNT ───────────────────────────────
  #
  # Asked of the exception object, at the point the difference is KNOWN, rather
  # than derived by subtraction afterwards. A subtraction cannot tell "the source
  # was gone" from "the upload broke"; the exception can, and it is the only thing
  # that can. `Studio::ImageCache.cache!` raises on every path it takes once it
  # decides work is missing — the remote fetch, `Studio::S3.upload`, and
  # `ImageCache.create!` — so the exception class is always available and always
  # discriminating. Its one quiet return is the idempotence short-circuit, which
  # the caller's completeness gate excludes before it ever calls.
  #
  # ── WHY THE LIST IS 404 AND 410 AND NOTHING ELSE ─────────────────────────────
  #
  # 404 is MEASURED: production's five residue URLs were fetched the way the app
  # fetches them, `URI.open(url, read_timeout: 30, redirect: true)`, and every one
  # answered `["404", "Not Found"]` while a control espn_id answered 230,577
  # bytes through the same call. `curl` agreeing proves nothing about what Ruby
  # sees, so it was asked in Ruby.
  #
  # 410 is NOT measured — it is here on the protocol's word, because it says the
  # same thing 404 says only more definitely, and a CDN that starts answering
  # "Gone" for a retired photo must not resurrect the false abort.
  #
  # EVERYTHING ELSE FAILS SAFE INTO `failed`, deliberately, and that includes a
  # 5xx and a 403. A sustained 503 from ESPN really is a run that did not do its
  # work, and it is TRANSIENT, so a red that clears on the next run is honest; a
  # 403 is as likely to be us being blocked as ESPN being empty. The caller's job
  # is then to name the cause in the verdict rather than to guess at credentials
  # — which it now does.
  module DeadHeadshotSource
    # The statuses that mean "there is nothing at this URL and there will not be".
    DEAD_STATUSES = [404, 410].freeze

    # The HTTP status the SOURCE answered with, or nil when this error is not a
    # source answering at all.
    #
    # READ OFF `io.status`, NEVER OFF THE MESSAGE. open-uri builds the message
    # from the same status, so parsing it would be a second spelling of one fact,
    # and a proxy is free to reword a reason phrase while the status line is the
    # protocol. When the status cannot be read the answer is nil, which the
    # predicate below turns into "not dead" — the safe direction, because the
    # cost of a wrong nil is a red run an operator investigates and the cost of a
    # wrong status is a real upload failure nobody is told about.
    def self.status(error)
      return nil unless error.is_a?(OpenURI::HTTPError)
      return nil unless error.respond_to?(:io) && error.io.respond_to?(:status)

      Integer(Array(error.io.status).first.to_s, exception: false)
    end

    # True when the source said the photo is not there. False for every other
    # exception the upload path can raise, including the ones that ARE ours.
    def self.dead?(error)
      DEAD_STATUSES.include?(status(error))
    end
  end
end
