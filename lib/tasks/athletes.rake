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
    puts "  derivable from them:    #{outcome.build_derivable}   (the population rule 2 grades)"
    puts "  filled:                 #{outcome.build_filled}"
    if outcome.build_implausible.positive?
      # A DATA BUG, NAMED RATHER THAN GRADED. These rows carried both measurements and
      # still could not be described, which means a value is outside
      # Athletes::BuildFromMeasurements' window — a unit mix-up or a zero-filled import.
      # Aborting on them is what rule 2 used to do and it could never be cleared by
      # fixing the lane; the row has to be fixed instead, so say which row.
      puts "  measured but IMPLAUSIBLE: #{outcome.build_implausible} — read the [?] line(s) above " \
           "and fix the measurement; the window is " \
           "#{Athletes::BuildFromMeasurements::HEIGHT_INCHES}in / " \
           "#{Athletes::BuildFromMeasurements::WEIGHT_LBS}lb"
    end
    puts ""
    if outcome.vision_armed
      puts "vision lane — paid, one call per athlete over the cached " \
           "#{vision::HEADSHOT_VARIANT}px headshot"
      puts "  wanted skin or hair:    #{outcome.vision_wanted}"
      puts "  no cached headshot:     #{outcome.skipped_no_headshot}"
      puts "  asked:                  #{outcome.vision_asked}"
      puts "  billed (call landed):   #{outcome.vision_billed}"
      puts "  asked but NOT billed:   #{outcome.vision_unbilled}"
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
    # row; it is the iteration failing. Its population is the WRITE path — a row that
    # no longer satisfies a validation (a blank `sport` raises RecordInvalid; measured
    # 2026-09-27), or a database error — and NOT the paid call, because
    # Athletes::DescribeFromHeadshot degrades to a blank Result by contract and never
    # raises into the loop's rescue.
    #
    # NOT "an ErrorLog insert that itself fails", which this comment used to list:
    # Appearances::FailureLog.file swallows its own StandardError and returns nil
    # (failure_log.rb:36-40), so it cannot raise into the rescue that called it, and
    # `failed` had already been incremented by the original exception regardless.
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

    # RULE 2 — THE FREE LANE COULD DERIVE A BUILD AND WROTE NOTHING. Graded on the DATA
    # (`BuildFromMeasurements.derivable?` — two integer measurements inside a frozen
    # constant window), never on the deriver's own verdict, because a deriver that
    # returned nil for every row would otherwise grade itself as having had nothing to
    # do. That is the `nfl:upload_headshots` shape precisely: `candidates: 2048`,
    # `cached: 0`, a clean summary, exit 0, for its whole life.
    #
    # WHAT IT STAYS QUIET ABOUT — and this list is the rule, not a footnote, because a
    # verdict that fires on a healthy run gets switched off within a week:
    #
    #   * a build already on file is never counted as wanted, so the warm re-run has
    #     build_derivable == 0 and this says nothing;
    #   * an athlete with NO height or weight is counted as wanting a build and not as
    #     derivable, so a permanent data gap is silent (build_unmeasured reports it);
    #   * an athlete whose measurement is present but IMPLAUSIBLE — centimetres in an
    #     inches column — is likewise not derivable. It is reported as
    #     build_implausible with a [?] line naming the row, and it does not abort.
    #
    # THE THIRD CASE IS WHY THIS RULE MOVED off `build_measured`, and the comment here
    # used to claim the rule could not cry wolf. It could. `measured?` asks whether both
    # COLUMNS are present; #describe returns nil outside its window, so a 180in/200lb row
    # was counted as a row the lane should have written and never could. On the warm
    # re-run it is the only row still wanting a build, so the lane reported
    # build_measured=1 build_filled=0 and aborted — every run, for ever, with nothing
    # wrong (measured in a desk 2026-09-26). Not reachable on production today: 2,051
    # athletes span 67..81in and 156..380lb with no out-of-window row, and the task is
    # operator-run rather than scheduled. It becomes reachable on the first ingest that
    # lands one bad row, which is the exact case the window exists for.
    #
    # A VERDICT MUST BE CLEARABLE BY FIXING WHAT IT ACCUSES. This one accuses the lane,
    # so its population can only contain rows the lane could actually have written. An
    # implausible row is cleared by fixing the ROW, and saying so in the report is the
    # honest way to ask for that.
    if outcome.build_derivable.positive? && outcome.build_filled.zero?
      abort "athletes:describe_from_headshots could derive a build for " \
            "#{outcome.build_derivable} athlete(s) that wanted one — both measurements on " \
            "file and inside the plausibility window — and wrote none of them. The free " \
            "lane needs no credential and no network, so this is Athletes::BuildFromMeasurements " \
            "failing on rows it accepts, or every write failing — read the [!] lines above, " \
            "then `bin/rails athletes:description_coverage`. (Rows whose measurements are " \
            "merely implausible are NOT in this count; they print as [?] above.)"
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
    #
    # ALL OR NOTHING, DELIBERATELY, and the PARTIAL failure is warned about below rather
    # than aborted on. A credential revoked at athlete 500, or a sustained 429 from
    # there, leaves asked 2,043 / billed 499: this rule is false, rule 1 is false (the
    # describer degrades, so `failed` stays 0), and the run exits 0 over ~1,544 ErrorLog
    # rows nobody was told to read. A `billed < asked` abort would catch that — and would
    # also fire on a HEALTHY pass, because one unreadable S3 object degrades to a blank
    # Result with no usage, so a single dead image on 2,043 good ones is already
    # asked 2,043 / billed 2,042. That is a guaranteed false positive on a sound run, and
    # a rule that fires on a sound run is a rule somebody disables. A threshold ("more
    # than a tenth unbilled") avoids that only by guessing a number nobody can defend
    # from the counters, and an exit code is the wrong place for a guess: it carries one
    # bit and cannot say "partly worked".
    #
    # SO THE GAP IS REPORTED AND WARNED, WHICH IS WHERE THE INFORMATION BELONGS. What
    # the operator needs is "N asks never reached the API, go read them", and that is a
    # sentence, not an exit status — a wrong guess there costs a line of noise instead of
    # a red run. The pass is resumable, so a systemic failure the warning does not stop
    # is caught by the next run one run late rather than never. This needed no new
    # column: `vision_asked` and `vision_billed` were both already counted.
    if outcome.vision_armed && outcome.vision_unbilled.positive? && outcome.vision_billed.positive?
      warn "WARNING: #{outcome.vision_unbilled} of #{outcome.vision_asked} vision call(s) were " \
           "asked for and never billed a token, so they did not reach the API — while " \
           "#{outcome.vision_billed} did. A credential revoked or rate-limited part way " \
           "through a pass looks like this, and so does a handful of unreadable S3 objects; " \
           "/admin/error_logs has a row per athlete and tells them apart. Not an abort: the " \
           "run did real work and is resumable, so re-running it after reading those rows " \
           "costs only the calls it has not already paid for."
    end

    if outcome.vision_asked.positive? && outcome.vision_billed.zero?
      abort "athletes:describe_from_headshots asked for #{outcome.vision_asked} vision " \
            "description(s) and not one call was billed a single token, so no call reached " \
            "the API. Check #{vision::API_KEY_ENV} (a key that is present but invalid " \
            "looks exactly like this), the rate limit, and the AWS keys that read the cached " \
            "headshot out of S3. /admin/error_logs has a row per athlete. The free build lane " \
            "wrote #{outcome.build_filled}, which is why nothing else above looks wrong."
    end
  end

  desc "Fill in or re-check ONE athlete against an outside source (ESPN by default). " \
       "PERSON=<person-slug|Full Name> | ESPN_ID=<id> | TEAM=<abbr> NAME=\"Full Name\" | TEAM=<abbr> (whole roster). " \
       "DRY_RUN=1 ADOPT=position,height_inches NO_HEADSHOT=1 LIMIT=N PAUSE=0.25"
  task acquire_or_validate: :environment do
    # THE OPERATOR'S DOOR ONTO Athletes::AcquireOrValidate. It prints and it
    # chooses subjects; every decision about what to write lives in the service,
    # so a second caller (a board button, a job) cannot disagree with this one.
    #
    # NEEDS NO CREDENTIAL, which was the explicit requirement — "we also need a
    # local solution". Every ESPN endpoint behind it is public. The ONLY part that
    # wants AWS keys is caching the headshot into S3, and that degrades to a
    # reported line rather than failing the run, so a desk with no bucket still
    # fills a player's data.
    #
    #   bin/rails athletes:acquire_or_validate PERSON=ashton-jeanty
    #   bin/rails athletes:acquire_or_validate ESPN_ID=3138744
    #   bin/rails athletes:acquire_or_validate TEAM=lv NAME="Chris Myarick"
    #   DRY_RUN=1 bin/rails athletes:acquire_or_validate TEAM=lv
    person = ENV["PERSON"].presence
    espn_id = ENV["ESPN_ID"].presence
    team = ENV["TEAM"].presence
    name = ENV["NAME"].presence
    dry_run = ENV["DRY_RUN"].present? && ENV["DRY_RUN"] != "0"
    adopt = ENV["ADOPT"].to_s.split(",").map(&:strip).compact_blank
    cache_headshot = ENV["NO_HEADSHOT"].blank?

    if [person, espn_id, team].all?(&:blank?)
      abort "athletes:acquire_or_validate needs a subject: PERSON=<person-slug|Full Name>, " \
            "ESPN_ID=<id>, TEAM=<abbr> NAME=\"Full Name\", or TEAM=<abbr> for a whole roster."
    end

    # ONE PROVIDER FOR THE WHOLE RUN, so a roster sweep reads each roster once —
    # Espn::PlayerProfile memoizes per instance, and a fresh one per subject would
    # re-fetch the same 79-player document on every call.
    provider = Espn::PlayerProfile.new
    act = Athletes::AcquireOrValidate.new(provider: provider, adopt: adopt, dry_run: dry_run,
                                          cache_headshot: cache_headshot)

    banner = "source: espn"
    banner += "  DRY RUN (nothing is written)" if dry_run
    banner += "  adopting: #{adopt.join(', ')}" if adopt.any?
    banner += "  headshot caching OFF" unless cache_headshot
    puts banner
    puts ""

    # THE SUBJECT LIST. A TEAM with no NAME walks that one roster — 79 players for
    # Las Vegas, so it is bounded by construction and is not a league-wide sweep.
    # It is the same single-person act 79 times, which is what makes "a trade
    # happened, re-check this team" one command.
    subjects =
      if person then [{ person: person }]
      elsif espn_id then [{ source_id: espn_id }]
      elsif name then [{ team: team, name: name }]
      else
        entries = provider.roster(team: team)
        puts "#{team} roster: #{entries.size} player(s)"
        puts ""
        entries.map { |entry| { source_id: entry.source_id } }
      end

    # LIMIT takes the sweep in inspectable waves; the act is idempotent, so the next
    # wave resumes where this one stopped and nothing has to record progress.
    limit = ENV["LIMIT"].presence&.to_i
    subjects = subjects.first(limit) if limit

    # A POLITE GUEST. One subject is one request and needs no pause; a roster sweep is
    # 79, so it waits between them by default. PAUSE=0 disables it.
    pause = ENV.fetch("PAUSE", subjects.length > 1 ? "0.25" : "0").to_f

    tally = Hash.new(0)

    subjects.each_with_index do |args, index|
      report = act.call(**args)
      tally[report.status] += 1
      tally[:stale] += 1 if report.ok? && report.stale?
      tally[report.mode] += 1 if report.ok?
      print_report(report)
      sleep pause if pause.positive? && index < subjects.length - 1
    end

    puts ""
    puts "verdict: " + tally.sort_by { |key, _| key.to_s }.map { |key, count| "#{key}=#{count}" }.join("  ")

    # A REFUSAL IS NOT A FAILURE, and this is deliberately not an abort. Every
    # refusal this act emits is a fact about the data that a human has to settle —
    # two spellings of one man, an id clash, a player ESPN no longer rosters — and
    # reddening the run would make the operator's next move "re-run it" instead of
    # "read the line". A source that could not be REACHED is different, and says so.
    if tally[:unavailable].positive?
      warn "#{tally[:unavailable]} subject(s) could not be checked because the source did not answer. " \
           "Nothing was written for them; re-run when it is back."
    end
  end
