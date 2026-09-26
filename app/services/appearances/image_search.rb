module Appearances
  # WHERE REFERENCE PHOTOGRAPHS COME FROM — the façade, and the registry of
  # providers behind it.
  #
  # ONE PHOTOGRAPH IS THE FLOOR AND IT IS NOT ENOUGH. Appearances::ReferenceImages
  # can offer the cached ESPN headshot and whatever URL the operator typed, and
  # Higgsfield accepts a list of one. But the goal this lane is aimed at is a
  # character sheet — full body, head-on, back, side profile, plus expressions —
  # and an identity built from a single 400px crop of a face cannot carry that.
  # This is the step that finds the rest.
  #
  # THE PROVIDER IS AN INTERFACE, not a vendor name spelled through the codebase.
  # A provider is any object answering three messages:
  #
  #   .provider_name  => String, stable, stored on every photograph it finds.
  #   .available?     => Boolean. Can this provider run RIGHT NOW?
  #   .search(query:, limit:) => Appearances::ImageSearch::Answer
  #
  # `available?` IS THE PROVIDER'S OWN QUESTION, asked of the provider, and that
  # is the load-bearing design choice in this file. The obvious shape — the façade
  # checking `ENV["SERPER_API_KEY"]` before dispatching — bakes "every provider is
  # authenticated" into the layer above the providers, and the first provider that
  # needs no credential (Wikimedia Commons answers image queries with no key at
  # all) then has to fight the façade to be usable. So the façade asks; a keyless
  # provider answers `true` unconditionally and nothing above it changes.
  #
  # NOTHING HERE TOUCHES THE MINT PATH. Appearances::CreateCharacterReference
  # takes its photograph list as an injected `references:` collaborator, so this
  # whole file reaches the identity through Appearances::ReferenceSet and the
  # create service does not know it exists.
  #
  # TWO PROVIDERS SHIP, and the SECOND one is what makes this lane usable at all.
  #
  #   Serper       serper.dev, general image search. PAID, and its response shape
  #                is still UNVERIFIED — no credential has ever existed, so its
  #                parser reads one field and guesses the rest.
  #   Wikimedia    commons.wikimedia.org. KEYLESS, and its shape was MEASURED
  #     Commons    against a live 200 on 2026-09-26.
  #
  # THIS FILE ONCE ARGUED FOR EXACTLY ONE, and the argument is worth preserving
  # because it was right at the time and is instructive about when it stops being
  # right. It ran: a second provider means a second parser written against a shape
  # nobody has seen, doubling the guessed surface with no credential to measure
  # either half against. That holds while both providers are unmeasured and one of
  # them works. It collapsed on two facts — `SERPER_API_KEY` was never bought, so
  # `available?` was false on every machine and the operator's Search button never
  # rendered anywhere; and the keyless provider's shape can be measured for free, by
  # anyone, at any time. A provider that needs no credential does not double the
  # guess; it removes the guess from the only path that runs.
  #
  # THE SEAM COST WHAT IT PROMISED. The registry, the `available?` protocol and the
  # keyless fake in test/services/appearances/image_search_test.rb were built so the
  # second provider would be "a file and a line". It was: one provider file, one name
  # added to `providers`, and nothing above it changed.
  module ImageSearch
    # ONE NORMALISED SEARCH HIT. Providers return these rather than their own
    # payload shapes, so the picker, the persistence and the gallery are written
    # against one thing and a new provider cannot change what they read.
    #
    # `image_url` is the only required member. Everything else is optional BY
    # DESIGN and not merely by convenience: the Serper response shape could not be
    # measured (no credential existed), so a provider that omits `width`, `title`
    # or `page_url` must still yield a usable photograph rather than lose it.
    #
    # `mime` IS REPORTED, NOT ACTED ON — and that split is deliberate. It is the
    # cheapest honest answer to "is this a photograph at all": Wikimedia Commons
    # volunteers `application/pdf` and `image/vnd.djvu` on the scanned books it
    # returns, which is the same judgement PhotoMerit::DOCUMENT_MARKERS reaches by
    # sniffing a file extension out of a URL. The calibration page PRINTS it so the
    # operator can see the archive admit what a row is. Nothing ranks on it yet:
    # folding a new signal into the ranking belongs to the task that owns the
    # ranking defects (`reference-photos-wrong-person`), not to the page that
    # exposes them. Providers that cannot report it leave it nil.
    #
    # `thumb_url` IS FOR THE BROWSER, `image_url` IS FOR THE VENDOR. A gallery of
    # twenty full-size originals is how a page earns an HTTP 429 from the archive
    # (measured 2026-09-26 on Commons: the third original onward answered 429 and
    # rendered as grey alt-text). Providers that offer no small rendition leave it nil
    # and every reader falls back to `image_url`.
    Result = Struct.new(:image_url, :page_url, :title, :width, :height, :position,
                        :mime, :thumb_url, keyword_init: true)

    # WHAT A SEARCH ANSWERS WITH — the results AND how many rows we could not read.
    #
    # The count is here rather than in a log line alone because a silent zero and
    # a silent parse failure are the same empty list, and only one of them is a
    # bug in our code. The operator's page prints it, so "serper returned 20 and
    # we understood 0" is visible in the place where it can be acted on instead of
    # sitting in a log nobody tails.
    Answer = Struct.new(:results, :unparsed_count, :provider_name, keyword_init: true) do
      def self.empty(provider_name: nil)
        new(results: [], unparsed_count: 0, provider_name: provider_name)
      end

      # NIL-TOLERANT READERS. A provider built by hand in a test, or one that
      # forgets a member, must not make the caller's `.length` raise — and
      # `Struct#any?` is deliberately NOT overridden here: it means "any non-nil
      # MEMBER" on a Struct, so a reader who expected "any results" would have got
      # `true` from an empty answer that merely carries a provider name.
      def results = (self[:results] || [])
      def unparsed_count = (self[:unparsed_count] || 0)
    end

    # THE REGISTRY. Ordered: the first AVAILABLE provider serves the query.
    #
    # An ordered list rather than a Hash keyed by name, because the order IS the
    # preference and a Hash's order is an accident of insertion that nobody
    # reading it would know to rely on.
    #
    # A METHOD RATHER THAN A FROZEN CONSTANT for two reasons. It keeps the
    # provider classes out of this file's load-time graph — a constant here would
    # make loading the façade load every provider, and a provider that ever
    # referenced the façade back would deadlock Zeitwerk. And it gives the suite a
    # seam: a test hands this a keyless fake to prove the `available?` protocol
    # does not assume a credential, which a frozen constant would need
    # constant-surgery to reach.
    # THE ORDER IS THE PREFERENCE, AND IT IS PAID-FIRST-THEN-FLOOR.
    #
    # Serper leads because a bought key means somebody chose a general image search
    # over a free-licence media archive, and the façade serves the first AVAILABLE
    # provider — so listing WikimediaCommons first would make that purchase
    # unreachable forever. Commons answers `available?` unconditionally, which makes
    # it a FLOOR rather than a preference: it serves whenever nothing better is
    # configured, which today is everywhere.
    #
    # ⚠ `available?` IS NOW TRUE ON EVERY MACHINE, and that is a behaviour change to
    # be aware of rather than a detail. Before this provider existed the whole
    # unconfigured path — no Search button, "web image search is off" — was the one
    # that ran in production and on every desk. It is now unreachable in practice and
    # is kept, with its tests, because an empty registry and a provider list that all
    # answer false are still states this façade must render rather than raise on.
    def self.providers = [Serper, WikimediaCommons]

    # HOW MANY CANDIDATES TO ASK FOR. Generous on purpose: this is the number the
    # operator JUDGES the search by, and a short list hides a bad search behind
    # luck. Asking for twenty and building the identity from a handful costs one
    # query either way — providers charge per QUERY, not per result.
    DEFAULT_LIMIT = 20

    # THE PROVIDER THAT WOULD SERVE A QUERY RIGHT NOW, or nil.
    #
    # nil IS A NORMAL ANSWER, not an error, and the whole unconfigured path rests
    # on that: with no credential on the machine the page must still render, from
    # the headshot floor, with an honest note about why the gallery is thin. An
    # exception here would turn "we have not bought a search key yet" into a 500
    # on a page whose only job is to show the operator what we have.
    def self.provider
      providers.find(&:available?)
    end

    def self.available? = provider.present?

    # THE NAME STORED ON EVERY PHOTOGRAPH A SEARCH FINDS, or nil when nothing is
    # configured.
    def self.provider_name = provider&.provider_name

    # RUN ONE QUERY. Returns an EMPTY ANSWER when nothing is configured — the same
    # empty answer a configured provider gives when it finds nothing, because the
    # caller's behaviour is identical in both cases and only the PAGE needs to
    # tell them apart (which it does, through .available?).
    #
    # A PROVIDER THAT RAISES IS CAUGHT rather than propagated. A search is an
    # optional enrichment of a list that already has a floor; a provider outage
    # must cost the operator some photographs, never the page.
    #
    # CAUGHT IS NOT SWALLOWED, and that distinction is the whole reason `target:`
    # exists on this method. An empty Answer is what a provider ALSO returns when it
    # searched fine and found nothing, so on the page a 401 and an empty result read
    # as the same sentence — "returned nothing" — and the operator spends an
    # afternoon looking for a photograph problem they do not have. The row in
    # /admin/error_logs is what tells those two apart, and `target:` is what names
    # the look it happened on.
    #
    # `target:` IS OPTIONAL because this façade is reachable from a console and a
    # rake task, where there may be no record to file it against. A row with no
    # target is still a row; `ErrorLog.capture!` stamps its own slug, so it is still
    # reachable in the admin list.
    def self.search(query:, limit: DEFAULT_LIMIT, target: nil)
      chosen = provider
      return Answer.empty if chosen.nil?

      answer = chosen.search(query: query, limit: limit)
      return Answer.empty(provider_name: chosen.provider_name) if answer.nil?

      answer
    rescue StandardError => e
      Rails.logger.warn(
        "[Appearances::ImageSearch] #{chosen&.provider_name} failed: #{e.class}: #{e.message}"
      )
      Appearances::FailureLog.file(e, target: target)
      Answer.empty(provider_name: chosen&.provider_name)
    end
  end
end
