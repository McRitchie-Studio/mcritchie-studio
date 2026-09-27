module Athletes
  # ONE PERSON, FILLED IN OR CHECKED AGAINST AN OUTSIDE SOURCE — the per-player act
  # this repo did not have.
  #
  # ── WHAT THE OPERATOR ASKED FOR ──────────────────────────────────────────────
  #
  # His words, 2026-09-27: "Pretend we need a new rookie rb that isn't in our seed
  # data. We need the SOPs to fill out (or validate (maybe a trade happened))
  # details about the player. Name, Team, Headshot, Height and other general data",
  # and then, decisively, "we also need a local solution."
  #
  # That is ONE act with TWO MODES, and the parenthesis is the whole design:
  #   ACQUIRE   a person we have never had -> create the Person and Athlete rows.
  #   VALIDATE  a person whose details may have moved -> ask the source, and report
  #             field by field what it now disagrees with.
  # A trade is the motivating validate case and is named as such in the report.
  #
  # ── WHY NOTHING EXISTING DID THIS ────────────────────────────────────────────
  #
  # Every player-data path in the repo is BULK and production-shaped:
  #   · the `nfl-rebuild` skill DROPS THE DATABASE (`db:drop db:create
  #     db:schema:load`) — all-or-nothing recovery, not a repair.
  #   · the `nfl-refresh` skill re-pulls the whole nflverse CSV and scrapes all 32
  #     depth charts. Non-destructive, but it is a league-wide sweep and it is
  #     nflverse-primary, so it cannot answer a question about one man from ESPN.
  #   · `roster-sync` is marked "Status: PENDING — do not run steps 2 and 3 yet".
  #   · `nfl:upload_headshots` selects `Athlete.where.not(espn_id: nil)`, which is
  #     precisely what a person nobody has fetched yet does not have. Verified in
  #     `lib/tasks/nfl.rake`.
  # So there was no way to fix ONE person, which is what the model pipeline needs.
  #
  # ── THE SEAM: ESPN IS PRIMARY, NOT PERMANENT ─────────────────────────────────
  #
  # ESPN is the primary source by his decision, together with "We can always add
  # supliment data sourses later". So this object holds no ESPN knowledge at all.
  # It is handed a `provider` that answers #find / #find_on_roster / #roster with
  # `Athletes::SourceProfile` values, already in our units and our vocabulary.
  # Adding a second source means writing a second provider and changing nothing
  # here. The default is Espn::PlayerProfile, which needs NO CREDENTIAL — that is
  # what makes "a local solution" true rather than aspirational.
  #
  # ── THE OVERWRITE RULE, AND THE MEASUREMENT BEHIND IT ────────────────────────
  #
  # "Never silently overwrite" is not a mood; it is a per-field decision, and the
  # fields genuinely differ in who the authority is. Four policies, in FIELDS below:
  #
  #   :key    `espn_id`. Fill when blank. A stored id that DISAGREES with the
  #           incoming one refuses the entire act, because writing over it means
  #           pasting one human's body onto another human's row.
  #   :roster `team_slug`, `jersey_number`. The league publishes these and ESPN
  #           reports them first; we hold no better source and a trade is the event
  #           the operator named. The source wins, and the change is NAMED in the
  #           report — never applied quietly.
  #   :held   `position`, `height_inches`, `weight_lbs`, `first_name`, `last_name`.
  #           Fill when blank; on a disagreement KEEP OURS and report a conflict the
  #           operator can adopt by naming the field. A human or a better source
  #           outranks ESPN here, and that is measured, not assumed:
  #
  #             T.J. Watt        stored EDGE   ESPN "LB" -> normalizes to LB
  #             Alex Highsmith   stored EDGE   ESPN "LB" -> normalizes to LB
  #             Nick Herbig      stored EDGE   ESPN "LB" -> normalizes to LB
  #
  #           (measured 2026-09-27 over ESPN's Pittsburgh and Las Vegas rosters.)
  #           Our EDGE came from PFF, whose vocabulary is finer — the same reason
  #           Nflverse::SeedPlayers#resolve_position prefers `pff_position` over the
  #           generic column. A source-wins rule on `position` would have quietly
  #           demoted every 3-4 edge rusher in the league to LB, and nothing would
  #           have errored. Height and weight sit in the same class because a
  #           hand-corrected measurement must not be re-flattened on every run.
  #   :fill   `espn_headshot_url`. Derived from the id, so a disagreement cannot
  #           happen without the :key refusal firing first.
  #
  # ── STALENESS IS CAUSAL, AND THE WORD IS SHARED ON PURPOSE ───────────────────
  #
  # Nothing here reads a clock. "Stale" means THE SOURCE NOW DISAGREES WITH WHAT WE
  # STORED, which is the only comparison that can name the change on the report
  # line ("traded: cincinnati-bengals -> denver-broncos"). `athletes.updated_at`
  # moves for any column and `people.updated_at` does not move when the athlete row
  # changes at all, so both timestamps answer this question worse than the content
  # comparison does.
  #
  # `traded` is deliberately the SAME word Appearances::LookReading uses, because it
  # is the same real-world event seen at the next seam along. The chain has two
  # joints and each object owns one:
  #
  #     ESPN ──(this act)──> athletes.team_slug ──(LookReading#traded?)──> appearance
  #
  # This act is the REPAIR for the `defined` lane on the model-pipeline board, which
  # detects an incomplete or moved person and has nowhere to send the operator. A
  # second vocabulary for one condition would make the board and its own fix
  # disagree about what is wrong.
  #
  # ── USAGE ────────────────────────────────────────────────────────────────────
  #
  #   Athletes::AcquireOrValidate.new.call(person: "ashton-jeanty")
  #   Athletes::AcquireOrValidate.new.call(source_id: "4686658")
  #   Athletes::AcquireOrValidate.new.call(team: "lv", name: "Chris Myarick")
  #   Athletes::AcquireOrValidate.new(adopt: %w[position], dry_run: true).call(person: "tj-watt")
  #
  # `bin/rails athletes:acquire_or_validate` is the operator's door onto the same
  # object; it adds printing and nothing else.
  class AcquireOrValidate
    # Every athlete this act can reach is an NFL player, because the only provider
    # today is an NFL provider. Stated once, as the value `Athlete` validates for
    # presence, rather than threaded through as an argument nobody would vary.
    SPORT = "football".freeze

    # THE WHOLE OVERWRITE RULE, AS DATA. A field's authority is a property of the
    # field, so it is declared once here and read by one loop, instead of being a
    # branch per field that a later reader has to reconstruct.
    FIELDS = [
      { field: :espn_id, table: :athlete, from: :source_id, policy: :key },
      { field: :team_slug, table: :athlete, from: :team_slug, policy: :roster },
      { field: :jersey_number, table: :athlete, from: :jersey_number, policy: :roster },
      { field: :position, table: :athlete, from: :position, policy: :held },
      { field: :height_inches, table: :athlete, from: :height_inches, policy: :held },
      { field: :weight_lbs, table: :athlete, from: :weight_lbs, policy: :held },
      { field: :first_name, table: :person, from: :first_name, policy: :held },
      { field: :last_name, table: :person, from: :last_name, policy: :held },
      { field: :espn_headshot_url, table: :athlete, from: :headshot_url, policy: :fill }
    ].freeze

    ADOPTABLE = FIELDS.select { |f| f[:policy] == :held }.map { |f| f[:field].to_s }.freeze

    # OUR TEAM SLUG -> ESPN'S ABBREVIATION, so a person we already hold can be found
    # on the right roster without the operator naming a team. Inverted from the map
    # Espn::ScrapeDepthCharts already carries rather than spelled out a second time;
    # measured 2026-09-27, that map agrees with ESPN's own team slugs on all 32.
    SLUG_TO_ABBREV = Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG.invert.freeze

    # ONE FIELD'S VERDICT. `stored` and `incoming` are both kept even when nothing
    # was written, because the report's job is to show WHY a person needed
    # refreshing and "unchanged: RB" is part of that answer.
    Change = Struct.new(:field, :table, :outcome, :stored, :incoming, :note, keyword_init: true) do
      WROTE = %i[filled traded updated adopted].freeze

      def wrote? = WROTE.include?(outcome)
      def conflict? = outcome == :conflict
      # THE SOURCE DISAGREED WITH SOMETHING WE HAD ALREADY STORED — which is what
      # `Report#stale?` answers. `adopted` belongs here: the operator choosing to
      # take the source's value settles the argument, it does not un-have it, and
      # dropping it would make a person stop reading as stale for the very run that
      # proved they were.
      def disagreement? = %i[traded updated conflict adopted].include?(outcome)
    end

    Report = Struct.new(
      :mode, :status, :subject, :person_slug, :person_name, :source, :source_id,
      :changes, :headshot, :created, :message, :dry_run, keyword_init: true
    ) do
      def ok? = status == :ok
      def changes = self[:changes] || []
      def created = self[:created] || []
      def written = changes.select(&:wrote?)
      def conflicts = changes.select(&:conflict?)
      def unreadable = changes.select { |c| c.outcome == :unreadable }

      # THE CAUSAL ANSWER TO "was this person stale?" — the source disagreed with
      # something we had already stored. A field we merely FILLED does not count:
      # nothing was out of date, we simply had never asked.
      def stale? = changes.any?(&:disagreement?)
    end

    def initialize(provider: nil, adopt: [], dry_run: false, cache_headshot: true, search_league: true)
      @provider = provider || Espn::PlayerProfile.new
      @adopt = Array(adopt).map(&:to_s)
      @dry_run = dry_run
      @cache_headshot = cache_headshot
      # Widening to all 32 rosters when the stored team misses. On by default,
      # because that miss IS the trade. Off for a caller that wants one cheap
      # request per person and can live without discovering a move.
      @search_league = search_league

      unknown = @adopt - ADOPTABLE
      raise ArgumentError, "not adoptable: #{unknown.join(', ')} (adoptable: #{ADOPTABLE.join(', ')})" if unknown.any?
    end

    # THE ACT. Exactly one of `person:`, `source_id:`, or `team:` + `name:` names
    # the subject. Never raises for a fact about the world — an unknown person, a
    # name the source does not carry, an identity clash all come back as a Report
    # with a status and a message. Athletes::SourceUnavailable is caught
    # too, because "the internet was down" is a fact about the world as well.
    def call(person: nil, source_id: nil, team: nil, name: nil)
      subject = [person, source_id, [team, name].compact_blank.join(" ")].compact_blank.first
      resolve_and_apply(person: person, source_id: source_id, team: team, name: name, subject: subject)
    rescue Athletes::SourceUnavailable => e
      refusal(:unavailable, subject, "source unavailable: #{e.message}")
    end

    private

    def resolve_and_apply(person:, source_id:, team:, name:, subject:)
      if source_id.present?
        profile = @provider.find(source_id: source_id)
        return refusal(:not_found, subject, "#{@provider.source} has no athlete #{source_id}") unless profile

        local_person, local_athlete = local_for(profile)
      elsif person.present?
        local_person = find_person(person)
        return refusal(:no_such_person, subject, "no person on file matching #{person.inspect}") unless local_person

        local_athlete = local_person.athlete_profile
        profile = profile_for_known_person(local_person, local_athlete, team)
        return profile if profile.is_a?(Report)
      elsif team.present? && name.present?
        profile = @provider.find_on_roster(team: team, name: name)
        return refusal(:not_found, subject, "#{@provider.source}'s #{team} roster does not list #{name.inspect}") unless profile

        local_person, local_athlete = local_for(profile)
      else
        raise ArgumentError, "name a subject: person:, source_id:, or team: + name:"
      end

      return local_person if local_person.is_a?(Report)
      return refusal(:unidentified, subject, "#{@provider.source} answered without an id and a name") unless profile.identified?

      guard = identity_guard(local_athlete, profile, subject)
      return guard if guard

      # AN ACQUIRE NEEDS BOTH HALVES OF A NAME. `people` validates first_name and
      # last_name for presence, so a source that sent only one would raise
      # RecordInvalid out of the middle of a transaction instead of coming back as
      # a fact about the source. Refused here, where it can be reported.
      if local_person.nil? && (profile.first_name.blank? || profile.last_name.blank?)
        return refusal(:unnamed, subject,
                       "#{@provider.source} answered with #{profile.full_name.inspect} — " \
                       "a new person needs both a first and a last name")
      end

      apply(local_person, local_athlete, profile, subject)
    end

    # THE PROFILE FOR SOMEBODY WE ALREADY HOLD. Two routes, and the second one is
    # the common case: 2,881 of 2,881 athletes in this database carry no `espn_id`
    # (measured 2026-09-27), so almost every validate starts with no source id at
    # all and has to find the person on a roster by name.
    def profile_for_known_person(local_person, local_athlete, team)
      stored_id = local_athlete&.espn_id.presence
      if stored_id
        found = @provider.find(source_id: stored_id)
        # A STORED ID THE SOURCE NO LONGER CARRIES IS A REFUSAL, NOT A RE-SEARCH.
        # Falling back to a name lookup here would find a DIFFERENT id and bind it to
        # this row — re-keying a human's identity on the strength of a spelling, which
        # is the one thing #identity_guard exists to prevent. So the act stops and
        # hands the operator the id that no longer resolves.
        #
        # THE PRINTED REMEDY IS THE ONE THAT ACTUALLY WORKS, which took a measurement
        # to get right. This message first said "re-bind it deliberately with
        # source_id:", and passing source_id is refused by #identity_guard for as long
        # as the dead id is still on the row — a remedy that walks the operator into a
        # second refusal. Clearing the id is what unblocks it, and
        # `acquire_or_validate_test.rb` follows the instruction and asserts it lands.
        unless found
          return refusal(:stale_source_id, local_person.slug,
                         "#{local_person.slug} holds #{@provider.source} id #{stored_id}, which the " \
                         "source no longer carries. Clear it first — " \
                         "Athlete.find_by(person_slug: #{local_person.slug.inspect})" \
                         ".update!(espn_id: nil) — then re-run; identity is never re-bound for you")
        end

        return found
      end

      name = local_person.full_name
      abbrev = team.presence || SLUG_TO_ABBREV[local_athlete&.team_slug]
      found = abbrev && @provider.find_on_roster(team: abbrev, name: name)
      return found if found

      # THE STORED TEAM IS THE ONE ROSTER A TRADED PLAYER IS NOT ON — which makes
      # the miss above the EXPECTED result for the operator's motivating case, not an
      # answer. Measured 2026-09-27: Bo Nix on file against cincinnati-bengals, and
      # the Cincinnati roster truthfully does not list him.
      #
      # So a miss widens to the league rather than refusing. ESPN publishes no
      # working name search, so the 32 rosters ARE the index (see
      # Espn::PlayerProfile#find_in_league). The widened search runs only after the
      # cheap route misses, and only once per person ever: the lookup stores
      # `espn_id`, and every later validate is one request.
      unless @search_league
        return refusal(:not_on_source, local_person.slug,
                       "#{@provider.source}#{abbrev ? "'s #{abbrev} roster" : ''} does not list " \
                       "#{name}, and the league-wide search is switched off")
      end

      found = @provider.find_in_league(name: name)
      unless found
        return refusal(:not_on_source, local_person.slug,
                       "#{name} is on no #{@provider.source} roster in the league " \
                       "— retired, released, or not a player")
      end

      found
    end

    # WHICH ROWS THIS PROFILE BELONGS TO, or a refusal when that cannot be decided
    # safely. The ladder is identity-first and name-last on purpose: the id is a
    # fact, a name is a spelling.
    def local_for(profile)
      by_id = Athlete.find_by(espn_id: profile.source_id)
      return [by_id.person, by_id] if by_id

      exact = Person.find_by_name(profile.first_name.to_s, profile.last_name.to_s)
      return [exact, exact.athlete_profile] if exact

      # THE REFUSAL THAT STOPS A DUPLICATE HUMAN. Measured: ESPN's "AJ Cole"
      # reaches Person.find_by_name as nil while `a-j-cole` sits on file, so
      # "no exact match" is NOT "new player". See Athletes::NameKey.
      near = NameKey.near_matches(profile.full_name)
      return [ambiguous_name_refusal(profile, near), nil] if near.any?

      [nil, nil]
    end

    # THE AMBIGUOUS-NAME REFUSAL, AND THE ONE REMEDY THAT IS NOT A LOOP.
    #
    # This message used to end "resolve by hand, or re-run with source_id: to bind the id
    # to the right row", and following it returns the BYTE-IDENTICAL refusal. Measured
    # 2026-09-27, two passes with the same `source_id:`: naming an id decides which
    # PROFILE the source answers with, and #local_for above still resolves the ROW by
    # name — by_id misses because nothing holds the id yet, find_by_name cannot see
    # across the punctuation, and the near-match ladder fires again. An instruction that
    # returns its own refusal is worse than no instruction, because the operator spends
    # the run believing they have tried something.
    #
    # It is the same defect this file already fixed once for #profile_for_known_person's
    # `:stale_source_id`, and `acquire_or_validate_test.rb` now holds BOTH to the same
    # bar: it cuts the printed line out of the message and RUNS it.
    def ambiguous_name_refusal(profile, near)
      spelling = profile.full_name
      # Sorted because NameKey.near_matches filters in Ruby over an unordered query, and
      # an operator comparing two sweeps should not have to wonder whether the order
      # means something.
      slugs = near.map(&:slug).sort

      refusal(:ambiguous_name, spelling,
              "#{spelling} is not on file under that spelling, but #{slugs.join(', ')} " \
              "could be the same person. source_id: does not settle this — it chooses " \
              "which PROFILE the source answers with, while the ROW is still resolved by " \
              "name, so re-running with one returns this very message. What settles it is " \
              "filing this spelling as an alias on the right row: Person.find_by_name " \
              "matches on aliases, so it unblocks this act AND fixes every later lookup. " \
              "If he is nobody on that list he is a new person and needs his own row by " \
              "hand. Otherwise run #{slugs.length > 1 ? 'the line for the right man' : 'this'} " \
              "and re-run the act — " \
              "#{slugs.map { |slug| alias_remedy(slug, spelling) }.join(' — or — ')}")
    end

    # ONE RUNNABLE LINE PER CANDIDATE, printed last so nothing is appended to the
    # characters the operator copies, and one per candidate rather than one template with
    # a placeholder — an instruction that has to be edited before it runs is the class of
    # defect this method exists to end.
    #
    # `people.aliases` is jsonb defaulting to `[]`, so `|` is a set union that is
    # nil-safe on a fresh row and adds nothing on a second press. Verified 2026-09-27 in
    # BOTH row shapes: a Person whose Athlete row carries no `espn_id`, and a Person with
    # no Athlete row at all.
    #
    # DELIBERATELY NOT AN ID-BINDING LINE. A near match is a PERSON —
    # NameKey.near_matches queries `people` — and a person on file need not have an
    # `athletes` row, so `Athlete.find_by(person_slug: ...).update!(espn_id: ...)` raises
    # NoMethodError on nil for exactly the punter this refusal was written for. Measured.
    # And deliberately not a `Person.create!` line for the "different man" branch: this
    # refusal exists to stop a second row for one human, so handing over the command that
    # makes one is not something to print beside "these could be the same person".
    def alias_remedy(slug, spelling)
      "Person.find_by(slug: #{slug.inspect})" \
        ".then { |p| p.update!(aliases: p.aliases | [#{spelling.inspect}]) }"
    end

    # A STORED ID THAT DISAGREES REFUSES EVERYTHING. There is no safe half-measure:
    # the row either describes the person the source just described, or the two
    # records are about different humans and every field below is a mistake.
    def identity_guard(local_athlete, profile, subject)
      stored = local_athlete&.espn_id.presence
      return nil if stored.nil? || stored == profile.source_id

      refusal(:identity_conflict, subject,
              "#{local_athlete.person_slug} already holds #{@provider.source} id #{stored}, " \
              "and the source answered with #{profile.source_id} — refusing to write one " \
              "person's data onto another's row. If #{stored} is the wrong id, clear it — " \
              "Athlete.find_by(person_slug: #{local_athlete.person_slug.inspect})" \
              ".update!(espn_id: nil) — then re-run; if both ids are real, these are two " \
              "people and one of them needs their own row")
    end

    def apply(local_person, local_athlete, profile, subject)
      # WHAT WE HELD BEFORE ANY ROW EXISTED, snapshotted ahead of the writes.
      # An acquire creates the Person with the source's own name, so deciding
      # against the live record afterwards would report `first_name: unchanged`
      # about a value this act had written seconds earlier. Every field of a row
      # that did not exist is honestly `filled`.
      stored = snapshot(local_person, local_athlete)
      changes = decide(stored, profile)
      created = []

      ActiveRecord::Base.transaction do
        local_person, local_athlete, created = ensure_rows(local_person, local_athlete, profile)
        persist(local_person, local_athlete, changes) unless @dry_run
      end

      headshot = settle_headshot(local_athlete, profile, changes)

      Report.new(
        mode: created.any? ? :acquire : :validate,
        status: :ok,
        subject: subject,
        # `name_slug` is the fallback for a DRY RUN, where the person is built and never
        # saved, so Sluggable's before_save has not stamped `slug` yet. Without it the
        # report reads "ACQUIRE Jack Bech ()" and names nobody.
        person_slug: (local_person&.slug.presence || local_person&.name_slug),
        person_name: (local_person&.full_name.presence || profile.full_name),
        source: profile.source,
        source_id: profile.source_id,
        changes: changes,
        headshot: headshot,
        created: created,
        dry_run: @dry_run
      )
    end

    # THE ACQUIRE HALF. A Person we have never had, and an Athlete row for a Person
    # who had none — both are creations, and both are named in the report so the
    # operator can see a new human entered the database.
    #
    # `Person.create!` rather than find_or_create_by_name!: the lookup has already
    # been done above, by id and then by name and then by near match, and repeating
    # it here would hide which of those decided. A slug collision raises
    # RecordNotUnique — two different names can compute one slug — and that is a
    # refusal, not something to work around by inventing a disambiguator the
    # operator never saw.
    def ensure_rows(local_person, local_athlete, profile)
      created = []

      if local_person.nil?
        attrs = { first_name: profile.first_name, last_name: profile.last_name, athlete: true }
        # A DRY RUN TOUCHES NOTHING. Built unsaved rather than created and rolled
        # back: a rollback still burns a primary-key sequence and still fires
        # callbacks, and the point of a dry run is that the operator can take one
        # without wondering what it left behind. `name_slug` is the slug the save
        # WOULD take — Sluggable stamps it in a before_save, so an unsaved row has
        # none yet.
        local_person = @dry_run ? Person.new(attrs) : Person.create!(attrs)
        created << "person:#{local_person.slug.presence || local_person.name_slug}"
      elsif !local_person.athlete?
        local_person.update!(athlete: true) unless @dry_run
      end

      if local_athlete.nil?
        person_slug = local_person.slug.presence || local_person.name_slug
        local_athlete = Athlete.new(person_slug: person_slug, sport: SPORT)
        local_athlete.save! unless @dry_run
        created << "athlete:#{person_slug}"
      end

      [local_person, local_athlete, created]
    end

    # WHAT WE HOLD RIGHT NOW, field by field. A missing row reads as nil for every
    # one of its fields, which is exactly what it means.
    def snapshot(local_person, local_athlete)
      FIELDS.to_h do |spec|
        record = spec[:table] == :person ? local_person : local_athlete
        [spec[:field], record&.public_send(spec[:field])]
      end
    end

    # THE FIELD-BY-FIELD VERDICT. One pass over FIELDS, one Change each, no writes.
    def decide(snapshot, profile)
      FIELDS.map do |spec|
        stored = snapshot[spec[:field]]
        incoming = profile.public_send(spec[:from])

        # A VALUE THE SOURCE SENT AND THE PARSER REFUSED IS NOT AN ABSENT VALUE.
        # Reported with the raw string, because the alternative — a silent nil that
        # reads as "ESPN does not carry a height" — is the failure the strict parser
        # was bought to prevent, reintroduced one layer up.
        raw = profile.unparsed[spec[:field].to_s]
        next change(spec, :unreadable, stored, nil, "source sent #{raw.inspect}; could not read it") if raw

        next change(spec, :absent, stored, nil) if blank_value?(incoming)
        next change(spec, :filled, stored, incoming) if blank_value?(stored)
        next change(spec, :unchanged, stored, incoming) if same?(stored, incoming)

        disagreement(spec, stored, incoming)
      end
    end

    def disagreement(spec, stored, incoming)
      case spec[:policy]
      when :roster
        outcome = spec[:field] == :team_slug ? :traded : :updated
        change(spec, outcome, stored, incoming)
      when :held
        return change(spec, :adopted, stored, incoming) if @adopt.include?(spec[:field].to_s)

        change(spec, :conflict, stored, incoming,
               "kept ours; adopt the source's value with adopt: [#{spec[:field].to_s.inspect}]")
      else
        # :key never reaches here — identity_guard refuses first. :fill lands here
        # only if a derived value drifted, which is worth a conflict line rather
        # than a silent overwrite.
        change(spec, :conflict, stored, incoming, "kept ours")
      end
    end

    def persist(local_person, local_athlete, changes)
      %i[person athlete].each do |table|
        record = table == :person ? local_person : local_athlete
        next unless record

        attrs = changes.select { |c| c.table == table && c.wrote? }
                       .to_h { |c| [c.field, c.incoming] }
        record.update!(attrs) if attrs.any?
      end
    end

    # THE HEADSHOT, AND WHY IT CANNOT FAIL THE ACT.
    #
    # The image is the one part of this act that needs a credential — ESPN's PNG is
    # public, but Studio::ImageCache.cache! puts the variants in S3 through
    # Studio::S3. A desk with no bucket configured must still be able to fill a
    # player's data, so every failure here is REPORTED and none of it raises. The
    # source URL is stored either way, which is what `nfl:upload_headshots` needs to
    # finish the job later.
    #
    # The key prefix comes from Athlete#headshot_key_prefix, the single writer of
    # that string, and the report reads the STORED `s3_key` back off the rows rather
    # than rebuilding a path — a re-key moves objects, so a derived path names
    # objects that are no longer there.
    def settle_headshot(athlete, profile, changes)
      return { status: :absent, reason: "#{profile.source} published no headshot url" } if profile.headshot_url.blank?
      return { status: :skipped, reason: "dry run" } if @dry_run
      return { status: :skipped, reason: "caching disabled" } unless @cache_headshot
      return { status: :skipped, reason: "no athlete row" } unless athlete

      widths = Athlete::HEADSHOT_WIDTHS
      wanted = ["original", *widths.map(&:to_s)]
      athlete.image_caches.reload
      have = athlete.image_caches.select { |c| c.purpose == "headshot" }
      if (wanted - have.map(&:variant)).empty?
        return { status: :already, keys: have.map(&:s3_key).sort }
      end

      source_url = changes.find { |c| c.field == :espn_headshot_url }&.incoming.presence || profile.headshot_url
      Studio::ImageCache.cache!(
        owner: athlete, purpose: "headshot", source_url: source_url,
        key_prefix: athlete.headshot_key_prefix, widths: widths, content_type: "image/png"
      )
      athlete.image_caches.reload
      { status: :cached,
        keys: athlete.image_caches.select { |c| c.purpose == "headshot" }.map(&:s3_key).sort }
    rescue StandardError => e
      { status: :failed, reason: "#{e.class}: #{e.message}" }
    end

    def change(spec, outcome, stored, incoming, note = nil)
      Change.new(field: spec[:field], table: spec[:table], outcome: outcome,
                 stored: stored, incoming: incoming, note: note)
    end

    def blank_value?(value) = value.nil? || (value.respond_to?(:empty?) && value.empty?)

    # Compared as strings so 2 and "2" are one jersey number and a slug is a slug.
    # The columns are typed, so this only ever normalizes the SOURCE's side.
    def same?(stored, incoming) = stored.to_s.strip == incoming.to_s.strip

    def find_person(handle)
      by_slug = Person.find_by(slug: handle.to_s.strip)
      return by_slug if by_slug

      first, last = handle.to_s.strip.split(" ", 2)
      return nil if last.blank?

      Person.find_by_name(first, last) || NameKey.near_matches(handle).first
    end

    def refusal(status, subject, message)
      Report.new(mode: :refused, status: status, subject: subject, message: message,
                 changes: [], created: [], dry_run: @dry_run)
    end
  end
end
