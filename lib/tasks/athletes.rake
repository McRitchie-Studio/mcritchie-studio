namespace :athletes do
  desc "Report how many athletes carry build / skin_tone / hair_description. Read-only."
  task description_coverage: :environment do
    total = Athlete.count
    filled = {
      build: Athlete.where.not(build: [nil, ""]).count,
      skin_tone: Athlete.where.not(skin_tone: [nil, ""]).count,
      hair_description: Athlete.where.not(hair_description: [nil, ""]).count
    }
    measured = Athlete.where.not(height_inches: nil).where.not(weight_lbs: nil).count
    headshots = ImageCache.where(owner_type: "Athlete", purpose: "headshot",
                                 variant: Athletes::DescribeFromHeadshot::HEADSHOT_VARIANT)
                          .distinct.count(:owner_id)

    puts "athletes:                     #{total}"
    filled.each { |field, n| puts "  with #{field.to_s.ljust(22)} #{n}" }
    puts "  with height AND weight       #{measured}   (the source for build)"
    puts "  with a cached #{Athletes::DescribeFromHeadshot::HEADSHOT_VARIANT}px headshot #{headshots}   (the source for skin tone + hair)"
  end

  desc "Fill build/skin_tone/hair_description for athletes that lack them. " \
       "Idempotent, resumable, never overwrites. DESCRIBE_LIMIT=20 DESCRIBE_PAUSE=0.2"
  task describe_from_headshots: :environment do
    # DESCRIBE_LIMIT: stop after N athletes have been CHANGED, so the cold run can
    # be taken in inspectable waves. The task is idempotent and the columns are its
    # progress, so the next wave resumes exactly where this one stopped.
    #
    # RUN A SAMPLE FIRST. The whole value of this feature is whether the
    # descriptions are any good, and that is a human judgement:
    #
    #   DESCRIBE_LIMIT=20 bin/rails athletes:describe_from_headshots
    #
    # then read the table it prints before spending on the rest.
    limit = ENV["DESCRIBE_LIMIT"].presence&.to_i

    # DESCRIBE_PAUSE: seconds after each PAID call. Free build fills are not paused.
    pause = ENV.fetch("DESCRIBE_PAUSE", Athletes::BackfillDescriptions::DEFAULT_PAUSE.to_s).to_f

    # ONE DESCRIBER, BUILT HERE AND ASKED ONCE. The warning below and the lane report
    # at the end must agree about whether the paid lane is armed, and the only way they
    # can is by reading the same object: `DescribeFromHeadshot.available?` answers for
    # the process, while `#armed?` answers for the instance the run actually used.
    # `vision` is the class, kept for its constants.
    vision = Athletes::DescribeFromHeadshot
    describer = vision.new

    unless describer.armed?
      # NOT AN ABORT. Build comes off the recorded height and weight and needs no
      # credential at all, so a run without a key still does real work — it just
      # cannot fill skin tone or hair. Saying so beats refusing to start. The paid
      # lane's verdict cannot fire either, because an unarmed describer is never asked.
      warn "#{vision::API_KEY_ENV} is not set — filling build from measurements only; " \
           "skin tone and hair need a credential."
    end

    puts "model: #{vision::MODEL}; pause: #{pause}s#{limit ? "; limit: #{limit} athlete(s) changed" : ''}"
    puts ""

    outcome = Athletes::BackfillDescriptions.new(
      limit: limit, pause: pause, describer: describer, logger: ->(line) { puts line }
    ).call

    # THE REPORT IS PER LANE, and so are the verdicts below it. Two sources answer
    # different columns at different prices and fail in different ways, so a total
    # that sums them cannot say whether the run did its job: one full pass with a dead
    # credential fills 2,051 free builds, writes zero paid descriptions, and every
    # summed counter reads healthy. Each lane is reported and graded on its own
    # evidence instead.
    #
    # READ EACH LANE LEFT TO RIGHT: wanted it -> a source could answer -> something
    # came back. A gap in the first step is a DATA gap and is not an error. A gap in
    # the last step is the lane not working, and that is what exits non-zero.
    puts ""
    puts "considered:               #{outcome.considered}"
    puts "skipped (already done):   #{outcome.skipped_complete}"
    puts "updated:                  #{outcome.updated}"
    puts "failed:                   #{outcome.failed}"
    puts ""
    puts "build lane — free, from the athlete's own height and weight"
    puts "  wanted a build:         #{outcome.build_wanted}"
    puts "  had the measurements:   #{outcome.build_measured}"
    puts "  filled:                 #{outcome.build_filled}"
    puts ""
    if outcome.vision_armed
      puts "vision lane — paid, one call per athlete over the cached " \
           "#{vision::HEADSHOT_VARIANT}px headshot"
      puts "  wanted skin or hair:    #{outcome.vision_wanted}"
      puts "  no cached headshot:     #{outcome.skipped_no_headshot}"
      puts "  asked:                  #{outcome.vision_asked}"
      puts "  billed (call landed):   #{outcome.vision_billed}"
      puts "  described:              #{outcome.described}"
    else
      # NOT ASKED AT ALL, rather than asked 2,043 times for $0.00. The describer is
      # unarmed, so the backfill never hands it an athlete — which is why there is no
      # ask count to misread here, and why the paid verdict below cannot fire.
      puts "vision lane — NOT ARMED (#{vision::API_KEY_ENV} unset): " \
           "#{outcome.vision_wanted} athlete(s) wanted skin or hair and went unasked."
    end
    puts ""
    puts "tokens:                   in #{outcome.usage['input']}, out #{outcome.usage['output']}"
    puts "cost (#{vision::MODEL} list): #{outcome.cost ? format('$%.4f', outcome.cost) : 'unpriced'}"
    if outcome.cost_per_billed_call
      puts "cost per billed call:     #{format('$%.6f', outcome.cost_per_billed_call)}"
      remaining = Athlete.where(skin_tone: [nil, ""]).or(Athlete.where(hair_description: [nil, ""])).count
      puts "projected for the remaining #{remaining}: " \
           "#{format('$%.2f', outcome.cost_per_billed_call * remaining)}"
    end

    if outcome.rows.any?
      puts ""
      puts "WHAT IT WROTE — read this before spending on the rest:"
      outcome.rows.each do |row|
        puts ""
        puts "  #{row.slug} (#{row.position})"
        puts "    build: #{row.build.presence || '(blank)'}"
        puts "    skin:  #{row.skin_tone.presence || '(blank)'}"
        puts "    hair:  #{row.hair_description.presence || '(blank)'}"
      end
    end

    # RULE 1 — THE PASS ITSELF BROKE DOWN. More raises than writes is not one dead
    # row; it is the iteration failing. Its population is the WRITE path — a
    # validation on a row that predates it, a database error, an ErrorLog insert that
    # itself fails — and NOT the paid call, because Athletes::DescribeFromHeadshot
    # degrades to a blank Result by contract and never raises into the loop's rescue.
    # That is exactly why it cannot be the only rule: rules 2 and 3 grade the two
    # sources, and this one grades the walk over them. Ending on `puts` is what let
    # `nfl:upload_headshots` report a total credential failure as an exit-0 success.
    if outcome.failed > outcome.updated
      abort "athletes:describe_from_headshots raised on #{outcome.failed} of the " \
            "#{outcome.failed + outcome.updated} athlete(s) it tried to write (wrote " \
            "#{outcome.updated}) — read the [!] lines above, which name the exception per " \
            "athlete, and /admin/error_logs, which has the rows. A raise here is the write " \
            "failing, not a description failing: the describer degrades rather than raising."
    end

    # RULE 2 — THE FREE LANE HAD ITS INPUT AND WROTE NOTHING. Graded on the DATA
    # (height and weight on file), never on the deriver's own verdict, because a
    # deriver that returned nil for every row would otherwise grade itself as having
    # had nothing to do. That is the `nfl:upload_headshots` shape precisely:
    # `candidates: 2048`, `cached: 0`, a clean summary, exit 0, for its whole life.
    #
    # IT CANNOT CRY WOLF. An athlete whose build is already filled is never counted as
    # wanting one, so the warm re-run has build_measured == 0 and this says nothing.
    # An athlete with no height or weight is counted as wanting a build and NOT as
    # having the input, so a permanent data gap is silent — which is the distinction
    # the old single rule got wrong, and the one that would have got it disabled.
    if outcome.build_measured.positive? && outcome.build_filled.zero?
      abort "athletes:describe_from_headshots had height and weight on file for " \
            "#{outcome.build_measured} athlete(s) wanting a build and wrote none of them. " \
            "The free lane needs no credential and no network, so this is either " \
            "Athletes::BuildFromMeasurements rejecting every row as implausible or every " \
            "write failing — read the [!] lines above, then " \
            "`bin/rails athletes:description_coverage`."
    end

    # RULE 3 — THE PAID LANE NEVER REACHED THE API, and this is the rule the task
    # exists to carry. The describer degrades and never raises, so a present-but-
    # INVALID credential, a sustained 429, or an unreadable S3 object files an
    # ErrorLog row and returns a blank Result: `failed` stays 0, rule 1 is false, and
    # the free build lane meanwhile drives `updated` to 2,051. Without this rule the
    # run exits 0 having described nobody and left ~2,000 ErrorLog rows nobody was
    # told to read — `nfl:upload_headshots` reproduced for the half that costs money.
    #
    # BILLED, NOT DESCRIBED, and the difference is the warm re-run. An answer that is
    # legitimately null — a helmet, a hood, a placeholder crop — leaves the row short
    # of #complete?, so every later run asks about it again and gets nothing again.
    # Grading on `described` would abort on that steady state for ever. Token usage is
    # the honest evidence that a call HAPPENED: re-asking a covered face bills, a call
    # that never left the process does not.
    #
    # WHAT IT STILL CANNOT SEE: a lane that bills every call and writes nothing — our
    # own parser broken, say — looks from here exactly like that null steady state.
    # Separating them needs a record that we ASKED and the answer was null (noted at
    # Athletes::BackfillDescriptions#wants_vision?), which is a column rather than an
    # accounting change and is not in this pass.
    if outcome.vision_asked.positive? && outcome.vision_billed.zero?
      abort "athletes:describe_from_headshots asked for #{outcome.vision_asked} vision " \
            "description(s) and not one call was billed a single token, so no call reached " \
            "the API. Check #{vision::API_KEY_ENV} (a key that is present but invalid " \
            "looks exactly like this), the rate limit, and the AWS keys that read the cached " \
            "headshot out of S3. /admin/error_logs has a row per athlete. The free build lane " \
            "wrote #{outcome.build_filled}, which is why nothing else above looks wrong."
    end
  end
end
