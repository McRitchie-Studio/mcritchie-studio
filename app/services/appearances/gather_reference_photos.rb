module Appearances
  # FIND PHOTOGRAPHS OF ONE PERSON AND FILE EVERY CANDIDATE — chosen or not.
  #
  # This is the write half of the page: one query out, a row per candidate back,
  # and a verdict recorded against each. The read half (Appearances::ReferenceSet)
  # then offers only the chosen ones to the mint path, so the gallery and the
  # identity can never disagree about what the identity was built from.
  #
  # WHY THE REJECTS ARE KEPT. The operator's question is not "did it mint?" — it
  # is "is the search any good?", and that cannot be answered from the winners. A
  # search returning twenty stock-photo watermarks and one usable portrait yields
  # the same single chosen photograph as a search returning twenty good portraits
  # we capped at one. Filing the rejects with their reasons is what makes those two
  # distinguishable on a page, and they cost a text row each.
  #
  # IT SPENDS MONEY. Providers charge per QUERY, so every call to this object is a
  # purchase. That is why nothing schedules it: it runs from an operator's click
  # and from a rake task, never from a callback, a sweep, or a page render.
  #
  # NO KEY IS NOT AN ERROR. With no provider configured this files nothing, reports
  # `configured: false`, and leaves the look exactly as it was — the headshot floor
  # still stands and the page still renders. The unconfigured path is the one that
  # runs today, so it is the one that has to look finished.
  class GatherReferencePhotos
    # HOW MANY PHOTOGRAPHS AN IDENTITY IS BUILT FROM.
    #
    # Higgsfield's minimum is 1 and it names no maximum. This cap is ours, and it
    # is about the IDENTITY rather than about the API: past a handful, extra
    # photographs of the same face stop adding information and start adding
    # whatever the search got wrong. Everything past the cap is filed
    # `beyond_limit` rather than dropped, so raising the cap later is a re-pick
    # rather than a re-search — and a re-search is another purchase.
    CHOSEN_LIMIT = 6

    Summary = Struct.new(:configured, :provider_name, :query, :returned, :filed,
                         :chosen, :rejected, :unfetchable, :unparsed, keyword_init: true) do
      def configured? = !!self[:configured]
    end

    def self.call(appearance, **kwargs) = new(appearance, **kwargs).call

    # `search:` is injected for the same reason Appearances::CreateCharacterReference
    # injects its client: every real call costs money, so the suite must be able to
    # hand this object something that cannot reach the network. It defaults to the
    # façade, never to a concrete provider — this object must not know which vendor
    # is serving.
    def initialize(appearance, search: ImageSearch, limit: ImageSearch::DEFAULT_LIMIT)
      @appearance = appearance
      @search = search
      @limit = limit
    end

    def call
      return unconfigured_summary unless @search.available?

      answer = @search.search(query: query, limit: @limit)
      file(answer)
    end

    # WHAT WE ASK THE INTERNET FOR. The person's name, plus the team when we know
    # it, because "Drew Lock" alone collects a locksmith and a 2019 Broncos rookie
    # in the same twenty results.
    #
    # The DESCRIPTOR is deliberately left out. It is free text the operator typed
    # to name a look ("navy suit", "1994 Ace Ventura") and it is about how we want
    # the person RENDERED, not about how they appear in photographs on the internet
    # — folding it into the query narrows the search with a term no photograph is
    # tagged with.
    def query
      [@appearance&.person&.full_name, team_name].compact_blank.join(" ")
    end

    private

    def team_name
      @appearance&.team&.name.presence || @appearance&.person&.athlete_profile&.team&.name.presence
    end

    def unconfigured_summary
      Summary.new(configured: false, provider_name: nil, query: query, returned: 0,
                  filed: 0, chosen: 0, rejected: 0, unfetchable: 0, unparsed: 0)
    end

    # FILE THE ANSWER. One pass, in the provider's own order, with three verdicts:
    #
    #   unfetchable  — failed the SSRF/reachability guard. NEVER sent anywhere, and
    #                  filed so the operator can see the search offered it.
    #   beyond_limit — good, but past CHOSEN_LIMIT.
    #   chosen       — in the identity.
    #
    # THE GUARD RUNS BEFORE THE CAP, so a rejected-as-unsafe hit does not consume
    # one of the six slots. Ordering it the other way would let a single
    # private-range URL at rank 1 push a good photograph out of the identity.
    def file(answer)
      results = answer.results
      unfetchable = 0
      chosen = 0
      rejected = 0
      filed = 0

      results.each do |result|
        safe = FetchableUrl.ok?(result.image_url)
        unfetchable += 1 unless safe

        take = safe && chosen < CHOSEN_LIMIT
        reason = if safe
          take ? nil : AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT
        else
          AppearanceReferencePhoto::REJECTED_UNFETCHABLE
        end

        next unless upsert(result, chosen: take, rejection_reason: reason)

        filed += 1
        take ? chosen += 1 : rejected += 1
      end

      Summary.new(configured: true, provider_name: answer.provider_name || @search.provider_name,
                  query: query, returned: results.length, filed: filed, chosen: chosen,
                  rejected: rejected, unfetchable: unfetchable,
                  unparsed: answer.unparsed_count)
    end

    # ONE ROW PER PHOTOGRAPH PER LOOK, re-judged on every search.
    #
    # `find_or_initialize_by` then save, rather than an insert: a re-search re-offers
    # most of the same URLs, and the second run's verdict is the current one — a hit
    # that was `beyond_limit` at rank 7 last week and rank 2 today should now be
    # chosen. The unique index is what makes that safe under a double-click; the
    # rescue below is what makes it safe under the race the index catches.
    #
    # A HEADSHOT OR OPERATOR ROW IS NEVER OVERWRITTEN. Those two sources carry more
    # trust than a search hit (see AppearanceReferencePhoto::SOURCES) and the same
    # URL arriving from a search must not demote the record of where we actually got
    # it — which is exactly what the operator reads the source chip to learn.
    #
    # RETURNS THE ROW ONLY WHEN THIS CALL FILED IT. nil for a row we left alone and
    # nil for a row that would not save — a candidate whose URL is longer than the
    # unique index can hold is dropped, and counting it as filed would make the
    # summary claim a photograph the gallery cannot show.
    def upsert(result, chosen:, rejection_reason:)
      photo = AppearanceReferencePhoto.find_or_initialize_by(
        appearance_slug: @appearance.slug, image_url: result.image_url
      )
      return nil if photo.persisted? && !photo.from_search?

      photo.assign_attributes(
        source: AppearanceReferencePhoto::SOURCE_SEARCH,
        page_url: result.page_url,
        title: result.title,
        width: result.width,
        height: result.height,
        position: result.position,
        query: query,
        chosen: chosen,
        rejection_reason: rejection_reason,
        found_at: Time.current
      )
      photo.save ? photo : nil
    rescue ActiveRecord::RecordNotUnique
      # The unique index caught a concurrent search filing the same URL. The other
      # writer's row is as good as ours — a duplicate is not worth failing a batch
      # of twenty over.
      nil
    end
  end
end
