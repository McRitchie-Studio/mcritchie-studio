namespace :nfl do
  desc "For Athletes with espn_id, cache headshot variants in S3 + ImageCache. Idempotent. HEADSHOT_PAUSE=0.25 HEADSHOT_LIMIT=N"
  task upload_headshots: :environment do
    # HEADSHOT_PAUSE: seconds to wait after each ATTEMPTED upload, so a cold run
    # of ~2,000 candidates is a polite guest at a.espncdn.com rather than a
    # scraper. Paid only on an attempt, so the warm re-run — which fetches
    # nothing — is not slowed by it. HEADSHOT_PAUSE=0 disables it.
    # HEADSHOT_LIMIT: stop after N attempted uploads, so the cold run can be
    # taken in inspectable waves. The task is idempotent, so the next wave
    # resumes exactly where this one stopped; nothing records progress because
    # nothing has to — the ImageCache rows ARE the progress.
    pause = ENV.fetch("HEADSHOT_PAUSE", "0.25").to_f
    limit = ENV["HEADSHOT_LIMIT"].presence&.to_i

    # A LOCAL, resolved inside the task BODY. Binding the width list to a
    # namespace-level constant would read Athlete at task-DEFINITION time, which
    # runs before the `:environment` prerequisite and so before Zeitwerk can
    # autoload the model — a NameError on every `rake -T`.
    widths = Athlete::HEADSHOT_WIDTHS

    candidates = Athlete.where.not(espn_id: nil).includes(:image_caches)
    banner = "candidates: #{candidates.count} athletes; widths: #{widths.inspect}; pause: #{pause}s"
    banner += "; limit: #{limit} upload(s)" if limit
    puts banner

    considered = 0
    cached = 0
    skipped_complete = 0
    skipped_no_source = 0
    failed = 0
    misfiled = 0

    # THE POPULATION THE VERDICT GRADES, counted where the source is KNOWN to be
    # on file rather than derived afterwards. Derivation by subtraction is how the
    # false abort below got its denominator, and a subtraction cannot tell "the
    # lane walked past this" from "nothing could ever have been fetched for it".
    fetchable = 0

    # A DEAD SOURCE IS NOT A FAILED UPLOAD, and counting them together is what
    # made this task abort on a healthy production run. The fetch and the put are
    # two different parties: a 404 from a.espncdn.com is a fact about ESPN, a
    # failed `put_object` is a fact about us, and only the second one is the lane
    # not working. Both used to arrive through the one bare `rescue => e` below
    # and land in `failed`, which `failed > cached` then read as a broken
    # uploader.
    #
    # MEASURED ON PRODUCTION 2026-09-27, read-only:
    #
    #     TOTAL=2051  WITH_ESPN_ID=2048  COMPLETE_CANDIDATES=2043
    #     FETCHABLE=5  SOURCELESS_CANDIDATES=0
    #
    # Production's ENTIRE fetchable population is five athletes, every one of them
    # WITH an espn_headshot_url on file, and every one of those five URLs answers
    # 404 -- fetched the way this task fetches, `URI.open(url, read_timeout: 30,
    # redirect: true)`, while a control espn_id answered 230,577 bytes through the
    # same call. So the healthy steady state was `cached: 0, failed: 5`, the rule
    # fired, and the operator was told to go and check AWS credentials that were
    # fine. Athletes::DeadHeadshotSource carries the discrimination and the
    # reasoning for which statuses qualify.
    dead_source = 0

    # THE TWO RESIDUES, BY NAME, because a count alone asks the operator to go and
    # find out WHICH -- and a verdict that cannot be acted on is the verdict that
    # gets ignored.
    #
    # TWO LISTS RATHER THAN ONE, because they are two different chores. A
    # sourceless athlete needs the COLUMN filled (`rake nfl:players_seed`); a dead
    # source needs the PHOTO to exist at ESPN, which no task of ours can arrange.
    # Folding them together would print one list nobody can act on.
    #
    # MEASURED: on production `sourceless_slugs` is EMPTY. All three athletes with
    # no espn_headshot_url also have no espn_id, so `Athlete.where.not(espn_id:
    # nil)` never sees them and they are not candidates at all. The residue the
    # lane does see is the five dead sources.
    sourceless_slugs = []
    dead_source_notes = []

    # THE CAUSES, CARRIED ONTO THE CHANNEL THAT SURVIVES. The per-athlete `[!]`
    # lines below are `puts`, and the lane's only consumer runs this task with
    # `>/dev/null` and keeps stderr (bin/ecosystem-build, phase 6c) -- so an abort
    # saying "read the [!] lines above" pointed the operator at output the lane had
    # already discarded. The verdicts now carry the first few causes in their own
    # body, on stderr, where they can be read.
    failure_notes = []

    candidates.find_each do |athlete|
      # THE LIMIT BOUNDS EVERY ATHLETE THIS RUN REACHED FOR, dead sources
      # included. It is a politeness budget at a.espncdn.com, and a 404 costs the
      # same request and the same `sleep pause` as a hit -- so leaving them out
      # would let `HEADSHOT_LIMIT=10` walk a thousand retired photos.
      break if limit && (cached + failed + dead_source) >= limit

      considered += 1

      # THE FOLDER, RESOLVED BEFORE THE SKIP BRANCHES rather than at the upload
      # call site below, because the drift counter needs it on EVERY candidate --
      # including the thousands this task is about to walk past as complete. It is
      # a pure string built from a column already loaded, so hoisting it costs
      # nothing, and asking for it later would have cost the count.
      #
      # THE TEAM IS A FOLDER NAME, NOT A PRECONDITION. This task used to resolve
      # an NFL team through person.contracts and `next` past any athlete without
      # one, discarding the athlete over a cosmetic path segment it could have
      # defaulted. Athlete#headshot_key_prefix is now the only writer of this
      # string, shared with Nflverse::SeedPlayers, which had the fallback all
      # along.
      key_prefix = athlete.headshot_key_prefix

      rows = athlete.image_caches.select { |c| c.purpose == "headshot" }

      # THE COMPLETENESS CHECK BELOW CANNOT SEE A WRONG KEY, and that blindness is
      # why 2,043 athletes are stuck: a hand-rolled backfill derived the folder
      # from the EMPTY `contracts` table and filed every one of them under
      # `free-agents/`, rostered players included. All three variants are PRESENT,
      # so this task skips every one of them as complete -- forever, while printing
      # a clean summary. The drift is therefore COUNTED off the STORED key versus
      # the COMPUTED prefix, the only comparison that can see it, and the summary
      # names the task that repairs it.
      #
      # A WARNING, NEVER AN ABORT. A stale folder name still serves every avatar
      # correctly -- ImageCache#url reads the stored key and nothing rebuilds it
      # from the prefix -- so this is a taxonomy defect, not an outage, and
      # reddening a rebuild over a cosmetic path segment is how an operator learns
      # to stop reading the line.
      misfiled += 1 if rows.any? { |c| Athletes::RekeyHeadshots.misfiled?(c, key_prefix) }

      # "ALREADY DONE" HAS TO INCLUDE "original". Studio::ImageCache.cache!
      # stores the unmodified source as variant "original" PLUS one variant per
      # width, so a row set holding only 100 and 400 is not complete — and this
      # check used to call it complete, which both under-counts the work left and
      # corrupts the denominator the verdict below is computed from.
      #
      # ASKED OF THE MODEL, because the same definition decides the SKIP here and
      # the graded POPULATION below, and two spellings of one rule drift. Reads the
      # preloaded `image_caches`, so this costs no query per athlete.
      if athlete.headshot_complete?
        skipped_complete += 1
        next
      end

      # NO SOURCE URL IS A DATA GAP, NOT AN UPLOAD FAILURE. cache! raises a bare
      # ArgumentError without one, which the rescue below would file under
      # `failed` and the abort above would then blame on AWS credentials that are
      # fine. Counted separately for the same reason upload_coach_headshots
      # counts its `without_url`.
      # ASKED THROUGH THE PREDICATE THE VERDICT GRADES, not of the column directly.
      # Past the completeness gate above, Athlete#headshot_fetchable? reduces to "is
      # there a source on file" — so this reads the same as the `blank?` check it
      # replaced, and cannot drift from the population the rules below are written
      # against. ORDER MATTERS: the predicate is also false for a COMPLETE athlete,
      # so it must stay below the completeness gate or a finished athlete would be
      # filed as sourceless.
      unless athlete.headshot_fetchable?
        skipped_no_source += 1
        sourceless_slugs << athlete.person_slug
        next
      end

      # PAST THE SOURCE GATE, SO THE LANE CAN BE HELD TO THIS ONE. Incremented HERE,
      # after the only branch that can prove no source exists, which is what makes
      # "sourceless athletes never trip the verdict" a property of the code rather
      # than of the current data.
      fetchable += 1

      begin
        Studio::ImageCache.cache!(
          owner: athlete,
          purpose: "headshot",
          source_url: athlete.espn_headshot_url,
          key_prefix: key_prefix,
          widths: widths,
          content_type: "image/png"
        )
        cached += 1
        puts "  [+] #{athlete.person_slug.ljust(28)} -> #{key_prefix}/{original,#{widths.join(',')}}.png" if cached <= 5 || (cached % 50).zero?
      rescue => e
        # SPLIT HERE, WHERE THE DIFFERENCE IS KNOWN. The exception object is the
        # only thing that can tell a dead source from a broken uploader; a count
        # cannot, and a count is what the retired rule tried to reason from. So
        # the classification happens with the exception in hand and the two
        # outcomes never share a counter.
        # ASKED THROUGH `dead?`, NEVER BY RE-TESTING THE STATUS HERE. The status
        # is read only to PRINT it; spelling the rule a second time at the call
        # site is how two definitions of one thing start to drift.
        if Athletes::DeadHeadshotSource.dead?(e)
          dead_source += 1
          dead_source_notes << "#{athlete.person_slug} (espn_id #{athlete.espn_id}): " \
                               "HTTP #{Athletes::DeadHeadshotSource.status(e)}"
        else
          failed += 1
          failure_notes << "#{athlete.person_slug}: #{e.class}: #{e.message.to_s.truncate(60)}"
          puts "  [!] #{athlete.person_slug}: #{e.class}: #{e.message}"
        end
      end

      sleep pause if pause.positive?
    end

    # READ THE LANE LEFT TO RIGHT: wanted it -> a source could answer -> the source
    # answered -> the upload worked. Each step is a different question and only the
    # LAST one grades the lane; a gap at either of the middle steps is a fact about
    # ESPN and must be silent.
    #
    #   wanted       candidates that still LACKED a variant  (considered - complete)
    #   fetchable    of those, ones with a source on file    (accumulated above)
    #   attempted    candidates this run reached for         (cached + failed + dead)
    #   graded       attempts whose outcome is OURS          (cached + failed)
    #   unfetched    fetchable, and walked past anyway       (fetchable - attempted)
    #   unclassified wanted, skipped for no stated reason    (the subtraction guard)
    #
    # `attempted` AND `graded` ARE DIFFERENT DENOMINATORS ON PURPOSE, and keeping
    # them apart is this fix. `attempted` answers "did the run do the work it
    # found", so a dead source belongs in it -- the request went out, the pause was
    # paid, and there is nothing more the lane could have done. `graded` answers
    # "did OUR half work", so a dead source must NOT be in it: 404s in that
    # numerator are what made `failed > cached` fire on a healthy run.
    #
    # `needed` IS RETIRED, and it was the first half of this defect. It was
    # `wanted` -- every candidate short of a variant, INCLUDING the ones no source
    # can ever complete -- so the decline rule below accused the lane of declining
    # work no run could have done, and could only be cleared by filling a column
    # the lane does not write. A VERDICT MUST BE CLEARABLE BY FIXING WHAT IT
    # ACCUSES, so the graded population holds only athletes a source could have
    # answered for.
    #
    # MEASURED, AND THE RETIREMENT'S OWN ACCOUNT OF PRODUCTION WAS WRONG: it said
    # eight athletes had no espn_headshot_url and kept `needed` positive against
    # `attempted` 0. Production 2026-09-27 says THREE have no espn_headshot_url,
    # all three also have no espn_id, and so none of the three is a candidate --
    # `skipped_no_source` is 0 there. The abort operators actually got was the
    # OTHER rule: `needed` 5, `attempted` 5, `failed` 5 > `cached` 0, every failure
    # a 404. The narrowing to `fetchable` is still right, as a property rather than
    # as a reading of this data: it makes an unclearable verdict impossible.
    #
    # `unfetched` AND `unclassified` KEEP THE SUBTRACTION GUARD the old `needed`
    # had, which is worth preserving: a `next` added later lands in one of them
    # without being told to report itself. Which one depends on where it goes --
    # after the source gate it is `unfetched` (the lane declined fetchable work),
    # before it `unclassified` (a skip nobody told the verdict about). Both are
    # reported. Hand-counting is how the original hole got dug: `skipped_no_team`
    # was faithfully counted AND printed, and no rule read it.
    wanted       = considered - skipped_complete
    graded       = cached + failed
    attempted    = graded + dead_source
    unfetched    = fetchable - attempted
    unclassified = wanted - skipped_no_source - fetchable

    # THE CAUSES AS ONE SENTENCE, built once because BOTH graded verdicts below say
    # it and two spellings of one sentence drift. THREE is enough to tell
    # `Aws::Errors::MissingCredentialsError` from `OpenURI::HTTPError: 503` and
    # short enough to read in a rebuild log; anyone running the task by hand still
    # has every `[!]` line on stdout. Empty when nothing failed, which is every run
    # where neither verdict below fires.
    cause_cap = 3
    causes = if failure_notes.any?
      more = failure_notes.size - cause_cap
      "Causes: #{failure_notes.first(cause_cap).join('; ')}" \
        "#{more.positive? ? " (and #{more} more)" : ''}. "
    else
      ""
    end

    puts ""
    puts "considered:             #{considered}"
    puts "skipped (already done): #{skipped_complete}"
    puts "wanted a headshot:      #{wanted}"
    puts "  no espn_headshot_url: #{skipped_no_source}   (a data gap -- never graded)"
    puts "  fetchable:            #{fetchable}   (the population the rules below grade)"
    puts "cached:                 #{cached}"
    puts "dead source (404/410):  #{dead_source}   (a data gap -- never graded)"
    puts "failed:                 #{failed}"
    puts "misfiled (stale key):   #{misfiled}"

    # 25 IS A READABILITY CEILING SHARED BY BOTH INVENTORIES BELOW, not a claim
    # about the data. A cold run before any seed has hundreds in either list, and a
    # wall of slugs is how a report stops being read. MEASURED: production's two
    # residues are 0 sourceless candidates and 5 dead sources, so the cap fires on
    # neither and both lists print whole. A LOCAL rather than a constant, for the
    # reason the widths list is one: nothing in this file needs it at definition
    # time.
    named_cap = 25

    if sourceless_slugs.any?
      # ON STDOUT WITH THE COUNTERS, NOT ON STDERR WITH THE VERDICTS. A permanent
      # data gap appears on every run for ever, and a signal printed on every
      # healthy run is not a signal. It is inventory, so it sits with the
      # inventory, and it names the task that can shorten the list.
      #
      # MEASURED: this list is EMPTY on production. All three athletes with no
      # espn_headshot_url also have no espn_id, so they are not candidates and the
      # loop never reaches them. The residue the lane DOES see is the dead-source
      # list below. Kept because the column is nullable and a cold run before any
      # seed fills it has thousands.
      shown = sourceless_slugs.first(named_cap)
      remaining = sourceless_slugs.size - shown.size
      puts ""
      puts "  athletes with NO espn_headshot_url -- nothing to fetch, so nothing the lane"
      puts "  is graded on. `rake nfl:players_seed` fills the column where a source exists;"
      puts "  some of these have none and will appear here for ever:"
      shown.each { |slug| puts "    [-] #{slug}" }
      puts "    ... and #{remaining} more" if remaining.positive?
    end

    if dead_source_notes.any?
      # THE OTHER RESIDUE, AND ON PRODUCTION THE ONLY ONE. A SEPARATE LIST from the
      # sourceless slugs above because it is a different chore with a different
      # remedy: that one needs a COLUMN filled, this one needs a PHOTO to exist at
      # ESPN. One merged list would be a list nobody can act on.
      #
      # ON STDOUT, for the same reason and with the same consequence: the lane
      # discards it. That is correct for inventory that prints on every healthy run
      # for ever, and it is why the espn_id and the status are ON each line -- the
      # operator reading this report is the one who can go and look, and the status
      # is what tells them whether looking is worth it (404 is permanent, and a 503
      # would never have reached this list).
      #
      # NOTHING HERE REPAIRS THE DATA, deliberately. Chasing a fresh URL for a
      # retired photo is a different job from grading a run correctly, and mixing
      # the two would mean a verdict fix that also writes rows.
      shown = dead_source_notes.first(named_cap)
      remaining = dead_source_notes.size - shown.size
      puts ""
      puts "  athletes whose ESPN source ANSWERED 404/410 -- the URL is on file and this run"
      puts "  fetched it, so the lane did its job and the shelf was empty. A dead source is a"
      puts "  data gap, never a failed upload, and nothing here grades the lane."
      puts "  `rake nfl:players_seed` re-derives the URL from espn_id; where ESPN has retired"
      puts "  the photograph there is nothing to re-derive and these appear here for ever:"
      shown.each { |note| puts "    [x] #{note}" }
      puts "    ... and #{remaining} more" if remaining.positive?
    end

    if misfiled.positive?
      warn "nfl:upload_headshots: #{misfiled} athletes carry headshot rows filed under a stale " \
           "key. This task cannot repair them -- it grades \"already done\" by VARIANT PRESENCE " \
           "and never by key, so it skips every one of them as complete. Run " \
           "`rake nfl:rekey_headshots` to re-file them under Athlete#headshot_key_prefix."
    end

    # THE PER-ATHLETE RESCUE ABOVE IS RIGHT; ENDING ON `puts` WAS NOT. One dead
    # ESPN headshot URL must not cost the other thousand their upload, so each
    # failure is counted and the loop continues — and then the task returned
    # normally, so the process exited 0 no matter how many failed. MEASURED with
    # three manufactured candidates and Studio::ImageCache.cache! raising the
    # real Aws::Errors::MissingCredentialsError: `failed: 3`, `cached: 0`, exit
    # 0. That is the credential failure the phase-6c log line has been telling
    # operators to go and check, reported as a success.
    #
    # GRADED ON THE MAJORITY, not on `failed.positive?`. More failures than
    # successes cannot be one bad URL — it is the uploader not working, which is
    # what a credential failure looks like from here: every attempt fails, so
    # `cached` is 0 and `failed` is everything.
    #
    # THE DEFERRAL THAT USED TO SIT HERE IS DISCHARGED, and not by the answer it
    # expected. It read: "THE MAJORITY IS ONLY AS GOOD AS THE SAMPLE... One new
    # athlete whose ESPN headshot 404s is then failed: 1, cached: 0, which clears
    # this rule and aborts... Narrowing to a meaningful sample changes behaviour
    # and owes its own test." It was filed as hypothetical. MEASURED ON PRODUCTION
    # 2026-09-27, it was the WHOLE fetchable population: 5 of 5, every one a 404,
    # and this rule aborted the rebuild on a run where nothing was wrong.
    #
    # THE SAMPLE NEVER NEEDED NARROWING; THE NUMERATOR WAS WRONG. A 404 was never a
    # failed upload, so the answer is not "how many failures are too few to
    # believe" -- a threshold nobody could have defended from these counters -- but
    # "that was not a failure". `graded` is `cached + failed` with the dead sources
    # taken out at the point the exception said so, which is why this rule can stay
    # a plain majority and still be quiet on the warm re-run.
    #
    # WHAT IS STILL TRUE OF THE SAMPLE, because the old comment was right about
    # this part: on a warm machine `graded` counts only the newly-discovered
    # espn_ids, so it is often one or two. A single REAL failure -- a transient 5xx
    # from S3, say -- therefore still reddens a run. That is the correct trade now
    # that a 404 cannot reach the numerator: a genuine upload failure on the only
    # athlete this run tried IS a run that did not work, and the task is idempotent
    # so the next run clears it.
    #
    # THE CAUSES TRAVEL WITH THE VERDICT. The `[!]` lines are on stdout and
    # bin/ecosystem-build runs this task with `>/dev/null`, so "read the [!] lines
    # above" pointed at output the lane had already thrown away. The first few
    # `slug: ExceptionClass: message` pairs now ride in the abort body itself, on
    # stderr, which the lane keeps -- one look tells an operator whether this is
    # AWS or ESPN without changing a credential first.
    if failed > cached
      warn "nfl:upload_headshots: #{failed} of #{graded} attempted uploads failed"
      abort "nfl:upload_headshots failed #{failed} of #{graded} attempted uploads " \
            "(cached #{cached}#{dead_source.positive? ? "; #{dead_source} more had a dead " \
            "source and are NOT counted here" : ""}) — #{causes}" \
            "Across MANY attempts this is usually AWS credentials: check AWS_ACCESS_KEY_ID / " \
            "AWS_SECRET_ACCESS_KEY / AWS_REGION in .env. A 404 or 410 from a.espncdn.com is " \
            "NOT in this count — dead sources are named in the report on stdout."

    # THE PARTIAL FAILURE, WARNED ABOUT RATHER THAN ABORTED ON, and it needs saying
    # at all BECAUSE the rule above grades a majority. Credentials revoked at
    # athlete 1,900 leave cached 1,900 / failed 143: the majority rule is false, the
    # run exits 0, and 143 [!] lines scroll past on STDOUT while the rebuild lane —
    # which reads stderr — is told nothing. An abort would be wrong: 143 transient
    # S3 errors among 2,043 good uploads is a normal afternoon, and a rule that
    # reddens on one gets switched off. A threshold would only swap the false
    # positive for a number nobody can defend from these counters, and an exit code
    # is the wrong place for a guess — it carries one bit and cannot say "partly
    # worked". So the gap becomes a SENTENCE on the channel the lane reads. The task
    # is idempotent, so a systemic failure this warning does not stop is caught by
    # the next run one run late rather than never.
    #
    # IT NO LONGER BLAMES ESPN. This warning used to say each failure was "more
    # likely a dead ESPN source URL than a credential problem" — which was the same
    # conflation the rule above carried, guessed instead of measured. A dead source
    # cannot reach `failed` any more, so whatever is in here is OURS or a transient,
    # and the causes say which.
    elsif failed.positive?
      warn "WARNING: nfl:upload_headshots failed #{failed} of #{graded} attempted uploads " \
           "(cached #{cached}) — too few to be the uploader breaking, so this is more likely a " \
           "transient than a credential problem. #{causes}" \
           "Dead ESPN sources are NOT in this count. The task is idempotent, so re-running it " \
           "retries only these."
    end

    # THE SECOND HOLE, AND THE ONE THAT COST 2,048 ATHLETES THEIR AVATAR. The
    # rule above grades the ATTEMPTS, so it is structurally blind to a run that
    # made none: with `cached` 0 and `failed` 0, `failed > cached` is false and
    # the task returns normally. MEASURED on production 2026-09-26, against the
    # contract precondition this task carried until today: `candidates: 2048`,
    # `cached: 0`, `skipped (no NFL team): 2048`, exit 0. `contracts` and `teams`
    # are both EMPTY tables in production — 0 rows each — so that precondition
    # could never be satisfied by anybody, and the task had cached nothing, ever,
    # while printing a clean summary every time somebody ran it. Nobody noticed
    # for as long as the task existed. That is what a silent success costs.
    #
    # GRADED ON WHETHER THE RUN DID THE WORK IT FOUND, which is a different
    # question from whether its attempts succeeded, and the reason this is a
    # SECOND rule rather than a rewrite of the first. The two are disjoint by
    # construction: `attempted.zero?` forces `failed == cached == 0`, so
    # `failed > cached` is false exactly when this can fire.
    #
    # IT CANNOT CRY WOLF ON THE WARM RE-RUN, and an earlier version of this block
    # argued that from a figure production does not carry. It said eight athletes
    # had no espn_headshot_url, so `needed` never reached 0 and this fired on every
    # healthy run. MEASURED 2026-09-27: THREE athletes have no espn_headshot_url,
    # all three also have no espn_id, and so not one of them is a candidate --
    # `skipped_no_source` is 0 on production and this rule never fired there at all.
    # What fired was the OTHER rule, on five 404s. Graded on `fetchable` the
    # quiet-on-a-warm-run claim is true as a PROPERTY of the population rather than
    # as a reading of today's rows, which is the only way it was ever worth making.
    #
    # WHAT IT STAYS QUIET ABOUT -- and this list is the rule, not a footnote,
    # because a verdict that fires on a healthy run gets switched off within a week:
    #
    #   * a complete athlete is never counted as wanting one, so the warm re-run
    #     has wanted == 0 and this says nothing;
    #   * an athlete with NO espn_headshot_url is counted as WANTING a headshot and
    #     not as fetchable, so a permanent data gap is silent -- it is named in the
    #     report above instead, which is where a chore belongs;
    #   * an athlete whose source ANSWERED 404 counts as attempted, because the run
    #     did reach for it and there was nothing there. Leaving dead sources out of
    #     `attempted` would make this rule fire on exactly production's steady state
    #     -- fetchable 5, every one dead -- which is the trap the other rule fell
    #     into from the other side.
    #
    # A PARTIAL decline only warns, because a partial is not a lane that stopped
    # working and an exit code carries one bit that cannot say "partly".
    #
    # ── THIS RULE IS UNREACHABLE TODAY AND STAYS. VERDICT, 2026-09-27 ────────────
    #
    # Nothing sits between `fetchable += 1` and the attempt, and every path out of
    # that attempt increments exactly one of `cached`, `dead_source` or `failed` --
    # so `attempted` always equals `fetchable` and this condition cannot be true.
    # (The `HEADSHOT_LIMIT` break does not reach it either: it breaks BEFORE
    # `considered += 1`, so the athletes it skips were never counted as fetchable.)
    # Two readers have now measured that independently.
    #
    # IT IS A GUARD AWAITING A FUTURE BRANCH, NOT DEAD CODE, and the difference is
    # WHERE a future `next` would land. `unclassified` below catches one added ABOVE
    # the source gate; this rule and `unfetched` catch one added BELOW it. Below the
    # source gate is precisely where the historical defect lived -- the `next` past
    # any athlete without an NFL contract, which cost 2,048 athletes their avatar
    # and printed a clean summary while doing it. Deleting this would leave the half
    # of the loop with a track record uncovered, and it would be deleted for the
    # reason it was written: nothing has happened there yet.
    #
    # WHY THIS ONE ABORTS WHERE `unfetched` ONLY WARNS: declining EVERY fetchable
    # athlete is the lane refusing its job wholesale, which is the 2,048 shape;
    # declining some of them is a partial, and a partial is a sentence, not an exit
    # code. Said plainly here so the next reader who measures it does not have to
    # re-litigate it, and does not mistake "no test can reach it" for "no reason".
    if fetchable.positive? && attempted.zero?
      warn "nfl:upload_headshots: attempted 0 of #{fetchable} athletes it could have fetched"
      abort "nfl:upload_headshots attempted 0 of the #{fetchable} athletes that still needed a " \
            "headshot AND had an espn_headshot_url to fetch — it declined every one of them " \
            "WITHOUT trying, so this is the task refusing its job, not S3 refusing the upload. " \
            "Every one of them was fetchable, so no data gap explains it: read the skip " \
            "branches in this task. (The #{skipped_no_source} athletes with no " \
            "espn_headshot_url are NOT in this count — they are named in the report above.)"
    elsif unfetched.positive?
      warn "nfl:upload_headshots: #{unfetched} of #{fetchable} fetchable athletes were skipped " \
           "without an attempt — each had an espn_headshot_url on file, so this is the lane " \
           "walking past work it could have done"
    end

    # THE SUBTRACTION GUARD, REPORTED. Zero on every path this task has today: the
    # source gate is the only branch between "wanted one" and "tried", so `wanted`
    # minus the sourceless minus the fetchable is exactly 0. It is computed anyway
    # because that is how the FIRST hole stayed open -- `skipped_no_team` was
    # counted, printed, and read by no rule. A `next` added above the source gate
    # lands here instead of vanishing, and says so rather than aborting, because a
    # skip nobody has classified yet is not yet known to be a failure.
    if unclassified.positive?
      warn "nfl:upload_headshots: #{unclassified} of #{wanted} athletes that wanted a headshot " \
           "were skipped for a reason no verdict here classifies. A skip branch was added " \
           "without telling the verdict about it — classify it as a data gap (counted like " \
           "espn_headshot_url) or as the lane declining work (counted like fetchable)."
    end
  end

  desc "Re-file cached athlete headshots under Athlete#headshot_key_prefix where the stored key disagrees. Idempotent. REKEY_LIMIT=N REKEY_KEEP_ORPHANS=1"
  task rekey_headshots: :environment do
    # A SEPARATE TASK, NOT A MODE OF nfl:upload_headshots, and the split is
    # deliberate. The two jobs differ in what they do and in how a bad run is
    # graded: `upload_headshots` CREATES missing variants by fetching ESPN, and its
    # two verdicts read `cached`/`failed`/`needed` -- counters that describe upload
    # attempts. A re-key MOVES bytes that are already in the bucket and fetches
    # nothing, so folding it in would mean feeding a second population into those
    # denominators, which is precisely the hand-counted-verdict hole both of those
    # rules carry a comment block about. What DOES belong in the other task is the
    # DETECTION -- it now counts misfiled athletes and names this task -- because
    # the reason 2,043 rows are stuck is that the rebuild could not see them.
    #
    # REKEY_LIMIT: stop after N re-keyed athletes, so a ~2,000-athlete repair can
    # be taken in inspectable waves. The task is idempotent, so the next wave
    # resumes exactly where this one stopped; nothing records progress because
    # nothing has to -- the ImageCache rows ARE the progress.
    #
    # REKEY_KEEP_ORPHANS=1: repoint the rows and LEAVE the old objects where they
    # are. The default deletes them, and only ever after the new object is written
    # AND the row has been repointed onto it; Athletes::RekeyHeadshots documents
    # why that order is the whole design. Set this when you want to eyeball the
    # result before anything is destroyed.
    limit = ENV["REKEY_LIMIT"].presence&.to_i
    keep_orphans = ENV["REKEY_KEEP_ORPHANS"] == "1"

    stats = Athletes::RekeyHeadshots.new(limit: limit, delete_orphans: !keep_orphans).call

    # THE SAME THREE NUMBERS nfl:upload_headshots GRADES ITSELF ON, and derived
    # the same way for the same reason.
    #
    #   needed      candidates whose stored key disagreed  (considered - already_filed)
    #   attempted   candidates this run actually moved     (rekeyed + failed)
    #   unattempted needed, and walked past anyway         (needed - attempted)
    #
    # `unattempted` is DERIVED, never accumulated. Today nothing can land in it:
    # there is no `next` between the staleness check and the move, so it is a NET
    # for a skip branch added later rather than a path this run can take. Stated
    # plainly because a guard that reads as load-bearing and is not gets deleted
    # by the next person who measures it.
    considered  = stats[:considered]
    already     = stats[:already_filed]
    rekeyed     = stats[:rekeyed]
    failed      = stats[:failed]
    needed      = considered - already
    attempted   = rekeyed + failed
    unattempted = needed - attempted

    puts ""
    puts "re-keyed:               #{rekeyed}"
    puts "already filed:          #{already}"
    puts "objects copied:         #{stats[:objects_copied]}"
    puts "objects already there:  #{stats[:objects_already_present]}"
    puts "orphans deleted:        #{stats[:orphans_deleted]}"
    puts "failed:                 #{failed}"

    # GRADED ON THE MAJORITY, exactly as the uploader is. One unreadable object is
    # an afternoon S3 is having; more failures than successes is the mover not
    # working, which from here is what a credential or permission failure looks
    # like -- every attempt fails, so `rekeyed` is 0 and `failed` is everything.
    # A tie at zero is nothing to do, not a failure, so this cannot fire on it.
    if failed > rekeyed
      warn "nfl:rekey_headshots: #{failed} of #{attempted} attempted re-keys failed"
      abort "nfl:rekey_headshots failed #{failed} of #{attempted} attempted re-keys " \
            "(re-keyed #{rekeyed}) -- read the [!] lines above, which name the cause per " \
            "athlete. Across MANY attempts this is usually S3 access: check " \
            "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION, and that the key may " \
            "GetObject, PutObject and DeleteObject on the bucket. NO AVATAR WAS LOST: a " \
            "failed athlete's rows still point at the objects they always did."
    end

    if needed.positive? && attempted.zero?
      warn "nfl:rekey_headshots: attempted 0 of #{needed} misfiled athletes"
      abort "nfl:rekey_headshots found #{needed} misfiled athletes and moved none of them " \
            "WITHOUT trying, so this is the task declining its job rather than S3 refusing " \
            "the copy. A skip count that equals the misfiled count is never a successful run."
    elsif unattempted.positive?
      warn "nfl:rekey_headshots: #{unattempted} of #{needed} misfiled athletes were skipped " \
           "without an attempt"
    end

    # THE ORDERING'S OWN SAFETY CATCH, REPORTED. An old key still referenced by an
    # ImageCache row is never deleted, and reaching that branch means the repoint
    # did not land where this expected -- worth an operator's eye even though the
    # outcome (an object kept) is the safe one.
    if stats[:orphans_held].positive?
      warn "nfl:rekey_headshots: kept #{stats[:orphans_held]} old object(s) because an " \
           "ImageCache row still references them -- nothing was deleted out from under a " \
           "live row, but the repoint did not land as expected. Re-run to retry."
    end

    # AN UNDELETED ORPHAN IS INERT: no row points at it, so it serves nothing and
    # costs storage. Reported, never fatal -- the repair itself succeeded.
    if stats[:orphans_failed].positive?
      warn "nfl:rekey_headshots: #{stats[:orphans_failed]} old object(s) could not be deleted. " \
           "They are unreferenced, so they serve nothing; re-run to retry the cleanup."
    end
  end

  ESPN_TEAMS_INDEX_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams"
  ESPN_TEAM_COACHES_URL = ->(team_id) { "https://sports.core.api.espn.com/v2/sports/football/leagues/nfl/teams/#{team_id}/coaches" }
  COACH_HEADSHOT_WIDTHS = [100, 400].freeze

  desc "Pull NFL head coaches from ESPN; populate Coach espn_id + espn_headshot_url. No S3 traffic."
  task link_coach_headshots: :environment do
    require "open-uri"
    require "json"

    teams_by_abbrev = Team.where(league: "nfl").index_by(&:short_name).merge(
      "LA"  => Team.find_by(slug: "los-angeles-rams"),
      "WSH" => Team.find_by(slug: "washington-commanders")
    )

    puts "Fetching ESPN team index..."
    teams_resp = JSON.parse(URI.open(ESPN_TEAMS_INDEX_URL).read)
    espn_teams = teams_resp.dig("sports", 0, "leagues", 0, "teams").map { |t| t["team"] }
    puts "  #{espn_teams.size} ESPN teams"

    matched = 0
    skipped_unchanged = 0
    skipped_no_team = 0
    skipped_no_coach = 0
    failed = 0

    espn_teams.each do |et|
      espn_team_id = et["id"]
      espn_abbrev  = et["abbreviation"]
      our_team     = teams_by_abbrev[espn_abbrev]

      unless our_team
        skipped_no_team += 1
        puts "  [?] No team match for ESPN abbrev=#{espn_abbrev}"
        next
      end

      coaches_resp = JSON.parse(URI.open(ESPN_TEAM_COACHES_URL.call(espn_team_id)).read)
      ref = coaches_resp.dig("items", 0, "$ref")
      unless ref
        skipped_no_coach += 1
        next
      end

      coach_resp = JSON.parse(URI.open(ref).read)
      espn_id = coach_resp["id"].to_s
      headshot_url = coach_resp.dig("headshot", "href")
      first = coach_resp["firstName"]
      last  = coach_resp["lastName"]
      espn_person_slug = "#{first} #{last}".parameterize

      coach = Coach.find_by(team_slug: our_team.slug, role: "head_coach", person_slug: espn_person_slug) ||
              Coach.find_by(team_slug: our_team.slug, role: "head_coach")

      unless coach
        skipped_no_coach += 1
        puts "  [?] #{our_team.slug.ljust(25)} no Coach record (ESPN HC: #{first} #{last})"
        next
      end

      if coach.person_slug != espn_person_slug
        puts "  [~] #{our_team.slug.ljust(25)} ESPN says HC=#{first} #{last}, we have #{coach.person.full_name}"
      end

      if coach.espn_id == espn_id && coach.espn_headshot_url == headshot_url
        skipped_unchanged += 1
      else
        coach.update!(espn_id: espn_id, espn_headshot_url: headshot_url)
        matched += 1
        puts "  [+] #{our_team.slug.ljust(25)} #{first} #{last} (espn_id=#{espn_id})"
      end
    rescue => e
      failed += 1
      puts "  [!] error for #{espn_abbrev}: #{e.class}: #{e.message}"
    end

    puts ""
    puts "matched/updated:      #{matched}"
    puts "skipped (unchanged):  #{skipped_unchanged}"
    puts "skipped (no team):    #{skipped_no_team}"
    puts "skipped (no Coach):   #{skipped_no_coach}"
    puts "failed:               #{failed}"
  end

  # Maps our team_slug to the team's official NFL.com subdomain.
  # Used to scrape the team's coaches roster page when ESPN's coach API
  # doesn't provide a headshot.href (which is the case for ~21/32 HCs and
  # for every coordinator).
  COACH_ROLE_LABELS = {
    "head coach"                 => "head_coach",
    "offensive coordinator"      => "offensive_coordinator",
    "defensive coordinator"      => "defensive_coordinator",
    "special teams coordinator"  => "special_teams_coordinator"
  }.freeze

  desc "Scrape each team's NFL.com coaches roster page; populate Coach espn_headshot_url where missing. Covers HC + 3 coordinators per team."
  task link_coach_headshots_from_team_sites: :environment do
    require "open-uri"
    require "nokogiri"

    matched = 0
    skipped_unchanged = 0
    skipped_no_coach = 0
    skipped_no_image = 0
    failed_team = 0

    Team.where(league: "nfl").where.not(coaches_url: nil).find_each do |team|
      team_slug = team.slug
      # Try Team.coaches_url first; if it 404s, try the alternate /team/coaches-roster/
      # path (Buccaneers and Titans use coaches-roster instead of coaches).
      candidate_urls = [team.coaches_url]
      if team.coaches_url.include?("/team/coaches/")
        candidate_urls << team.coaches_url.sub("/team/coaches/", "/team/coaches-roster/")
      elsif team.coaches_url.include?("/team/coaches-roster/")
        candidate_urls << team.coaches_url.sub("/team/coaches-roster/", "/team/coaches/")
      end

      html = nil
      candidate_urls.each do |url|
        html = URI.open(url, read_timeout: 15, "User-Agent" => "Mozilla/5.0").read
        break
      rescue OpenURI::HTTPError, SocketError, Net::OpenTimeout, Net::ReadTimeout
        next
      end

      unless html
        failed_team += 1
        puts "  [!] #{team_slug.ljust(25)} no coach page found (tried #{candidate_urls.size} URLs)"
        next
      end

      doc = Nokogiri::HTML(html)

      # Each coach card is the smallest ancestor of a coach link that contains
      # both a role label and an <img>.
      doc.css("a[href*='/team/coaches/'], a[href*='/team/coaches-roster/']").each do |link|
        href = link["href"].to_s
        next if href.match?(/coaches(?:-roster)?\/(index|all-time)?$/)

        card = link.ancestors.find { |n| n.css("img").any? }
        next unless card

        # Strip "Assistant Head Coach" / "Associate Head Coach" so they don't
        # match the bare "head coach" label.
        text = card.text.gsub(/(assistant|associate|interim|senior)\s+(head\s+coach|offensive\s+coordinator|defensive\s+coordinator|special\s+teams\s+coordinator)/i, "")
        role_label = COACH_ROLE_LABELS.keys.find { |label| text.match?(/#{Regexp.escape(label)}/i) }
        next unless role_label
        role = COACH_ROLE_LABELS[role_label]

        img = card.css("img").first
        img_url = img["src"].to_s.start_with?("http") ? img["src"] : img["data-src"].to_s
        if img_url.empty? || img_url.start_with?("data:")
          skipped_no_image += 1
          next
        end

        # Force a known-good high-res Cloudinary transform. NFL.com's default
        # mobile variant is ~12KB and gets blurry on hover. We strip whatever
        # transform stack is present and pin "t_headshot_desktop_3x/f_auto" —
        # works on both /image/upload/ (public) and /image/private/
        # (auth-required without a transform) paths, and yields a clean
        # ~80KB color portrait. Crucially do NOT include "t_lazy" — that's
        # Cloudinary's grayscale placeholder transform.
        img_url = img_url.sub(
          %r{(/image/(?:upload|private)/)(?:[a-z]+_[^/]+/)*},
          '\1t_headshot_desktop_3x/f_auto/'
        )

        person_slug = href.split("/").last.parameterize
        coach = Coach.find_by(team_slug: team_slug, role: role, person_slug: person_slug)

        unless coach
          skipped_no_coach += 1
          # Surface mismatch so seed can be corrected later
          our_coach = Coach.find_by(team_slug: team_slug, role: role)
          puts "  [~] #{team_slug.ljust(25)} #{role.ljust(28)} NFL.com=#{person_slug}, our DB has #{our_coach&.person_slug.inspect}"
          next
        end

        if coach.espn_headshot_url == img_url
          skipped_unchanged += 1
        else
          coach.update!(espn_headshot_url: img_url)
          matched += 1
          puts "  [+] #{team_slug.ljust(25)} #{role.ljust(28)} #{coach.person.full_name}" if matched <= 8 || (matched % 25).zero?
        end
      end
    end

    puts ""
    puts "matched/updated:      #{matched}"
    puts "skipped (unchanged):  #{skipped_unchanged}"
    puts "skipped (no Coach):   #{skipped_no_coach}"
    puts "skipped (no image):   #{skipped_no_image}"
    puts "failed (team page):   #{failed_team}"
  end

  desc "For Coaches with espn_headshot_url (from ESPN or NFL.com), cache variants. Idempotent."
  task upload_coach_headshots: :environment do
    with_url    = Coach.where.not(espn_headshot_url: nil).includes(:image_caches)
    without_url = Coach.where(sport: "football", espn_headshot_url: nil).count
    puts "candidates: #{with_url.count} coaches with headshot URL; #{without_url} football coaches with no image source; widths: #{COACH_HEADSHOT_WIDTHS.inspect}"

    cached = 0
    skipped_complete = 0
    failed = 0
    refreshed = 0

    with_url.find_each do |coach|
      headshots = coach.image_caches.select { |c| c.purpose == "headshot" }

      # Stale cache: coach.espn_headshot_url has changed since the variants
      # were uploaded. Sources differ across rows, OR all rows point to a
      # URL that no longer matches the current one. Wipe and re-upload so
      # 100w and 400w aren't from different photos (e.g., McVay's old ESPN
      # B&W still cached at 100w while 400w came from a later NFL.com URL).
      cached_sources = headshots.map(&:source_url).uniq
      if headshots.any? && (cached_sources.size > 1 || cached_sources.first != coach.espn_headshot_url)
        ImageCache.where(owner: coach, purpose: "headshot").destroy_all
        # Note: the S3 objects stay (orphaned). Studio::ImageCache.cache! will
        # overwrite them on re-upload since the s3_key is deterministic.
        headshots = []
        refreshed += 1
      end

      have = headshots.map(&:variant)
      if (["original"] + COACH_HEADSHOT_WIDTHS.map(&:to_s) - have).empty?
        skipped_complete += 1
        next
      end

      # Use coach.slug (person-team-role) for the S3 path so coaches with the
      # same person_slug across teams/roles don't collide.
      key_prefix = "headshots/nfl/coaches/#{coach.slug}"
      content_type = coach.espn_headshot_url.to_s.end_with?(".png") ? "image/png" : "image/jpeg"

      begin
        Studio::ImageCache.cache!(
          owner: coach,
          purpose: "headshot",
          source_url: coach.espn_headshot_url,
          key_prefix: key_prefix,
          widths: COACH_HEADSHOT_WIDTHS,
          content_type: content_type
        )
        cached += 1
        puts "  [+] #{coach.person_slug.ljust(28)} (#{coach.team_slug})"
      rescue => e
        failed += 1
        puts "  [!] #{coach.person_slug}: #{e.class}: #{e.message}"
      end
    end

    puts ""
    puts "cached:                 #{cached}"
    puts "refreshed (stale cache):#{refreshed}"
    puts "skipped (already done): #{skipped_complete}"
    puts "skipped (no ESPN img):  #{without_url}"
    puts "failed:                 #{failed}"

    # Per-coach gap report — surfaces which roles on which teams ended this
    # rebuild without a cached headshot, grouped by team. Makes the next
    # iteration's targets visible at the bottom of the rebuild log.
    puts ""
    puts "─── Coaches still missing headshots (post-upload) ───"
    missing = Coach.where(sport: "football").includes(:person, :image_caches).reject do |c|
      c.image_caches.any? { |ic| ic.purpose == "headshot" }
    end
    if missing.empty?
      puts "  (none — full coverage)"
    else
      missing.group_by(&:team_slug).sort.each do |team_slug, coaches|
        puts "  #{team_slug}"
        coaches.each do |c|
          reason = c.espn_headshot_url.present? ? "url present, upload failed" : "no espn_headshot_url"
          puts "    #{c.role.ljust(28)} #{c.person.full_name.ljust(22)} [#{reason}]"
        end
      end
      puts ""
      puts "  Total missing: #{missing.size} of #{Coach.where(sport: "football").count}"
    end
  end

  desc "Seed Person + Athlete from nflverse players.csv (cross-ref IDs + ESPN headshots → S3). VERBOSE=1 SKIP_HEADSHOTS=1 MIN_SEASON=2024 STATUS=ACT (default: any status)"
  task players_seed: :environment do
    Nflverse::SeedPlayers.new(
      verbose:          ENV["VERBOSE"] == "1",
      upload_headshots: ENV["SKIP_HEADSHOTS"] != "1",
      min_season:       ENV["MIN_SEASON"] || Nflverse::SeedPlayers::DEFAULT_MIN_SEASON,
      status_filter:    ENV["STATUS"]
    ).call
  end

  desc "Sync NFL salaries from Spotrac JSON. Annotates active Contracts (matched by otc_id, falling back to name); creates Person/Athlete/Contract for entries we don't have yet."
  task salaries_sync: :environment do
    Spotrac::SyncContracts.new(verbose: ENV["VERBOSE"] == "1").call
  end

  desc "Find suffix-stripped duplicate Persons (e.g. 'will-anderson' alongside 'will-anderson-jr') and merge into the canonical record. Default DRY_RUN=1; set DRY_RUN=0 to commit."
  task merge_duplicate_athletes: :environment do
    Athletes::MergeDuplicates.new(
      dry_run: ENV.fetch("DRY_RUN", "1") != "0",
      verbose: ENV["VERBOSE"] == "1"
    ).call
  end

  desc "Compute proprietary position-bucketed pass/run rank + 0-10 grade from PFF inputs. SEASON=2025-nfl (default)."
  task assign_grades: :environment do
    season_slug = ENV["SEASON"] || "2025-nfl"
    Athletes::ComputeProprietaryGrades.new(season_slug: season_slug).call
  end

  desc "Pull NFL season schedule from nflverse for YEAR (default 2026). Creates Season + Slates (PRE/REG/playoffs) + Games. Idempotent."
  task schedule_seed: :environment do
    year = (ENV["YEAR"] || 2026).to_i
    stats = Nflverse::SeedSchedule.new(year: year).call
    puts ""
    puts "Done. Season: #{stats[:season]}"
    puts "  Slates:  #{stats[:slates]}"
    puts "  Games:   #{stats[:games]} created/found"
    puts "  Skipped: #{stats[:skipped]}"
    stats[:slate_counts].each { |type, count| puts "    #{type.ljust(15)} #{count} games" }
  end

  desc "Compute TeamRanking rows for SEASON, scoring against GRADES_FROM (defaults to SEASON). Preseason use: SEASON=2026-nfl GRADES_FROM=2025-nfl."
  task rankings_compute: :environment do
    season_slug = ENV.fetch("SEASON", "2026-nfl")
    grades_slug = ENV["GRADES_FROM"]
    Season.find_by!(slug: season_slug)
    Season.find_by!(slug: grades_slug) if grades_slug

    before = TeamRanking.where(season_slug: season_slug).count
    TeamRanking.compute_all!(season_slug: season_slug, grades_season_slug: grades_slug)
    after = TeamRanking.where(season_slug: season_slug).count
    puts "TeamRankings for #{season_slug}: #{before} → #{after}#{grades_slug ? " (scored against #{grades_slug} grades)" : ""}"

    # THE ROW COUNT IS NOT THE VERDICT HERE, and the rebuild lane logs the row
    # count. MEASURED on a desk with AthleteGrade emptied inside a rolled-back
    # transaction: compute_all! wrote 448 rows and exited 0, the identical count
    # the healthy run writes. The two differ only in the SCORES — 448 distinct
    # values spanning 49.6..5604.37 with grades, one distinct value of 0.0
    # without — so a lane grading on the count cannot see the difference, and
    # "448 rank rows populated" reads the same through a missing grade season.
    #
    # An all-zero ranking is not a ranking: every team ties at 0 and the 1..32
    # order is whatever the sort happened to do. Refuse it and name the season
    # that came back empty, since GRADES_FROM is the knob that fixes it.
    scores = TeamRanking.where(season_slug: season_slug).pluck(:score).compact
    if scores.any? && scores.all?(&:zero?)
      abort "nfl:rankings_compute scored every team 0.0 across #{scores.size} rows — " \
            "#{grades_slug || season_slug} has no AthleteGrade rows to score against. " \
            "The ranks written are ties in sort order, not a ranking. Set GRADES_FROM to " \
            "a season that has grades, or import them first."
    end
  end

  desc "Snapshot current DepthChart → per-slate Roster+RosterSpot. SEASON=2026-nfl WEEK=N (default: current week)."
  task rosters_snapshot: :environment do
    season_slug = ENV.fetch("SEASON", "2026-nfl")
    season = Season.find_by(slug: season_slug)
    abort "Season not found: #{season_slug}" unless season

    slate = if ENV["WEEK"]
      season.slates.where(slate_type: "regular_season").find_by(sequence: ENV["WEEK"].to_i)
    else
      today = Date.current
      season.slates.where(slate_type: "regular_season")
                   .where("ends_at >= ?", today)
                   .order(:sequence)
                   .first ||
        season.slates.where(slate_type: "regular_season").order(:sequence).first
    end
    abort "No regular_season slate found for #{season_slug}#{ENV["WEEK"] ? " WEEK=#{ENV["WEEK"]}" : ""}" unless slate

    puts "Snapshotting DepthChart → Roster for #{slate.slug} (Week #{slate.sequence})..."
    stats = Rosters::SnapshotFromDepthChart.new(slate_slug: slate.slug, verbose: ENV["VERBOSE"] == "1").call
    puts "Done: #{stats[:teams_snapshotted]} teams, #{stats[:teams_without_chart]} skipped, #{stats[:spots_created]} spots created, #{stats[:spots_updated]} updated"
  end
end
