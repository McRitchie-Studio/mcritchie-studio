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

    describer = Athletes::DescribeFromHeadshot
    unless describer.available?
      # NOT AN ABORT. Build comes off the recorded height and weight and needs no
      # credential at all, so a run without a key still does real work — it just
      # cannot fill skin tone or hair. Saying so beats refusing to start.
      warn "#{describer::API_KEY_ENV} is not set — filling build from measurements only; " \
           "skin tone and hair need a credential."
    end

    puts "model: #{describer::MODEL}; pause: #{pause}s#{limit ? "; limit: #{limit} athlete(s) changed" : ''}"
    puts ""

    outcome = Athletes::BackfillDescriptions.new(
      limit: limit, pause: pause, logger: ->(line) { puts line }
    ).call

    # THE NUMBERS THE VERDICTS BELOW READ, and `unattempted` is DERIVED rather than
    # accumulated — every future `next` in the loop lands in it by subtraction, so a
    # skip branch added later is counted without being told to report itself. Hand
    # counting is how `nfl:upload_headshots` dug the hole that cost 2,048 athletes
    # their avatar: a counter was faithfully incremented and printed, and no rule
    # read it.
    attempted = outcome.updated + outcome.failed
    unattempted = outcome.needed - attempted

    puts ""
    puts "considered:               #{outcome.considered}"
    puts "updated:                  #{outcome.updated}"
    puts "  build filled:           #{outcome.build_filled}"
    puts "  described from photo:   #{outcome.described}"
    puts "skipped (already done):   #{outcome.skipped_complete}"
    puts "skipped (no headshot):    #{outcome.skipped_no_headshot}"
    puts "failed:                   #{outcome.failed}"
    puts "unattempted:              #{unattempted}"
    puts ""
    puts "vision calls:             #{outcome.vision_calls}"
    puts "tokens:                   in #{outcome.usage['input']}, out #{outcome.usage['output']}"
    puts "cost (#{describer::MODEL} list): #{outcome.cost ? format('$%.4f', outcome.cost) : 'unpriced'}"
    if outcome.cost_per_call
      puts "cost per call:            #{format('$%.6f', outcome.cost_per_call)}"
      remaining = Athlete.where(skin_tone: [nil, ""]).or(Athlete.where(hair_description: [nil, ""])).count
      puts "projected for the remaining #{remaining}: #{format('$%.2f', outcome.cost_per_call * remaining)}"
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

    # GRADED ON THE MAJORITY OF ATTEMPTS. More failures than successes cannot be one
    # dead S3 object — it is the pass not working, which is what a bad credential
    # looks like from here: every attempt fails, so `updated` is 0 and `failed` is
    # everything. Ending on `puts` is what let `nfl:upload_headshots` report a total
    # credential failure as an exit-0 success.
    if outcome.failed > outcome.updated
      abort "athletes:describe_from_headshots failed #{outcome.failed} of #{attempted} attempts " \
            "(updated #{outcome.updated}) — read the [!] lines above, which name the cause per " \
            "athlete, and /admin/error_logs, which has the rows. Across MANY attempts this is " \
            "usually a credential: check #{describer::API_KEY_ENV} and the AWS keys that read " \
            "the cached headshot out of S3."
    end

    # THE SECOND RULE, AND THE ONE THE FIRST IS STRUCTURALLY BLIND TO. The rule above
    # grades ATTEMPTS, so a run that made none clears it: with `updated` 0 and
    # `failed` 0, `failed > updated` is false and the task returns normally. That is
    # exactly the shape that hid a broken `nfl:upload_headshots` for its whole life —
    # `cached: 0`, `skipped: 2048`, exit 0, a clean summary every time.
    #
    # IT CANNOT CRY WOLF ON THE WARM RE-RUN: `needed` subtracts the already-complete
    # rows, so the re-run that legitimately does nothing has `needed == 0` and this
    # says nothing. It fires only when the task found work and declined all of it.
    if outcome.needed.positive? && attempted.zero?
      abort "athletes:describe_from_headshots found #{outcome.needed} athlete(s) needing a " \
            "description and wrote none of them. That is the task declining its job, not a bad " \
            "afternoon: #{outcome.skipped_no_headshot} had no cached #{describer::HEADSHOT_VARIANT}px " \
            "headshot, and any athlete with no height/weight on file gets no build either. " \
            "Run `bin/rails athletes:description_coverage` to see which source is missing."
    end
  end
end