end

# ONE REPORT, PRINTED. Lives at file scope rather than inside the task body because
# a rake task body is not a method and cannot hold one.
def print_report(report)
  unless report.ok?
    puts "  [refused: #{report.status}] #{report.subject}"
    puts "      #{report.message}"
    puts ""
    return
  end

  head = "  #{report.mode.to_s.upcase} #{report.person_name} (#{report.person_slug})"
  head += "  #{report.source}:#{report.source_id}"
  head += "  STALE" if report.stale?
  puts head
  report.created.each { |row| puts "      created      #{row}" }

  report.changes.each do |change|
    label = change.outcome.to_s
    line = "      #{label.ljust(12)} #{change.field}"
    case change.outcome
    when :filled then line += ": #{change.incoming.inspect}"
    when :traded, :updated, :adopted then line += ": #{change.stored.inspect} -> #{change.incoming.inspect}"
    when :conflict then line += ": kept #{change.stored.inspect}, source says #{change.incoming.inspect}"
    when :unchanged then line += ": #{change.stored.inspect}"
    when :unreadable then line += ": #{change.note}"
    when :absent then next
    end
    puts line
  end

  headshot = report.headshot || {}
  case headshot[:status]
  when :cached then puts "      cached       headshot -> #{headshot[:keys].join(', ')}"
  when :already then puts "      unchanged    headshot (already cached)"
  when :skipped then puts "      skipped      headshot (#{headshot[:reason]})"
  when :failed then puts "      FAILED       headshot (#{headshot[:reason]}) — the source url is stored; " \
                        "`rake nfl:upload_headshots` finishes it later"
  when :absent then puts "      absent       headshot (#{headshot[:reason]})"
  end
  puts ""
end
