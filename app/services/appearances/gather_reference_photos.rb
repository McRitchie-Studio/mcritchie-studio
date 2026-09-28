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
    # FOUR SEARCHES PER LOOK, ONE PER EXPRESSION WE WANT THE MODEL TO HAVE SEEN.
    #
    # THE OPERATOR ASKED FOR THIS AND THE MEASUREMENT BACKED HIM. In his words:
    # *"chunk up the searches into 'First name Last name', 'Name Smile', 'Name No
    # Helmet', 'Name Laugh' and maybe pull 20 from each so 80 total — this should give
    # good assets for the model."* The goal behind it is FACIAL STRUCTURE AND
    # EXPRESSIONS: an identity built from six sideline photographs of one neutral face
    # cannot render a laugh.
    #
    # MEASURED AGAINST LIVE SERPER TWICE, ON TWO ATHLETES, 2026-09-27.
    #
    #   `justin-jefferson`, six variants at 20 each: 107 UNIQUE of 120 (13 collisions).
    #   `jaylen-waddle`, THESE FOUR at 20 each:       73 UNIQUE of 80  (7 collisions,
    #     8.8%), and the marginal contribution ran 20 / 20 / 18 / 15 new — "smiling"
    #     collided with the bare name on NOTHING at all.
    #
    # So variants reach genuinely different parts of the index, which is the premise the
    # whole fan-out rests on and the one worth measuring before spending four times as
    # much. It held on both athletes. The duplicate rate did NOT hold steady (10.8% then
    # 8.8%), so nothing here assumes a number: the dedupe is unconditional.
    #
    # ⚠ "no helmet" IS NOT A NEGATION AND THE ARGUMENT AGAINST IT WAS WRONG. The
    # prediction was that a search engine cannot negate, so the phrase would return
    # helmets. It does not: the phrase matches how captions are WRITTEN ("pictured
    # without his helmet"). On `justin-jefferson` it was the strongest variant of six by
    # portrait shape, 11 of 20 against 3 for the bare name. ⚠ BUT THAT MARGIN IS ONE
    # ATHLETE'S, not the variant's: on `jaylen-waddle` the same four ran 6 / 7 / 8 / 6
    # portrait-shaped, which is flat. What generalises is that the variants return
    # DIFFERENT photographs; which variant returns the BEST ones does not, and no code
    # here weights one variant above another on the strength of it. The two variants
    # proposed INSTEAD of the operator's — "press conference" (0 portrait-shaped) and
    # "headshot" (3) — were the worst two of the six and are not here.
    #
    # AND NOTE WHAT `portrait-shaped` IS: height > width, a FREE PROXY for a
    # face-filling crop, not a measurement of face fill. Only the classifier measures
    # that. No sentence on the page quotes the proxy as if it were the measurement.
    #
    # THE WORDING IS THE MEASURED WORDING, NOT THE OPERATOR'S VERBATIM NOUNS, and the
    # two are NOT interchangeable. He wrote "Smile" and "Laugh". Probed on
    # `justin-jefferson` against live Serper the same day, 20 results each:
    #
    #   "smile" vs "smiling"   overlapped 17 of 20 — effectively the same search
    #   "laugh" vs "laughing"  overlapped  7 of 20 — a materially DIFFERENT search
    #
    # The gerunds stay because they are the spelling every quality figure above was
    # measured with, and his nouns have none. That is a statement about the evidence and
    # not about his judgement: if he wants his own words, this constant is the one line
    # to change, and what he gains and loses by it is the 7-of-20 above.
    #
    # THE FIRST VARIANT IS THE BARE SUBJECT and it stays first for a reason beyond
    # order: it is the one every candidate is attributed to when several variants
    # return the same photograph (see `#found_by`), so the later variants are credited
    # only with what they UNIQUELY contributed — which is the number that decides
    # whether a variant is worth its query.
    QUERY_VARIANTS = ["", "smiling", "no helmet", "laughing"].freeze

    # HOW MANY PHOTOGRAPHS AN IDENTITY IS BUILT FROM.
    #
    # Higgsfield's minimum is 1 and it names no maximum. This cap is ours, and it
    # is about the IDENTITY rather than about the API: past a handful, extra
    # photographs of the same face stop adding information and start adding
    # whatever the search got wrong. Everything past the cap is filed with a reason
    # rather than dropped, so raising the cap later is a re-pick rather than a
    # re-search — and a re-search is another purchase.
    #
    # RAISED FROM 6 TO 8 WITH THE FAN-OUT, and this is the CHEAP half of the two
    # ceilings: everything past the cap is already filed, already classified and
    # already paid for, so moving this number spends NOTHING at gather time. It costs
    # only at mint time, where Higgsfield bills per training image. Eight is two per
    # variant — enough that a laugh and a neutral portrait can both be in the set the
    # operator asked to be richer, and still inside the "past a handful" judgement
    # above, which was about a dozen rather than about six.
    CHOSEN_LIMIT = 8

    # HOW MANY CANDIDATES WE PAY THE VISION CLASSIFIER TO LOOK AT.
    #
    # THIS IS THE EXPENSIVE CEILING, and it is the one the fan-out actually moves.
    # Appearances::FaceVisibility sends every shortlisted image as input tokens on
    # claude-haiku-4-5, so the bill scales with THIS number and not with how many
    # queries ran — four searches cost four queries and one classification request.
    #
    # RAISED FROM 12 TO 24, WHICH IS A DELIBERATE DOUBLING RATHER THAN A MATCH FOR THE
    # INPUT. Four variants at 20 each yield roughly 72 unique candidates, so 12 would
    # judge 17% of what we had just paid to find, and the 83% nobody looked at is
    # refused as `face_unscored` — the fan-out would have bought four queries and
    # changed nothing that reaches the model. Judging ALL 72 is the other extreme and
    # triples the classification bill for candidates the free merit score already ranks
    # last. 24 is a third of the harvest, three times the cap, and the number the
    # measured cost below was chosen against.
    #
    # THE COST THAT FOLLOWS, MEASURED 2026-09-27 so nobody has to re-derive it. Counted
    # with /v1/messages/count_tokens — which is free — over FIVE REAL candidate rows
    # already on file in production, base64'd from their own bytes (the endpoint refuses
    # a URL image source, so the URLs this lane actually sends cannot be counted
    # directly; the token count is a function of the pixels either way).
    #
    #   system prompt alone            624 tokens
    #   per image, 5 real candidates   292 to ~1,200, averaging 709
    #   answer for 12 images           523 tokens out   (measured, see MAX_TOKENS)
    #   answer for 24 images         1,039 tokens out
    #
    # So at Haiku 4.5's $1/MTok in and $5/MTok out, per athlete per search:
    #
    #   12 images   624 + 8,508 in, 523 out    = $0.0091 + $0.0026 = $0.012
    #   24 images   624 + 17,016 in, 1,039 out = $0.0176 + $0.0052 = $0.023
    #
    # ONE FULL PASS OVER THE 2,051 ATHLETES IN PRODUCTION is therefore ~8,204 Serper
    # queries (four each, and Serper bills per QUERY rather than per result) plus ~$47 of
    # classification, against ~$24 at a ceiling of 12. The whole change costs about
    # twenty-three dollars a pass. It is stated here rather than in a commit message
    # because the next person to reach for this constant is the person who needs it.
    #
    # ⚠ IT IS CAPPED BY Appearances::FaceVisibility::MAX_TOKENS, NOT ONLY BY MONEY, and
    # that ceiling had to move with this one — it was ALREADY TOO LOW FOR TWELVE. Every
    # image is answered with its own JSON object in ONE response, and a response cut off
    # at `max_tokens` has no closing bracket, so `FaceVisibility#parse` matches no array,
    # raises, and returns an EMPTY hash: total blindness for the whole look rather than a
    # short answer. A realistic twelve-image answer measured 523 tokens against a
    # MAX_TOKENS of 512. See MAX_TOKENS there for what it is now and why.
    VISION_SHORTLIST = 24

    # WHICH CANDIDATES MAY GO INTO AN IDENTITY IS NOT DECIDED HERE ANY MORE.
    #
    # Every threshold that used to live at this spot — the visibility floor, the
    # no-person floor, and now a face-SIZE floor and a wrong-person check — moved to
    # Appearances::ReferenceEligibility, because the same rule has to be applied three
    # times: here at file time to decide `chosen`, and again by
    # Appearances::ReferenceSet over the persisted rows once per GENERATOR, since the
    # zero-shot sheet and Higgsfield's trainer do not accept the same set. Three copies
    # of a threshold is three answers to "is this photograph a reference", and the page
    # prints one of them.
    #
    # THE TWO RULES THAT STAYED HERE — `CHOSEN_LIMIT` and `VISION_SHORTLIST` — are
    # about how many photographs and how big a bill, not about which photograph, which
    # is why they did not go with the rest.

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
                         :scored, :sized, :mint_ready, :shortlisted, :attempted,
                         keyword_init: true) do
      def configured? = !!self[:configured]

      # WHAT ACTUALLY DID THE ORDERING — `:face_size` when the classifier reported how
      # much of the frame the head fills, `:face` when it reported only visibility,
      # `:merit` when it could not answer at all. On the page this is the difference
      # between "these were ranked by the thing that decides a mint", "these were
      # ranked by whether a face is visible" and "these were ranked by shape", and the
      # operator has to be able to tell which one he is looking at.
      def ranked_by_face? = [:face, :face_size].include?(self[:ranked_by])
      def ranked_by_face_size? = self[:ranked_by] == :face_size

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

      # THE CLASSIFIER ANSWERED BUT REPORTED NO FACE SIZE — the one failure that would
      # otherwise make this whole gate inert without saying so.
      #
      # WHY IT IS ITS OWN ALARM. `fill` is a field of FaceVisibility's prompt that was
      # never verified against the live model (the task that added it forbade paid
      # calls), and Appearances::ReferenceEligibility refuses a candidate whose face size
      # nobody measured. So a model that ignores the field produces a page that files
      # twenty candidates, scores them all, chooses NONE, and — without this — explains
      # it with the ordinary "past the limit" furniture. That is the same silent shape
      # that put three photographs of aircraft into a character model on 2026-09-26,
      # and the lesson from that week was to name the blindness rather than its
      # symptom.
      #
      # KEYED ON `scored` RATHER THAN ON `shortlisted`, because it is a statement about
      # an answer we received: a classifier that answered nothing at all is
      # `face_classifier_blind?`, and reporting both alarms for one outage would bury
      # the actionable one.
      def face_size_blind?
        self[:scored].to_i.positive? && self[:sized].to_i.zero?
      end

      # WHICH FLASH THIS SENTENCE DESERVES. A blind classifier is an ALERT, not a
      # notice: the run "succeeded" — photographs were filed and an identity can be
      # built from them — so a green notice is exactly what let a confidently wrong
      # result read as a good one. The severity is part of the same judgement as the
      # sentence, so it lives beside it rather than being re-derived by each caller.
      #
      # A TRAINER WITH NOTHING TO TRAIN ON IS A NOTICE, NOT AN ALERT, and the asymmetry is
      # deliberate: the sheet path — the one the operator actually presses — got its
      # photographs, so the run really did succeed. `#trainer_clause` says what the trainer
      # will get in the same sentence, which is why there is no separate predicate for it.
      def flash_key = face_classifier_blind? || face_size_blind? ? :alert : :notice

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
        parts << "#{chosen} chosen as references"
        parts << trainer_clause
        "#{parts.join(' · ')}."
      end

      # NAMES WHAT DID THE ORDERING. "6 chosen" reads the same whether a vision
      # classifier ranked them or nothing did, and those are the two outcomes the
      # operator most needs to tell apart right after clicking.
      def ranking_clause
        return "#{sized} measured for face size" if ranked_by_face_size?
        return size_blind_clause if face_size_blind?
        return "#{scored} scored for face visibility" if ranked_by_face?
        return blind_clause if face_classifier_blind?

        "ranked on shape and relevance only (no face classifier)"
      end

      # SAYS THE MEASUREMENT THAT DECIDES A MINT IS MISSING, and what that costs. It
      # names the field so whoever reads it can check the prompt against the vendor's
      # answer, which is the actual next move.
      def size_blind_clause
        "NO FACE SIZE REPORTED: #{scored} photograph(s) were scored for visibility and " \
          "0 for face size, which is the measurement Higgsfield's prepare step turns on " \
          "- so the trainer is offered the cached headshot alone"
      end

      # WHAT EACH OF THE TWO GENERATORS ACTUALLY GETS, in one clause.
      #
      # THE TWO NUMBERS DIVERGE AND THE OPERATOR CANNOT SEE WHY WITHOUT THIS. Every
      # chosen photograph reaches the zero-shot sheet; only the ones with a measured
      # face size may be paid to Higgsfield's trainer, because four of six measured
      # mints failed at prepare and face size is the variable they turned on. One
      # number labelled "chosen" would describe whichever generator the reader happened
      # to be thinking about.
      def trainer_clause
        return "all #{chosen} can also go to the trainer" if chosen.to_i.positive? &&
                                                             self[:mint_ready].to_i == chosen.to_i

        "#{self[:mint_ready].to_i} of #{chosen} carry a measured face size, so the trainer " \
          "gets that many plus the cached headshot"
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

    # WHAT GETS FILED WHEN THE CLASSIFIER ANSWERS BUT REPORTS NO FACE SIZE. Its own
    # class rather than a second message on ClassifierBlind, because the class name is
    # what the operator scans /admin/error_logs for and the two failures have different
    # remedies — one is the vendor's fetch, the other is our prompt.
    class FaceSizeBlind < StandardError; end

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
                  ranked_by: nil, scored: 0, sized: 0, mint_ready: 0, shortlisted: 0,
                  attempted: 0)
    end

    # FILE THE ANSWER, IN RANK ORDER RATHER THAN IN THE PROVIDER'S ORDER.
    #
    # The verdicts, and only ONE of them is decided here:
    #
    #   unfetchable   — failed the SSRF/reachability guard. NEVER sent anywhere,
    #                   and filed so the operator can see the search offered it.
    #   beyond_limit  — eligible, but past CHOSEN_LIMIT. THE ONE THIS OBJECT OWNS,
    #                   because the cap is this object's rule.
    #   chosen        — in the reference set.
    #   everything else — Appearances::ReferenceEligibility's verdict, stamped verbatim:
    #                   not_a_photo, wrong_person, mixed_subjects, face_obscured,
    #                   face_unscored, face_too_small.
    #
    # `face_size_unmeasured` IS NEVER STAMPED HERE, and that is the two-generator split
    # rather than an omission: an unmeasured face size keeps a photograph out of
    # Higgsfield's TRAINER (Appearances::ReferenceSet#call re-asks for that) and not out
    # of the reference set, because the zero-shot sheet has no preparation stage to
    # refuse it and the operator asked for more references rather than fewer.
    #
    # `duplicate` is the one reason the model declares that NOTHING here stamps — see
    # AppearanceReferencePhoto for why it is declared anyway.
    #
    # THE VERDICT IS STAMPED VERBATIM RATHER THAN RE-DERIVED, which is the whole
    # reason the eligibility rule is a separate object: the symbol that refused the
    # photograph IS the reason printed on the tile, so the page can never explain a
    # rejection with a different rule from the one that made it.
    #
    # THE GUARD RUNS BEFORE THE RANKING, so a rejected-as-unsafe hit never consumes
    # a slot and is never paid to be classified. Ordering it the other way would
    # let a single private-range URL at rank 1 push a good photograph out of the
    # identity AND bill us to look at it.
    def file(answer)
      results = answer.results
      safe, unsafe = results.partition { |r| FetchableUrl.ok?(r.image_url) }

      judgements = face_judgements(safe)
      ranked = safe.sort_by { |r| [-final_score(r, judgements), r.position.to_i] }

      counts = { filed: 0, chosen: 0, rejected: 0, mint_ready: 0 }
      taken = 0
      ranked.each do |result|
        verdict = reference_verdict(result, judgements)
        # COUNTING TAKEN RATHER THAN INDEX. A disqualified candidate must not
        # consume a slot on its way to being rejected, or a thin answer full of
        # scanned pages would leave the identity with fewer photographs than the
        # search actually found for it.
        take = verdict == ReferenceEligibility::ELIGIBLE && taken < CHOSEN_LIMIT
        taken += 1 if take
        record(result, take, rejection_for(verdict, take), counts,
               judgement: judgements[result.image_url])
      end
      # THE UNSAFE ONES ARE NEVER SCORED — they were never sent to the classifier,
      # because paying to look at a URL we have already refused to fetch is paying
      # for an answer we would not act on.
      unsafe.each do |result|
        record(result, false, AppearanceReferencePhoto::REJECTED_UNFETCHABLE, counts,
               judgement: nil)
      end

      summary = Summary.new(configured: true,
                            provider_name: answer.provider_name || @search.provider_name,
                            query: query, returned: results.length, filed: counts[:filed],
                            chosen: counts[:chosen], rejected: counts[:rejected],
                            unfetchable: unsafe.length, unparsed: answer.unparsed_count,
                            ranked_by: ranked_by(judgements), scored: judgements.length,
                            sized: judgements.count { |_url, j| j.sized? },
                            mint_ready: counts[:mint_ready],
                            shortlisted: @shortlisted, attempted: @attempted)
      report_blind_classifier(summary)
      report_blind_face_size(summary)
      summary
    end

    # WHAT ORDERED THE GALLERY — the strongest measurement anything actually reported,
    # never the strongest one we asked for. A run where the classifier answered but
    # reported no face size ranked on visibility, and saying `:face_size` because the
    # prompt requested it is precisely the confident lie this lane keeps having to
    # unlearn.
    def ranked_by(judgements)
      return :face_size if judgements.any? { |_url, j| j.sized? }
      return :face if judgements.any?

      :merit
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

    # ONE ROW PER BLIND FACE-SIZE ANSWER, filed where the operator already looks.
    #
    # SEPARATE FROM `report_blind_classifier` BECAUSE THE REMEDY IS DIFFERENT, and the
    # remedy is the only reason an ErrorLog row is worth writing. A blind classifier is
    # a credential or a fetch problem on the vendor's side of the wire; a blind face
    # SIZE is our own prompt not getting the field back, and the person reading the row
    # has to know which of those two they are holding. A single row covering both would
    # send them to the wrong place half the time.
    def report_blind_face_size(summary)
      return unless summary.face_size_blind?

      FailureLog.file(
        FaceSizeBlind.new(
          "the face classifier scored #{summary.scored} photograph(s) for \"#{summary.query}\" " \
          "and reported a face SIZE for none of them — face size is what " \
          "Appearances::ReferenceEligibility.mint_verdict demands, so Higgsfield's trainer " \
          "gets the cached headshot alone (the zero-shot sheet still gets the set). Check " \
          "Appearances::FaceVisibility::SYSTEM_PROMPT against the vendor's actual answer"
        ),
        target: @appearance
      )
    end

    # EVERY COUNT IS INCREMENTED IN ONE PLACE, AFTER THE WRITE SUCCEEDED.
    #
    # ⚠ `mint_ready` USED TO BE COUNTED AT THE CALL SITE and that was a count that could
    # lie. `#upsert` answers nil for a row it deliberately left alone — a headshot or
    # operator row a search re-found — so a caller that counted before asking could report
    # "1 of 0 carry a measured face size". Counting after the write is what keeps every
    # figure in the summary about the same population.
    def record(result, take, reason, counts, judgement:)
      return unless upsert(result, chosen: take, rejection_reason: reason,
                                   judgement: judgement)

      counts[:filed] += 1
      take ? counts[:chosen] += 1 : counts[:rejected] += 1
      counts[:mint_ready] += 1 if take && judgement&.sized?
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
    def face_judgements(results)
      return {} unless @faces.respond_to?(:available?) && @faces.available?

      # WHAT CAN NEVER BE CHOSEN IS NEVER PAID FOR, and there are now two of those.
      #
      # DOCUMENTS, because a scanned page cannot be a reference at any supply level.
      # MEASURED on a real Commons answer for "Drew Lock": 20 candidates, 12 of them
      # documents, so the shortlist this fills drops from 12 images to 8 — a third of
      # the bill, spent confirming that a book is not a face.
      #
      # AND A PHOTOGRAPH WHOSE TITLE NAMES SOMEBODY ELSE, for exactly the same reason:
      # `Drew Hutton.jpg` is refused by Appearances::ReferenceEligibility however well it
      # scores, so classifying it buys an answer we would not act on. This is the one
      # place in the change where the free wrong-person check SAVES money rather than
      # only preventing a blend.
      #
      # NOTHING ELSE IS SKIPPED, and the line is drawn where the REFERENCE verdict draws
      # it: a photograph that may be a reference is worth measuring, even if its face
      # size turns out to keep it away from the trainer, because the measurement is what
      # decides that.
      eligible = results.reject { |r| PhotoMerit.document?(r) || wrong_person?(r) }
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
      # the judgements are translated straight back rather than leaking a second
      # identity for the same photograph through the rest of this object.
      #
      # THE MAP IS THE ONLY TRANSLATION, so a judgement for a URL we did not send has
      # nowhere to land and is dropped, which is the same tolerance the classifier's
      # own parser applies to an index it cannot resolve.
      judged = @faces.call(hosted.values, target: @appearance) || {}
      hosted.each_with_object({}) do |(remote_url, our_url), out|
        value = judged[our_url]
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

    # MAY THIS CANDIDATE BE A REFERENCE AT ALL? Asked of
    # Appearances::ReferenceEligibility rather than answered here, so the verdict that
    # refuses a photograph is the same one the page prints and the same one
    # Appearances::ReferenceSet re-checks before either generator is paid.
    #
    # THE REFERENCE QUESTION, NOT THE MINT QUESTION. `.mint_verdict` is stricter by one
    # demand and is asked later, by the object that knows which vendor is about to be
    # billed.
    def reference_verdict(result, judgements)
      judgement = judgements[result.image_url]

      ReferenceEligibility.verdict(result, person_name: person_name,
                                      visibility: judgement&.visibility,
                                      fill: judgement&.fill,
                                      subjects: judgement&.subjects)
    end

    # THE FREE HALF OF THE PERSON CHECK, asked before anything is paid for. Its own
    # method because the shortlist and the verdict both need it and a second spelling of
    # "names somebody else" would let them disagree about who is in the picture.
    def wrong_person?(result) = PersonNaming.judge(result.title, person_name).names_other?

    # THREE BANDS, IN THE ORDER OF HOW MUCH IS KNOWN — and the top band is ordered by
    # FACE SIZE, which is the whole point of this ranking.
    #
    #   3.0 + fill + 0.1·visibility   something measured how big the face is
    #   1.0 + visibility              something looked, but reported no size
    #   merit (0.0..1.0)              nobody looked
    #
    # SIZE LEADS AND VISIBILITY ONLY BREAKS ITS TIES, at a tenth of the weight. Four
    # real mints on 2026-09-25 turned on size: a bare-faced 556x780 sideline shot
    # failed at prepare and a tight ESPN headshot completed, while the photograph the
    # old ranking put FIRST — scored 92 for visibility — is one the vendor refuses. A
    # ranking whose top result cannot be minted is not a ranking of anything the
    # operator can use.
    #
    # THE BANDS DO NOT OVERLAP, deliberately: "nobody looked at this" must not outrank
    # "something looked and saw a face", and must equally not be read as "something
    # looked and saw none". With no classifier at all every candidate falls to the
    # bottom band and the ordering is pure merit, exactly as before.
    FILL_BAND = 3.0
    VISIBILITY_BAND = 1.0
    VISIBILITY_TIEBREAK = 0.1

    def final_score(result, judgements)
      judgement = judgements[result.image_url]
      return merit(result) if judgement.nil?
      return VISIBILITY_BAND + judgement.visibility unless judgement.sized?

      FILL_BAND + judgement.fill + (VISIBILITY_TIEBREAK * judgement.visibility)
    end

    def merit(result)
      @merit ||= {}
      @merit[result.image_url] ||= PhotoMerit.score(result, person_name: person_name)
    end

    # THE REFUSAL THAT ACTUALLY HAPPENED, or the cap.
    #
    # THE VERDICT IS THE REASON, spelled the same way in both vocabularies — see
    # Appearances::ReferenceEligibility::REFUSALS and
    # AppearanceReferencePhoto::REJECTION_REASONS, which the suite asserts are the same
    # words. A mapping table here is where a new refusal would get forgotten and land
    # on the page as the old reassuring "past the limit".
    #
    # `beyond_limit` IS THE ONLY REASON THIS OBJECT AUTHORS, because the cap is the only
    # rule it owns. An ELIGIBLE candidate that did not make it in was fine and the list
    # was full, which is the one rejection that means RAISE THE CAP rather than FIX THE
    # SEARCH.
    def rejection_for(verdict, take)
      return nil if take
      return AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT if verdict == ReferenceEligibility::ELIGIBLE

      verdict.to_s
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
    def upsert(result, chosen:, rejection_reason:, judgement: nil)
      photo = AppearanceReferencePhoto.find_or_initialize_by(
        appearance_slug: @appearance.slug, image_url: result.image_url
      )
      return nil if photo.persisted? && !photo.from_search?

      photo.assign_attributes(
        evidence_attributes(result).merge(
          source: AppearanceReferencePhoto::SOURCE_SEARCH,
          chosen: chosen,
          rejection_reason: rejection_reason,
          # ONLY OVERWRITE A MEASUREMENT WITH A MEASUREMENT. A re-search whose
          # shortlist did not include this photograph must not erase the judgement the
          # last one paid for — that would turn "we looked in March" into "nobody has
          # ever looked" and re-sort the gallery on an absence we created.
          #
          # MEMBER BY MEMBER RATHER THAN JUDGEMENT BY JUDGEMENT, and that matters here:
          # a run against a model that answered a visibility and no face size must keep
          # the face size an earlier, better answer paid for, rather than blanking it
          # because the newest judgement is thinner.
          face_score: judgement&.visibility || photo.face_score,
          face_fill: judgement&.fill || photo.face_fill,
          face_subjects: judgement&.subjects || photo.face_subjects
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
