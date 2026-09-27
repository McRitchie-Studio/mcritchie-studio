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
  # ── ONE FIELD THE OPERATOR NAMED THAT HAS NO HOME ────────────────────────────
  #
  # He described the define step as "name, height, and for athletes number and
  # team". Four of those exist (`people.first_name`/`last_name`,
  # `athletes.height_inches`, `athletes.team_slug`). THE JERSEY NUMBER DOES NOT
  # EXIST ON ANY TABLE — measured 2026-09-26, `grep -n jersey db/schema.rb` is
  # empty, and every "jersey" in the app means the free-text `colorway`. The
  # character-sheet recipe substitutes a `<NUMBER>` into its prompt, so this is a
  # real gap in the define step and not a detail.
  #
  # This object does NOT invent a check for it. A gate over a column that does not
  # exist would fail every look for a reason the operator cannot act on. Instead the
  # gap is stated once, in the open, on the board itself
  # (Appearances::Pipeline::DEFINITION_GAP_NOTE) so it is visible rather than
  # assumed-covered.
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
      "designed" => "Filed. Nothing says yet what to generate.",
      "defined" => "The person's data is captured and current.",
      "source" => "Photographs are available to build from.",
      "model" => "A reference set has been chosen.",
      "generation" => "A character model has been delivered."
    }.freeze

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
                :athlete_team_slug, :candidate_count, :chosen_count, :judged_count,
                :artifact_count, :artifact_source, :height_inches, :weight_lbs

    # Every argument is a FACT, not a lookup. `athlete_team_slug` is the athlete
    # row's CURRENT team (nil for a non-athlete); `headshot` is whether a cached
    # headshot exists to build from; `identity_state` is
    # Appearance#higgsfield_reference_state, already a mapped symbol.
    def initialize(appearance:, person_name: nil, person_slug: nil,
                   athlete: false, athlete_team_slug: nil, headshot: false,
                   physique_described: false, height_inches: nil, weight_lbs: nil,
                   candidate_count: 0, chosen_count: 0, judged_count: 0,
                   artifact_count: 0, artifact_source: nil, identity_state: nil)
      @appearance = appearance
      @person_name = person_name
      @person_slug = person_slug || appearance.person_slug
      @hand_stage = appearance.stage.presence
      @athlete = athlete
      @athlete_team_slug = athlete_team_slug.presence
      @headshot = headshot
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

    # ── the evidence ───────────────────────────────────────────────────────────

    # CAN THIS LOOK SAY WHAT TO GENERATE? The recipe's prompt substitutes a team
    # colourway; a look naming none of the three sources for one has nothing
    # downstream can act on. `generation_notes` counts because it is the hand-written
    # answer for a person with no athlete record behind them — the same three sources
    # Appearance#generation_brief composes from.
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

    # WHERE THE EVIDENCE PUTS THIS LOOK. First match wins, and the two regressions
    # lead deliberately: a stale definition and a look that cannot say what to
    # generate both outrank whatever exists downstream, because neither can be
    # trusted until it is fixed.
    def derived_stage
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

    # WHY THIS CARD IS WHERE IT IS, in one sentence the operator can act on. This is
    # the whole point of the board: "what is this and why is it stuck" without a click.
    def blocker
      return traded_sentence if stale?

      case derived_stage
      when "designed" then "Nothing says what to generate — give it a colorway, a team, or notes."
      when "defined" then "Defined. No photograph on file to build from yet."
      when "source" then source_sentence
      when "model" then model_sentence
      when "generation" then delivered_sentence
      end
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

    # WHAT IS KNOWN ABOUT THE PERSON, as facts rather than as a gate. Height and
    # weight are on file for every athlete measured; the physique description is the
    # one a separate backfill fills, and a card that said nothing about it would let
    # an empty brief look like a complete one.
    def definition_facts
      return [] unless athlete?

      facts = []
      facts << if height_inches.present? && weight_lbs.present?
        { label: "#{height_inches}in · #{weight_lbs}lb", tone: :good }
      else
        { label: "no measurements", tone: :bad }
      end
      facts << if physique_described?
        { label: "physique described", tone: :good }
      else
        { label: "physique blank", tone: :warn }
      end
      facts
    end
  end
end
