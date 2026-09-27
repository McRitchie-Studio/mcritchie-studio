module Appearances
  # WHICH LANE ONE LOOK BELONGS IN, AND WHY — the whole rule, in one place, over
  # facts it is HANDED rather than facts it goes and reads.
  #
  # The board (/model_pipeline) renders hundreds of these, so a reading that queried
  # for itself would be a page of N+1s. Every fact below arrives through the
  # constructor; `Appearances::Pipeline` gathers them in a fixed number of grouped
  # queries and hands them over. That split is also what makes the rule testable
  # without fixtures — a lane is a function of five numbers and three strings.
  #
  # ── THE RULE THE OPERATOR ASKED FOR, AND THE ONE DECISION LEFT TO US ──────────
  #
  # There are TWO writers of a look's position and they do not know about each
  # other. The SERVICES write the evidence: a search files candidates, a verdict
  # chooses one, a generation delivers an image. The OPERATOR writes a hand
  # placement by dragging a card. A drag deliberately triggers NOTHING (his
  # instruction, 2026-09-26: "No nothing triggers yet, I would rather just not
  # remove it"), so the two writers can disagree, and something has to say which
  # wins. This is that something:
  #
  #   1. The lane is DERIVED from evidence. #derived_stage is the truth the
  #      services produce, and it is recomputed on every read.
  #   2. A hand placement may move a look FORWARD of its evidence, and it STICKS
  #      there. That is a real thing an operator knows and we do not ("I am about to
  #      generate this one"), so the board keeps it.
  #   3. A hand placement may NEVER move a look behind its evidence. A look with a
  #      delivered image dragged back to Defined would make the board lie about
  #      finished work, which is the one thing a 1000-foot view must never do. The
  #      controller REFUSES that drag out loud rather than accepting it and
  #      silently correcting it on the next read — a silent correction teaches the
  #      operator the board is broken.
  #   4. A CHANGE IN THE PERSON'S SOURCE DATA SETS THE HAND PLACEMENT ASIDE. Not
  #      because a regression is allowed after all, but because the placement was a
  #      judgement about a definition that no longer holds: the man has been traded
  #      and is in the wrong jersey. #stale_hand_placement? reports that, so the
  #      card can say so rather than quietly moving.
  #
  # Read 2 and 3 together and the invariant is one sentence: THE BOARD NEVER SHOWS
  # LESS PROGRESS THAN THE EVIDENCE SUPPORTS.
  #
  # ── WHAT `defined` ASSERTS, AND WHY STALENESS IS A CONTENT COMPARISON ─────────
  #
  # The operator's own gloss on the lane: "this is where we get all the data for the
  # person … This is an important step to make sure the person is up to date like
  # after a trade." So it is a FRESHNESS CHECKPOINT, and work must be able to come
  # back to it.
  #
  # Staleness is therefore CAUSAL and is asked as a CONTENT comparison, never as a
  # clock: the look captured a team, the athlete row now names a different one. No
  # timestamp can answer this as well, and the two timestamps available answer it
  # WORSE:
  #   · `athletes.updated_at` moves for any column — an espn_id backfill, a height
  #     refresh, the build/skin-tone description sweep — so a calendar rule would
  #     flag every look on file as stale the morning after an unrelated import.
  #   · `people.updated_at` does not move AT ALL when the athlete row changes
  #     (measured 2026-09-26: no `touch: true` anywhere in app/models or
  #     app/services), so the obvious timestamp is blind to the very event the
  #     operator named.
  # The comparison has neither failure mode, and it can NAME the change on the card
  # ("traded — captured cincinnati-bengals, now denver-broncos"), which a timestamp
  # never could.
  #
  # A LOOK THAT CAPTURED NO TEAM CANNOT BE CONTRADICTED BY A TRADE, and that is not
  # a hole: a look asserting nothing about a uniform has nothing to go stale. It
  # sits in `designed` instead, because nothing downstream can be told what to make.
  #
  # ── AND `defined` ASSERTS A CONNECTION, NOT MERELY CAPTURED FIELDS ───────────
  #
  # His second instruction (2026-09-27): "when they are defined they should have a
  # standard connection a person (and athlete record)." `appearances.person_slug` is
  # a STRING with no foreign key, so a look naming a person who is not on file is
  # byte-identical to a connected one and nothing else in the app would notice. A
  # lane whose header claims "connected to a person and their record, and current"
  # cannot be entered by one, so #connected? leads the ladder — ahead even of the
  # trade, which cannot be asked of a look with no athlete behind it. See
  # #person_present? and #describable? for why NOTES are the connection a
  # non-athlete look is allowed to have instead.
  #
  # ── ONE FIELD THE OPERATOR NAMED THAT IS HELD BUT NOT BACKFILLED ─────────────
  #
  # He described the define step as "name, height, and for athletes number and
  # team". ALL FIVE NOW EXIST (`people.first_name`/`last_name`,
  # `athletes.height_inches`, `athletes.team_slug`, `athletes.jersey_number`). The
  # number arrived 2026-09-27, filled by Athletes::AcquireOrValidate under its
  # `:roster` policy because ESPN publishes it and a trade is the event the operator
  # named. Before that it existed on no table — and a tripwire in this object's test
  # asserted exactly that, so the claim could not outlive the schema. It fired the
  # day the column landed, and #sports_facts now renders the value.
  #
  # `defined` STILL DOES NOT REQUIRE IT, for a new reason. The column fills per
  # athlete on demand, never by backfill, so nil is the ORDINARY state of an athlete
  # nobody has acquired yet — a gate over it would demote nearly every look for a
  # reason that is not about that look. So the number is a FACT the card reports and
  # not a rung on the ladder: #sports_facts prints it when we hold one and a muted,
  # self-explaining `no #` when we do not, and
  # Appearances::Pipeline::DEFINITION_GAP_NOTE states the actionable version once on
  # the board.
  class LookReading
    # THE FIVE LANES, IN PIPELINE ORDER. The order IS the rule — #furthest and the
    # controller's refusal both read this array's index, so a lane inserted here
    # changes both without either being edited.
    STAGES = %w[designed defined source model generation].freeze

    LABELS = {
      "designed" => "Designed",
      "defined" => "Defined",
      "source" => "Source",
      "model" => "Model",
      "generation" => "Generation"
    }.freeze

    # WHAT SITTING IN EACH LANE MEANS, for the column header. Written as the state
    # ACHIEVED plus what is owed next, which is how /deployments reads and is the
    # board the operator asked this one to resemble.
    BLURBS = {
      "designed" => "Filed. Not connected to a person yet, or nothing says what to generate.",
      "defined" => "Connected to a person and their record, and current.",
      "source" => "Photographs are available to build from.",
      "model" => "A reference set has been chosen.",
      "generation" => "A character model has been delivered."
    }.freeze

    # WHAT THE `no #` CELL SAYS WHEN ASKED. It names the ACT that fills the column
    # rather than the column itself — a reader looking at a hole wants the remedy, and
    # "acquire or re-validate this athlete" is something they can go and do.
    NUMBER_GAP_TITLE =
      "No jersey number on file — it fills from ESPN when this athlete is acquired " \
      "or re-validated.".freeze

    def self.index(stage) = STAGES.index(stage.to_s)

    # The later of two lanes in pipeline order. An unknown or nil lane loses to a
    # known one, and two unknowns answer `designed` — the board must render every
    # card somewhere, so there is no nil return here.
    def self.furthest(one, other)
      a = index(one)
      b = index(other)
      return STAGES[[a, b].max] if a && b

      STAGES[a || b || 0]
    end

    attr_reader :appearance, :person_name, :person_slug, :hand_stage,
                :athlete_team_slug, :athlete_position, :jersey_number, :avatar_url,
                :candidate_count, :chosen_count, :judged_count,
                :artifact_count, :artifact_source, :height_inches, :weight_lbs

    # Every argument is a FACT, not a lookup. `athlete_team_slug` is the athlete
    # row's CURRENT team (nil for a non-athlete); `jersey_number` is that row's number,
    # nil until somebody acquires or re-validates the athlete; `headshot` is whether a
    # cached
    # headshot exists to build from; `avatar_url` is that headshot's S3 URL, built
    # from the STORED s3_key (never a rebuilt path — a re-key moved every athlete
    # out of `free-agents/`, so a derived path points at objects that have moved);
    # `identity_state` is Appearance#higgsfield_reference_state, already a mapped
    # symbol.
    def initialize(appearance:, person_name: nil, person_slug: nil, person_present: true,
                   athlete: false, athlete_team_slug: nil, athlete_position: nil,
                   jersey_number: nil, headshot: false, avatar_url: nil,
                   physique_described: false, height_inches: nil, weight_lbs: nil,
                   candidate_count: 0, chosen_count: 0, judged_count: 0,
                   artifact_count: 0, artifact_source: nil, identity_state: nil)
      @appearance = appearance
      @person_name = person_name
      @person_slug = person_slug || appearance.person_slug
      @person_present = person_present
      @hand_stage = appearance.stage.presence
      @athlete = athlete
      @athlete_team_slug = athlete_team_slug.presence
      @athlete_position = athlete_position.presence
      # NEITHER `.presence` NOR TRUTHINESS: 0 is a legal jersey number (the league has
      # allowed it since 2023), so the only absence this cell may report is nil.
      @jersey_number = jersey_number
      @headshot = headshot
      @avatar_url = avatar_url.presence
      @physique_described = physique_described
      @height_inches = height_inches
      @weight_lbs = weight_lbs
      @candidate_count = candidate_count.to_i
      @chosen_count = chosen_count.to_i
      @judged_count = judged_count.to_i
      @artifact_count = artifact_count.to_i
      @artifact_source = artifact_source.presence
      @identity_state = identity_state || appearance.higgsfield_reference_state
    end

    def slug = appearance.slug
    def position = appearance.position
    def descriptor = appearance.descriptor
    def colorway = appearance.colorway
    def captured_team_slug = appearance.team_slug.presence
    def athlete? = @athlete
    def headshot? = @headshot
    def physique_described? = @physique_described
    def identity_state = @identity_state

    # ── the connection ─────────────────────────────────────────────────────────
    #
    # THE OPERATOR'S CONTRACT FOR `defined` (2026-09-27): "when they are defined they
    # should have a standard connection a person (and athlete record)."
    #
    # `appearances.person_slug` is a STRING, not a foreign key — there is no FK on the
    # column and nothing stops a look naming a person who is not on file. So an orphan
    # look is byte-identical to a connected one until somebody resolves the slug, and a
    # lane that asserts "the person's data is captured and current" cannot be entered by
    # a look with no person behind it.

    # The `person_slug` resolves to a row.
    def person_present? = @person_present

    # SOMETHING SAYS WHAT THIS PERSON LOOKS LIKE. An athlete record is the standard
    # connection; `generation_notes` is the hand-written answer for a person who has
    # none, which is the case the hub is built for — Appearance's own header names Jim
    # Carrey and George Bush beside Joe Burrow, and #generation_brief already treats the
    # notes as the substitute. Requiring the athlete record of BOTH would strand every
    # non-athlete look in Designed forever.
    def describable? = athlete? || appearance.generation_notes.present?

    def connected? = person_present? && describable?
    def orphan? = !person_present?

    # ── the evidence ───────────────────────────────────────────────────────────

    # CAN THIS LOOK SAY WHAT TO WEAR? The recipe's prompt substitutes a team colourway;
    # a look naming none of the three sources for one has nothing downstream can act on.
    def uniform_named?
      colorway.present? || captured_team_slug.present? || appearance.generation_notes.present?
    end

    # THE CAPTURED DEFINITION NO LONGER MATCHES THE SOURCE. Asked only of a look that
    # captured a team, because a look that captured none asserts nothing to contradict.
    def traded?
      captured_team_slug.present? && athlete_team_slug.present? &&
        captured_team_slug != athlete_team_slug
    end

    alias stale? traded?

    # Anything at all to build an identity from: a filed candidate, or the derived
    # floor (our cached headshot / a URL the operator typed). The floor counts because
    # it is what the generator actually consumes — measured 2026-09-26, one cached
    # ESPN headshot produced an operator-approved ten-panel sheet, and five references
    # measured no better than one.
    def referenced?
      candidate_count.positive? || headshot? || appearance.reference_url.present?
    end

    # A JUDGEMENT HAS NARROWED THE SET. The ranker choosing, the operator giving a
    # verdict, or the operator naming a reference URL by hand are all selections; a
    # look whose only reference is the cached headshot nobody has looked at is NOT,
    # which is why it rests in `source` rather than jumping this lane.
    def selected?
      chosen_count.positive? || judged_count.positive? || appearance.reference_url.present?
    end

    # SOMETHING CAME OUT. Either an image filed against this look, or a character
    # identity the vendor says is ready — both are the generation step having
    # produced a usable thing.
    def delivered?
      artifact_count.positive? || identity_state == :ready
    end

    # ── the lane ───────────────────────────────────────────────────────────────

    # WHERE THE EVIDENCE PUTS THIS LOOK. First match wins, and the regressions lead
    # deliberately: a missing connection, a stale definition and a look that cannot say
    # what to wear each outrank whatever exists downstream, because none of them can be
    # trusted until it is fixed.
    #
    # THE CONNECTION LEADS EVEN THE TRADE, and it has to: #stale? asks whether the
    # captured team still matches the ATHLETE's, which a look with no person and no
    # athlete behind it cannot answer either way.
    def derived_stage
      return "designed" unless connected?
      return "defined" if stale?
      return "designed" unless uniform_named?
      return "generation" if delivered?
      return "model" if selected?
      return "source" if referenced?

      "defined"
    end

    # WHERE THE CARD RENDERS. The hand placement is honoured only forward of the
    # evidence, and a stale definition sets it aside entirely (rule 4 above).
    def board_stage
      return derived_stage if stale?

      self.class.furthest(hand_stage, derived_stage)
    end

    # The card came to rest somewhere the evidence alone would not have put it.
    def hand_placed? = hand_stage.present? && board_stage == hand_stage && hand_stage != derived_stage

    # A hand placement the operator made that this reading is ignoring, and the lane
    # it named — so the card can say so instead of appearing to have moved itself.
    def stale_hand_placement? = stale? && hand_stage.present? && hand_stage != derived_stage

    # MAY THE OPERATOR DRAG THIS CARD TO `target`? Forward of the evidence yes,
    # behind it no. The controller asks this before writing, so the refusal happens
    # at the write rather than as a correction on the next read.
    def placeable?(target)
      target_index = self.class.index(target.to_s)
      return false if target_index.nil?

      target_index >= self.class.index(derived_stage)
    end

    # ── what the card says ─────────────────────────────────────────────────────

    def title = [person_name.presence, descriptor].compact.join(" · ")

    # WHO THIS IS, for the card's identity line. The person's name where we have one;
    # the slug is the honest fallback for an orphan, because naming the slug is what
    # lets the operator go and find what is missing.
    def display_name = person_name.presence || person_slug

    # THE AVATAR'S FALLBACK. Two letters from the name we have — and from the SLUG when
    # there is no person, so an orphan card still renders a circle rather than a hole.
    def initials
      source = person_name.presence || person_slug.to_s.tr("-", " ")
      source.split.map { |word| word[0] }.compact.first(2).join.upcase.presence || "?"
    end

    # WHY THIS CARD IS WHERE IT IS, in one sentence the operator can act on. This is
    # the whole point of the board: "what is this and why is it stuck" without a click.
    def blocker
      return orphan_sentence if orphan?
      return undescribable_sentence unless describable?
      return traded_sentence if stale?

      case derived_stage
      when "designed" then "Nothing says what to wear — give it a colorway, a team, or notes."
      when "defined" then "Defined. No photograph on file to build from yet."
      when "source" then source_sentence
      when "model" then model_sentence
      when "generation" then delivered_sentence
      end
    end

    # THE SLUG IS NAMED, because it is the only handle the operator has to go and find
    # what happened — a person who was merged away, renamed, or deleted from under the
    # look. `appearances.person_slug` carries no foreign key, so nothing else caught it.
    def orphan_sentence
      "No person on file for \"#{person_slug}\" — this look is orphaned."
    end

    def undescribable_sentence
      "No athlete record behind #{display_name}, and no notes — nothing says what they look like."
    end

    def traded_sentence
      "Traded — captured #{captured_team_slug}, now #{athlete_team_slug}. Re-confirm before generating."
    end

    def source_sentence
      return "One reference — our cached headshot. Nobody has chosen from it yet." if candidate_count.zero?

      "#{candidate_count} candidate#{'s' if candidate_count != 1} found, none chosen yet."
    end

    def model_sentence
      chosen = chosen_count.positive? ? "#{chosen_count} chosen" : "operator reference set"
      return "#{chosen} — identity still training." if identity_state == :pending
      return "#{chosen} — the vendor returned a status we do not recognise." if identity_state == :unknown

      "#{chosen}. Nothing generated yet."
    end

    def delivered_sentence
      return "Identity ready. No image filed against this look yet." if artifact_count.zero?

      "#{artifact_count} image#{'s' if artifact_count != 1} delivered."
    end

    # THE SPORTS-DATA ROW the operator asked for: "a row of data dedicated to there
    # sports data, team and position." Facts, in the order he named them, and each cell
    # reports its own absence rather than collapsing — a row with a hole in it is what
    # tells him which athlete needs attention.
    #
    # THE JERSEY NUMBER IS A CELL LIKE THE OTHERS NOW. An absent one is still NAMED
    # rather than dropped: he named "number" as part of the define step, so a row that
    # quietly omitted it would read as complete.
    def sports_facts
      return [] unless athlete?

      size = measurements_label
      [
        cell(:team, athlete_team_slug&.titleize, "no team"),
        cell(:position, athlete_position, "no position"),
        number_cell,
        cell(:size, size, "no size")
      ]
    end

    # THE ONE CELL THAT DOES NOT GO THROUGH #cell, because its absence is the NORMAL
    # state rather than an anomaly. `athletes.jersey_number` is filled per athlete on
    # demand by Athletes::AcquireOrValidate and never by a backfill, so most athletes
    # carry no number today. Toning that :warn — as #cell does for team, position and
    # size — would put a warning chip on nearly every athlete card and spend the
    # contrast the traded card needs. That is the same leak the physique chip was
    # already fixed for, arriving for a new reason.
    #
    # So: a number we hold reads as a plain fact, and one we do not is muted and
    # carries the act that would fill it. 0 IS A LEGAL JERSEY, so absence is asked as
    # `nil?` — truthiness or `presence` would print "no #" for the man wearing it.
    def number_cell
      return { key: :number, label: "##{jersey_number}", tone: :neutral } unless jersey_number.nil?

      { key: :number, label: "no #", tone: :neutral, title: NUMBER_GAP_TITLE }
    end

    def measurements_label
      return nil if height_inches.blank? || weight_lbs.blank?

      "#{height_inches / 12}'#{height_inches % 12}\" · #{weight_lbs}lb"
    end

    # A cell is the value when we hold one, and the NAMED absence when we do not — never
    # blank. A row that collapsed its empty cells would read as complete.
    def cell(key, value, absent_label)
      value.present? ? { key: key, label: value, tone: :neutral } : { key: key, label: absent_label, tone: :warn }
    end

    # WHAT THE PERSON'S DEFINITION IS STILL MISSING — at most ONE chip, and only when
    # something IS missing.
    #
    # THE FIRST VERSION PRINTED A CHIP PER FIELD WHETHER IT WAS PRESENT OR NOT, and
    # rendering it killed the board: measurements and a physique description are blank
    # for most athletes today (build/skin_tone/hair_description were empty for all
    # 2,051, measured 2026-09-26), so every card carried two coloured chips and the ONE
    # card that genuinely needed attention — the traded one — was impossible to pick out
    # of the column. At 1000 feet a chip that is on every card carries no information;
    # it only spends the contrast the exceptions need.
    #
    # SO: nothing when the definition is complete, one `warn` chip when it is not. `warn`
    # rather than `bad` deliberately — a blank physique is the normal state of every
    # athlete until a separate backfill runs (build/skin_tone/hair_description were empty
    # for all 2,051, measured 2026-09-26), and styling 2,000 correct rows as failures is
    # the same mistake in a different colour.
    #
    # MEASUREMENTS ARE NOT NAMED HERE ANY MORE: they have a cell of their own in
    # #sports_facts, and a gap reported in two places at once is two chips of contrast
    # spent on one fact.
    def definition_facts
      return [] if !athlete? || physique_described?

      [{ label: "physique not described", tone: :warn }]
    end
  end
end
