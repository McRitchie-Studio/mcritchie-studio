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
    # whatever the search got wrong. Everything past the cap is filed with a reason
    # rather than dropped, so raising the cap later is a re-pick rather than a
    # re-search — and a re-search is another purchase.
    CHOSEN_LIMIT = 6

    # HOW MANY CANDIDATES WE PAY THE VISION CLASSIFIER TO LOOK AT.
    #
    # Twice the number we keep, so the ranker has real losers to reject rather than
    # merely ordering the set it was always going to take. It is a COST CEILING
    # first: Appearances::FaceVisibility bills per image, and without this the bill
    # would scale with whatever the provider felt like returning.
    VISION_SHORTLIST = 12

    # BELOW THIS, THE CLASSIFIER SAW NO USABLE FACE. Used only to LABEL a loser
    # (`face_obscured` rather than `beyond_limit`), never to exclude one: the
    # operator asked to PRIORITISE bare faces, and a threshold that excluded would
    # starve a person of whom no clear photograph exists. On a real Commons answer
    # for "Drew Lock" exactly ONE of twenty hits was bare-faced — excluding the
    # helmets would have left the identity with a single photograph.
    FACE_VISIBLE_THRESHOLD = 0.5

    # BELOW THIS, THERE IS NO PERSON IN THE PICTURE AT ALL, and this one IS a hard
    # exclusion. The distinction it rests on is the one FaceVisibility's prompt is
    # written to make: 0.15 means "your man, face hidden by a helmet" and 0.0 means
    # "this is not a photograph of anybody".
    #
    # WHY IT HAD TO EXIST. Without it, `CHOSEN_LIMIT` is a blind take-the-top-N and
    # a thin answer fills the identity with whatever was left. Measured on a real
    # Commons answer for "Drew Lock": 12 of 20 hits were scanned books, and a
    # 1750 edition of The Rape of the Lock was selected INTO the character model.
    # A helmeted photograph is a poor reference; a scanned book page is not a
    # reference, and no supply shortage makes it one.
    NO_PERSON_THRESHOLD = 0.1

    # THREE COUNTS DESCRIBE THE CLASSIFIER LANE, because two of them cannot tell
    # "did nothing" from "had nothing to do":
    #
    #   shortlisted — candidates we selected to be classified. Zero means no
    #                 classifier was configured, or every candidate was a document.
    #   attempted   — of those, how many we mirrored and actually sent. Below
    #                 `shortlisted` means the mirror lost some.
    #   scored      — of those, how many came back with a readable score.
    #
    # `attempted` AND `shortlisted` BOTH EXIST because collapsing them hides which
    # half broke: eight sent and none scored is a classifier failure, eight
    # shortlisted and none sent is a mirror failure, and the operator's next move is
    # different for each.
    Summary = Struct.new(:configured, :provider_name, :query, :returned, :filed,
                         :chosen, :rejected, :unfetchable, :unparsed, :ranked_by,
                         :scored, :shortlisted, :attempted, keyword_init: true) do
      def configured? = !!self[:configured]

      # WHAT ACTUALLY DID THE ORDERING — `:face` when the vision classifier ran,
      # `:merit` when it could not. On the page this is the difference between
      # "these were ranked by whether a face is visible" and "these were ranked by
      # shape and relevance", and the operator has to be able to tell.
      def ranked_by_face? = self[:ranked_by] == :face

      # THE LANE SAW NONE OF ITS INPUTS — the failure this whole change was written
      # from, and the one the page could not previously express.
      #
      # ZERO SCORES FROM N ATTEMPTS IS NOT N PHOTOGRAPHS THAT SCORED ZERO, and until
      # now the two were indistinguishable to an operator: both produced
      # `ranked_by: :merit` and the sentence "ranked on shape and relevance only (no
      # face classifier)", which is TRUE of a machine with no credential and a LIE
      # about a machine that shortlisted eight photographs, sent them, and was
      # refused on every one. On 2026-09-26 the lie cost the character model three
      # photographs of aircraft.
      #
      # KEYED ON `shortlisted` RATHER THAN ON `attempted`, so it covers BOTH ways the
      # lane can go blind — the classifier refusing everything, and the mirror
      # failing so completely that nothing was ever sent. Keying on `attempted` would
      # have read a total mirror failure as "nothing to do" and gone quiet again.
      #
      # IT CANNOT FIRE WITHOUT A CLASSIFIER. With no credential, `shortlisted` is
      # zero because the shortlist is never built — so an unconfigured machine, which
      # is every machine that has no ANTHROPIC_API_KEY, reports the ordinary
      # fallback rather than an alarm.
      def face_classifier_blind?
        self[:shortlisted].to_i.positive? && self[:scored].to_i.zero?
      end

      # WHICH FLASH THIS SENTENCE DESERVES. A blind classifier is an ALERT, not a
      # notice: the run "succeeded" — photographs were filed and an identity can be
      # built from them — so a green notice is exactly what let a confidently wrong
      # result read as a good one. The severity is part of the same judgement as the
      # sentence, so it lives beside it rather than being re-derived by each caller.
      def flash_key = face_classifier_blind? ? :alert : :notice

      # THE ONE SENTENCE BOTH SEARCH ACTIONS PRINT.
      #
      # It lived twice, verbatim, as a private `search_message` in
      # PhotoScoutingController and in AppearancesController. Every number in it is
      # this struct's, and the duplication meant the blind-classifier clause below
      # would have had to be added in two places — which is to say it could have been
      # added in one and left the other page still reading the old reassurance.
      def sentence
        parts = ["#{provider_name} returned #{returned} result(s)"]
        parts << "#{unparsed} in a shape we could not read" if self[:unparsed].to_i.positive?
        parts << "#{unfetchable} refused as unsafe to fetch" if self[:unfetchable].to_i.positive?
        parts << ranking_clause
        parts << "#{chosen} chosen for the model"
        "#{parts.join(' · ')}."
      end

      # NAMES WHAT DID THE ORDERING. "6 chosen" reads the same whether a vision
      # classifier ranked them or nothing did, and those are the two outcomes the
      # operator most needs to tell apart right after clicking.
      def ranking_clause
        return "#{scored} scored for face visibility" if ranked_by_face?
        return blind_clause if face_classifier_blind?

        "ranked on shape and relevance only (no face classifier)"
      end

      # SAYS WHAT BROKE AND HOW MUCH IT COST, in the operator's units. It names both
      # counts so the sentence itself separates a mirror failure from a classifier
      # failure, and it ends by naming the consequence — the ranking that actually
      # chose the photographs now on the page.
      def blind_clause
        "FACE CLASSIFIER SAW NOTHING: 0 of #{shortlisted} shortlisted scored " \
          "(#{attempted} mirrored and sent) - these were ranked on shape and " \
          "relevance only, so check them before minting"
      end
    end

    # WHAT GETS FILED WHEN THE LANE GOES BLIND. An exception class rather than a bare
    # string because Appearances::FailureLog files through ErrorLog.capture!, which
    # reads `#message` and `#backtrace` off an exception — and because the class name
    # is what the operator scans for in /admin/error_logs.
    #
    # NEVER RAISED, only filed. Raising it would cost the operator the page, which is
    # the opposite of what this lane promises.
    class ClassifierBlind < StandardError; end

    def self.call(appearance, **kwargs) = new(appearance, **kwargs).call

    # `search:` is injected for the same reason Appearances::CreateCharacterReference
    # injects its client: every real call costs money, so the suite must be able to
    # hand this object something that cannot reach the network. It defaults to the
    # façade, never to a concrete provider — this object must not know which vendor
    # is serving.
    # BOTH COLLABORATORS ARE INJECTED, and for the same reason
    # Appearances::CreateCharacterReference injects its vendor client: every real
    # call to either one costs money, so the suite must be able to hand this object
    # things that cannot reach the network.
    #
    # `search:` defaults to the FAÇADE, never a concrete provider — this object
    # must not know which vendor is serving.
    #
    # `mirror:` IS THE THIRD, and it is injected for a slightly different reason than
    # the other two: it spends no vendor money, but it fetches a remote file and
    # writes an S3 object, and a suite that did either would be writing into a real
    # bucket. Appearances::LiveCallTrap refuses the un-injected path outright rather
    # than trusting every test to remember.
    def initialize(appearance, search: ImageSearch, faces: FaceVisibility,
                   mirror: MirrorCandidates, limit: ImageSearch::DEFAULT_LIMIT)
      @appearance = appearance
      @search = search
      @faces = faces
      @mirror = mirror
      @limit = limit
      @shortlisted = 0
      @attempted = 0
    end

    def call
      return unconfigured_summary unless @search.available?

      # `target:` IS WHAT MAKES A PROVIDER FAILURE FINDABLE. Both collaborators
      # degrade to an empty answer rather than raising, so the look they were
      # working on is the only handle the operator has for reading the row back.
      answer = @search.search(query: query, limit: @limit, target: @appearance)
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
                  filed: 0, chosen: 0, rejected: 0, unfetchable: 0, unparsed: 0,
                  ranked_by: nil, scored: 0, shortlisted: 0, attempted: 0)
    end

    # FILE THE ANSWER, IN RANK ORDER RATHER THAN IN THE PROVIDER'S ORDER.
    #
    # Five verdicts:
    #
    #   unfetchable   — failed the SSRF/reachability guard. NEVER sent anywhere,
    #                   and filed so the operator can see the search offered it.
    #   not_a_photo   — no person in the picture at all. The one HARD exclusion:
    #                   a scanned page is not a poor reference, it is not one.
    #   face_obscured — the vision classifier looked and found no usable face.
    #                   Only ever stamped when something ACTUALLY LOOKED.
    #   beyond_limit  — fine, but past CHOSEN_LIMIT.
    #   chosen        — in the identity.
    #
    # `duplicate` is the sixth reason the model declares and the one NOTHING here
    # stamps — see AppearanceReferencePhoto for why it is declared anyway.
    #
    # THE GUARD RUNS BEFORE THE RANKING, so a rejected-as-unsafe hit never consumes
    # a slot and is never paid to be classified. Ordering it the other way would
    # let a single private-range URL at rank 1 push a good photograph out of the
    # identity AND bill us to look at it.
    def file(answer)
      results = answer.results
      safe, unsafe = results.partition { |r| FetchableUrl.ok?(r.image_url) }

      scores = face_scores(safe)
      ranked = safe.sort_by { |r| [-final_score(r, scores), r.position.to_i] }

      counts = { filed: 0, chosen: 0, rejected: 0 }
      taken = 0
      ranked.each do |result|
        # COUNTING TAKEN RATHER THAN INDEX. A disqualified candidate must not
        # consume a slot on its way to being rejected, or a thin answer full of
        # scanned pages would leave the identity with fewer photographs than the
        # search actually found for it.
        take = !not_a_photo?(result, scores) && taken < CHOSEN_LIMIT
        taken += 1 if take
        record(result, take, rejection_for(result, scores, take), counts,
               face_score: scores[result.image_url])
      end
      # THE UNSAFE ONES ARE NEVER SCORED — they were never sent to the classifier,
      # because paying to look at a URL we have already refused to fetch is paying
      # for an answer we would not act on.
      unsafe.each do |result|
        record(result, false, AppearanceReferencePhoto::REJECTED_UNFETCHABLE, counts,
               face_score: nil)
      end

      summary = Summary.new(configured: true,
                            provider_name: answer.provider_name || @search.provider_name,
                            query: query, returned: results.length, filed: counts[:filed],
                            chosen: counts[:chosen], rejected: counts[:rejected],
                            unfetchable: unsafe.length, unparsed: answer.unparsed_count,
                            ranked_by: scores.any? ? :face : :merit, scored: scores.length,
                            shortlisted: @shortlisted, attempted: @attempted)
      report_blind_classifier(summary)
      summary
    end

    # ONE ROW PER BLIND SEARCH, filed where the operator already looks.
    #
    # WHY THE ROW IS FILED HERE rather than inside either collaborator. This is the
    # only object that knows how many candidates it shortlisted, so it is the only one
    # that can tell "the classifier saw none of its inputs" from "there was nothing to
    # classify". FaceVisibility files its own row for a refusal it can NAME — a 400, a
    # timeout, an unreadable answer — but it cannot file one for the cases with no
    # exception in them: a 200 carrying an empty array, or a mirror that handed it
    # nothing to look at. Those are exactly the silent shapes.
    #
    # AT MOST ONE ROW, deliberately. Filing per photograph would put twelve identical
    # rows in front of the operator on a single outage and bury the number that
    # matters. This row names all three counts, so it is the whole diagnosis.
    #
    # IT MAY SIT BESIDE FaceVisibility'S OWN ROW, and that is not duplication: the
    # vendor's row says WHAT was refused ("Anthropic answered 400: Unable to download
    # the file"), this one says WHAT IT COST THE RUN ("0 of 8 scored, so these
    # photographs were ranked on shape alone"). On 2026-09-26 the first existed and
    # the second did not, and the second is the one that would have stopped three
    # aircraft entering a character model.
    def report_blind_classifier(summary)
      return unless summary.face_classifier_blind?

      FailureLog.file(
        ClassifierBlind.new(
          "face classifier scored 0 of #{summary.shortlisted} shortlisted candidate(s) " \
          "(#{summary.attempted} mirrored and sent) for \"#{summary.query}\" — the " \
          "photographs now filed were ranked on shape and relevance only"
        ),
        target: @appearance
      )
    end

    def record(result, take, reason, counts, face_score:)
      return unless upsert(result, chosen: take, rejection_reason: reason,
                                   face_score: face_score)

      counts[:filed] += 1
      take ? counts[:chosen] += 1 : counts[:rejected] += 1
    end

    # PAY TO LOOK AT THE SHORTLIST, NOT AT EVERYTHING.
    #
    # The free metadata score picks who gets classified; the classifier decides the
    # actual order. That split is what keeps the bill proportional to VISION_SHORTLIST
    # instead of to however many results the provider felt like returning.
    #
    # An empty Hash back — no credential, an outage, an unreadable answer — is a
    # NORMAL answer and the whole method degrades to the free ranking. The caller
    # can tell which happened from `Summary#ranked_by_face?`.
    # MIRROR FIRST, THEN CLASSIFY. The classifier never sees a third-party URL.
    def face_scores(results)
      return {} unless @faces.respond_to?(:available?) && @faces.available?

      # DOCUMENTS ARE NOT SHORTLISTED, because they can never be chosen and the
      # classifier bills per image. MEASURED on a real Commons answer for "Drew
      # Lock": 20 candidates, 12 of them documents, so the shortlist this fills
      # drops from 12 images to 8 — a third of the bill, spent confirming that a
      # book is not a face.
      eligible = results.reject { |r| PhotoMerit.document?(r) }
      shortlist = eligible.sort_by { |r| [-merit(r), r.position.to_i] }.first(VISION_SHORTLIST)
      return {} if shortlist.empty?

      @shortlisted = shortlist.length

      # THE ROWS ARE FILED BEFORE THE MIRROR RUNS, because the mirror's ImageCache
      # row is OWNED by the candidate row — one photograph, one owner, one "original"
      # variant, which is how MirrorCandidates satisfies ImageCache's
      # variant-unique-per-(owner, purpose) constraint by construction instead of
      # working around it. An owner has to exist before it can own anything.
      #
      # WHAT THESE ROWS CARRY AND WHAT THEY DO NOT: every fact the provider reported,
      # and NO verdict. The verdict pass below runs `#upsert` over the same rows a few
      # lines later and stamps `chosen` and `rejection_reason` then, once the
      # classifier has actually answered — so a row is never stamped with a judgement
      # nothing made. It also means a run that died here leaves evidence of what the
      # search offered rather than nothing at all.
      hosted = @mirror.call(shortlist.filter_map { |result| file_candidate(result) },
                            target: @appearance)
      @attempted = hosted.length
      return {} if hosted.empty?

      # ASKED ABOUT OUR URLs, ANSWERED IN THEIRS. Everything downstream keys on the
      # provider's `image_url` — the rows, the merit memo, the rejection reasons — so
      # the scores are translated straight back rather than leaking a second identity
      # for the same photograph through the rest of this object.
      #
      # THE MAP IS THE ONLY TRANSLATION, so a score for a URL we did not send has
      # nowhere to land and is dropped, which is the same tolerance the classifier's
      # own parser applies to an index it cannot resolve.
      scored = @faces.call(hosted.values, target: @appearance) || {}
      hosted.each_with_object({}) do |(remote_url, our_url), out|
        value = scored[our_url]
        out[remote_url] = value unless value.nil?
      end
    end

    # FILE THE EVIDENCE, WITHOUT A VERDICT, and return the row the mirror will own.
    #
    # A PERSISTED ROW IS RETURNED UNTOUCHED, which keeps the guard that protects a
    # headshot or operator row from a search hit in ONE place — `#upsert`. This method
    # never overwrites anything, so it cannot half-apply that rule; the worst it does
    # to an existing row is hand it to the mirror, and mirroring a photograph we
    # already trust costs one idempotent no-op.
    #
    # nil FOR A ROW THAT WILL NOT SAVE — a URL longer than the unique index can hold,
    # the same case `#upsert` drops. The caller's `filter_map` removes it, so it is
    # never mirrored and never classified, which is right: the gallery could not show
    # it either.
    def file_candidate(result)
      photo = AppearanceReferencePhoto.find_or_initialize_by(
        appearance_slug: @appearance.slug, image_url: result.image_url
      )
      return photo if photo.persisted?

      photo.assign_attributes(
        evidence_attributes(result).merge(
          source: AppearanceReferencePhoto::SOURCE_SEARCH, chosen: false
        )
      )
      photo.save ? photo : nil
    rescue ActiveRecord::RecordNotUnique
      # A concurrent search filed the same URL between the initialize and the save.
      # Its row is as good as ours and the mirror can own it just the same.
      AppearanceReferencePhoto.find_by(appearance_slug: @appearance.slug,
                                       image_url: result.image_url)
    end

    # WHAT THE PROVIDER SAID ABOUT THIS PHOTOGRAPH — the half of a row that is a
    # record of the search rather than a judgement of it.
    #
    # Shared by `#file_candidate` and `#upsert` because both write it and a second
    # spelling would let the pre-pass and the verdict pass disagree about what the
    # provider reported — the pre-pass writes it first, so its version would be the
    # one a failed run left behind.
    def evidence_attributes(result)
      {
        page_url: result.page_url,
        title: result.title,
        width: result.width,
        height: result.height,
        position: result.position,
        # REPORTED BY THE PROVIDER WHEN IT VOLUNTEERS ONE, and nil is fine — Serper
        # does not report a mime type and a row without one is not worse, only
        # quieter. Stored rather than derived because it is the ARCHIVE's own claim
        # about what the file is, which is a stronger statement than sniffing an
        # extension out of a URL, and the scouting page prints it as such. It is also
        # what MirrorCandidates asks first when it needs a content type.
        mime_type: result.mime,
        thumb_url: result.thumb_url,
        query: query,
        found_at: Time.current
      }
    end

    # MAY THIS CANDIDATE GO INTO THE IDENTITY AT ALL? Two independent disqualifiers,
    # and both mean the same thing — there is no person in this picture:
    #
    #   · the free metadata check recognised a document (deterministic, no spend);
    #   · the classifier looked and scored it below NO_PERSON_THRESHOLD.
    #
    # Everything else is eligible, however poor, because the operator asked for a
    # PRIORITY ORDER and a person of whom only helmeted photographs exist must still
    # get an identity.
    def not_a_photo?(result, scores)
      return true if PhotoMerit.document?(result)

      scored = scores[result.image_url]
      scored.present? && scored < NO_PERSON_THRESHOLD
    end

    # THE CLASSIFIER IS THE AUTHORITY WHERE IT SPOKE; merit only orders the rest.
    #
    # An UNSCORED candidate is not a zero. It is scaled into the band below the
    # classifier's own scale rather than mixed into it, because "nobody looked at
    # this" must not outrank "something looked and saw a face" — and must equally
    # not be read as "something looked and saw none". With no classifier at all,
    # every candidate is unscored and the band is the only scale in play, so the
    # ordering is pure merit.
    def final_score(result, scores)
      scored = scores[result.image_url]
      return 1.0 + scored if scored

      merit(result)
    end

    def merit(result)
      @merit ||= {}
      @merit[result.image_url] ||= PhotoMerit.score(result, person_name: person_name)
    end

    # `face_obscured` IS ONLY EVER STAMPED WHEN SOMETHING ACTUALLY LOOKED. A loser
    # the classifier never saw — because it fell outside the shortlist, or because
    # there is no classifier configured — is `beyond_limit`, which is the truth. A
    # reason the operator reads as a judgement must not be a guess.
    def rejection_for(result, scores, take)
      return nil if take
      return AppearanceReferencePhoto::REJECTED_NOT_A_PHOTO if not_a_photo?(result, scores)

      scored = scores[result.image_url]
      if scored && scored < FACE_VISIBLE_THRESHOLD
        AppearanceReferencePhoto::REJECTED_FACE_OBSCURED
      else
        AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT
      end
    end

    def person_name = @appearance&.person&.full_name

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
    def upsert(result, chosen:, rejection_reason:, face_score: nil)
      photo = AppearanceReferencePhoto.find_or_initialize_by(
        appearance_slug: @appearance.slug, image_url: result.image_url
      )
      return nil if photo.persisted? && !photo.from_search?

      photo.assign_attributes(
        evidence_attributes(result).merge(
          source: AppearanceReferencePhoto::SOURCE_SEARCH,
          chosen: chosen,
          rejection_reason: rejection_reason,
          # ONLY OVERWRITE A SCORE WITH A SCORE. A re-search whose shortlist did not
          # include this photograph must not erase the judgement the last one paid
          # for — that would turn "we looked in March" into "nobody has ever looked"
          # and re-sort the gallery on an absence we created.
          face_score: face_score || photo.face_score
        )
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
