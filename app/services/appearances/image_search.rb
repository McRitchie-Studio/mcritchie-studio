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
  # ONLY ONE PROVIDER SHIPS TODAY, and that is a decision rather than an
  # oversight. Serper.dev was chosen for the first implementation; a second
  # provider would mean a second parser written against a shape nobody has seen
  # (read that provider's header for what "unverified" means here), doubling the
  # guessed surface with no credential to measure either half against. The
  # registry, the `available?` protocol, and the keyless fake in
  # test/services/appearances/image_search_test.rb exist so the second provider is
  # a file and a line rather than a refactor.
  module ImageSearch
    # ONE NORMALISED SEARCH HIT. Providers return these rather than their own
    # payload shapes, so the picker, the persistence and the gallery are written
    # against one thing and a new provider cannot change what they read.
    #
    # `image_url` is the only required member. Everything else is optional BY
    # DESIGN and not merely by convenience: the Serper response shape could not be
    # measured (no credential existed), so a provider that omits `width`, `title`
    # or `page_url` must still yield a usable photograph rather than lose it.
    Result = Struct.new(:image_url, :page_url, :title, :width, :height, :position,
                        keyword_init: true)

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
    def self.providers = [Serper]

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
    def self.search(query:, limit: DEFAULT_LIMIT)
      chosen = provider
      return Answer.empty if chosen.nil?

      answer = chosen.search(query: query, limit: limit)
      return Answer.empty(provider_name: chosen.provider_name) if answer.nil?

      answer
    rescue StandardError => e
      Rails.logger.warn(
        "[Appearances::ImageSearch] #{chosen&.provider_name} failed: #{e.class}: #{e.message}"
      )
      Answer.empty(provider_name: chosen&.provider_name)
    end
  end
end
