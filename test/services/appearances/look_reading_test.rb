require "test_helper"

# [unit] WHICH LANE ONE LOOK BELONGS IN, AND WHY.
#
# Every case here is built from FACTS handed to the constructor, with no database and
# no fixtures beyond an unsaved Appearance, because that is the shape of the object:
# Appearances::Pipeline gathers the facts in grouped queries and this decides. A test
# that needed rows to exercise a lane would be testing the gatherer instead.
#
# THE TWO PROPERTIES THAT MATTER MOST, and the reason the object exists:
#   · The board NEVER shows less progress than the evidence supports. A hand placement
#     moves a look forward and sticks; behind is refused.
#   · A change in the person's source data — a trade — sets a hand placement aside, so
#     a delivered model of a man in the wrong jersey cannot hide in Generation.
class Appearances::LookReadingTest < ActiveSupport::TestCase
  BENGALS = "cincinnati-bengals".freeze
  BRONCOS = "denver-broncos".freeze

  # An UNSAVED look: nothing here needs a row, and building one would invite the
  # default-appearance callbacks into a unit test that has no business firing them.
  def look(**attrs)
    Appearance.new({ slug: "look-test", person_slug: "josh-allen", descriptor: "Bills home" }.merge(attrs))
  end

  # THE DEFAULT IS A CONNECTED ATHLETE LOOK. Since 2026-09-27 the connection — a Person
  # row that resolves, plus an athlete record or hand-written notes — is a precondition
  # for every lane past Designed, so a reading built without one tests the connection
  # rule rather than the lane under test. The tests that are ABOUT the connection pass
  # `athlete:`/`person_present:` explicitly.
  def reading(appearance = look, **facts)
    Appearances::LookReading.new(appearance: appearance, **{ athlete: true }.merge(facts))
  end

  # ── the derived ladder ─────────────────────────────────────────────────────────

  test "a look that cannot say what to wear sits in designed" do
    r = reading(look(colorway: nil, team_slug: nil, generation_notes: nil))

    assert_equal "designed", r.derived_stage
    refute r.uniform_named?
    assert_match(/Nothing says what to wear/, r.blocker)
  end

  # ── the connection `defined` asserts ──────────────────────────────────────────
  #
  # The operator's contract (2026-09-27): "when they are defined they should have a
  # standard connection a person (and athlete record)."

  # `appearances.person_slug` is a STRING with no foreign key, so an orphan look is
  # byte-identical to a connected one until something resolves the slug. Nothing else in
  # the app would ever notice.
  test "a look whose person is not on file cannot leave designed, however much it has" do
    r = reading(look(colorway: "bills home"), person_present: false, athlete: false,
                candidate_count: 20, chosen_count: 6, artifact_count: 3)

    assert r.orphan?
    refute r.connected?
    assert_equal "designed", r.derived_stage
    assert_match(/No person on file for "josh-allen"/, r.blocker,
                 "the slug is the only handle the operator has to go and find what happened")
  end

  # AN ATHLETE RECORD IS THE STANDARD CONNECTION, and a look without one is not defined.
  test "a person with no athlete record and no notes cannot leave designed" do
    r = reading(look(colorway: "bills home"), athlete: false, person_name: "Jim Carrey",
                candidate_count: 20, chosen_count: 6)

    refute r.describable?
    assert_equal "designed", r.derived_stage
    assert_match(/No athlete record behind Jim Carrey, and no notes/, r.blocker)
  end

  # REQUIRING THE ATHLETE RECORD OF BOTH would strand every non-athlete look in Designed
  # forever, and the hub is explicitly built to cast one — Appearance's own header names
  # Jim Carrey and George Bush beside Joe Burrow. The notes are the substitute
  # #generation_brief already treats as one.
  test "hand-written notes are the connection for a person with no athlete record" do
    r = reading(look(colorway: "bills home", generation_notes: "1994 Ace Ventura, floral shirt"),
                athlete: false, candidate_count: 9, chosen_count: 4)

    assert r.describable?
    assert r.connected?
    assert_equal "model", r.derived_stage
  end

  # THE CONNECTION LEADS EVEN THE TRADE: #stale? compares the captured team against the
  # ATHLETE's, which a look with neither can answer neither way.
  test "an orphan is reported as orphaned rather than as stale" do
    r = reading(look(team_slug: "cincinnati-bengals"), person_present: false, athlete: false)

    refute r.stale?
    assert_equal "designed", r.derived_stage
  end

  # THE THREE SOURCES OF A UNIFORM, each on its own, because #generation_brief composes
  # from the same three and a look with any one of them can be told what to make.
  test "a colorway, a captured team, or hand-written notes each define a look" do
    assert reading(look(colorway: "bengals white")).uniform_named?
    assert reading(look(team_slug: BENGALS)).uniform_named?
    assert reading(look(generation_notes: "1994 Ace Ventura, floral shirt")).uniform_named?
  end

  test "a defined look with no photograph anywhere rests in defined" do
    r = reading(look(colorway: "bills home"), athlete_team_slug: "buffalo-bills")

    assert_equal "defined", r.derived_stage
    refute r.referenced?
    assert_match(/No photograph on file/, r.blocker)
  end

  # THE CACHED HEADSHOT IS A REAL REFERENCE, and this is the caveat the board was
  # warned about: measured 2026-09-26, one cached ESPN headshot produced an
  # operator-approved ten-panel sheet and five references measured no better than one.
  # So a look can reach Generation without a rich candidate set, and Source must not
  # gate on one.
  test "a cached headshot alone satisfies the source step" do
    r = reading(look(colorway: "bills home"), athlete: true, headshot: true)

    assert_equal "source", r.derived_stage
    assert r.referenced?
    refute r.selected?, "nobody has judged the headshot, so no selection has been made"
    assert_match(/cached headshot/, r.blocker)
  end

  test "candidates with nothing chosen stay in source and the card counts them" do
    r = reading(look(colorway: "bills home"), candidate_count: 20)

    assert_equal "source", r.derived_stage
    assert_equal "20 candidates found, none chosen yet.", r.blocker
  end

  # THREE WAYS A SELECTION HAPPENS, and each is a judgement by somebody: the ranker
  # choosing, the operator giving a verdict, the operator naming a URL by hand.
  test "a chosen candidate, an operator verdict, or an operator URL each reach model" do
    assert_equal "model", reading(look(colorway: "c"), candidate_count: 9, chosen_count: 4).derived_stage
    assert_equal "model", reading(look(colorway: "c"), candidate_count: 9, judged_count: 1).derived_stage
    assert_equal "model", reading(look(colorway: "c", reference_url: "https://x.test/a.png")).derived_stage
  end

  test "a filed image or a ready identity reaches generation" do
    assert_equal "generation", reading(look(colorway: "c"), artifact_count: 1).derived_stage

    ready = look(colorway: "c", higgsfield_reference_id: "ref-1",
                 higgsfield_reference_status: Appearances::CreateCharacterReference::READY_STATUS)
    assert_equal "generation", reading(ready).derived_stage
    assert_match(/No image filed against this look yet/, reading(ready).blocker)
  end

  # A TRAINING IDENTITY IS NOT A DELIVERY. It is the state worth polling, and a card
  # that read it as delivered would send the operator looking for an image nobody made.
  test "an identity still training does not reach generation" do
    training = look(colorway: "c", higgsfield_reference_id: "ref-1",
                    higgsfield_reference_status: Appearances::CreateCharacterReference::PENDING_STATUSES.first)
    r = reading(training, candidate_count: 9, chosen_count: 4)

    assert_equal "model", r.derived_stage
    assert_match(/still training/, r.blocker)
  end

  # AN UNRECOGNISED VENDOR STATUS IS NOT A SUCCESS — the same positive-form argument
  # Appearance#higgsfield_reference_ready? makes, carried onto the card.
  test "a status we do not recognise is reported rather than read as ready" do
    weird = look(colorway: "c", higgsfield_reference_id: "ref-1", higgsfield_reference_status: "exploded")
    r = reading(weird, candidate_count: 9, chosen_count: 4)

    assert_equal "model", r.derived_stage
    assert_equal :unknown, r.identity_state
    assert_match(/status we do not recognise/, r.blocker)
  end

  # ── staleness is CAUSAL, and it is a content comparison ────────────────────────

  test "a trade sends a look back to defined however far downstream it got" do
    r = reading(look(team_slug: BENGALS, colorway: "bengals white"),
                athlete: true, athlete_team_slug: BRONCOS,
                candidate_count: 20, chosen_count: 6, artifact_count: 2)

    assert r.stale?
    assert_equal "defined", r.derived_stage
    assert_equal "defined", r.board_stage
    assert_equal "Traded — captured #{BENGALS}, now #{BRONCOS}. Re-confirm before generating.", r.blocker
  end

  test "the same captured team is not stale" do
    r = reading(look(team_slug: BENGALS), athlete: true, athlete_team_slug: BENGALS, artifact_count: 1)

    refute r.stale?
    assert_equal "generation", r.derived_stage
  end

  # A LOOK THAT CAPTURED NO TEAM ASSERTS NOTHING A TRADE CAN CONTRADICT. Not a hole in
  # the check — the alternative would flag every colorway-only look the moment its
  # athlete moved, on a claim the look never made.
  test "a look that captured no team is never stale" do
    r = reading(look(team_slug: nil, colorway: "navy suit"), athlete: true, athlete_team_slug: BRONCOS)

    refute r.stale?
  end

  test "a person with no athlete record behind them is never stale" do
    r = reading(look(team_slug: BENGALS, generation_notes: "notes"), athlete: false, athlete_team_slug: nil)

    refute r.stale?
  end

  # ── the hand placement ────────────────────────────────────────────────────────

  test "a hand placement forward of the evidence sticks and says so" do
    r = reading(look(colorway: "c", stage: "generation"), athlete: true, headshot: true)

    assert_equal "source", r.derived_stage
    assert_equal "generation", r.board_stage
    assert r.hand_placed?
  end

  test "a hand placement level with the evidence is not reported as a hand placement" do
    r = reading(look(colorway: "c", stage: "source"), athlete: true, headshot: true)

    assert_equal "source", r.board_stage
    refute r.hand_placed?, "the card only flags a placement the evidence would not have made"
  end

  # THE INVARIANT: the board never shows less progress than the evidence supports. A
  # stale `stage` column from before the evidence advanced must not hold a card back.
  test "the evidence overtakes a hand placement behind it" do
    r = reading(look(colorway: "c", stage: "defined"), candidate_count: 9, chosen_count: 4, artifact_count: 1)

    assert_equal "generation", r.board_stage
  end

  test "a trade sets a hand placement aside and the card can say which one" do
    r = reading(look(team_slug: BENGALS, stage: "generation"),
                athlete: true, athlete_team_slug: BRONCOS, artifact_count: 2)

    assert_equal "defined", r.board_stage
    assert r.stale_hand_placement?
    refute r.hand_placed?, "a placement that was set aside is not the reason the card is here"
  end

  # ── placeable? — what the controller refuses ──────────────────────────────────

  test "a drag forward of the evidence is allowed and a drag behind it is not" do
    r = reading(look(colorway: "c"), candidate_count: 9, chosen_count: 4)

    assert_equal "model", r.derived_stage
    assert r.placeable?("model"), "a drag onto the lane the evidence names is allowed"
    assert r.placeable?("generation")
    refute r.placeable?("source")
    refute r.placeable?("defined")
    refute r.placeable?("designed")
  end

  test "a lane that is not one of the five is refused" do
    refute reading.placeable?("shipped")
    refute reading.placeable?("")
    refute reading.placeable?(nil)
  end

  # ── the ladder's ORDER is the rule, so the helpers that read it are pinned ─────

  test "furthest reads pipeline order and never answers nil" do
    assert_equal "model", Appearances::LookReading.furthest("model", "defined")
    assert_equal "model", Appearances::LookReading.furthest("defined", "model")
    assert_equal "source", Appearances::LookReading.furthest(nil, "source")
    assert_equal "source", Appearances::LookReading.furthest("source", nil)
    assert_equal "designed", Appearances::LookReading.furthest(nil, nil)
    assert_equal "generation", Appearances::LookReading.furthest("nonsense", "generation")
  end

  test "the five lanes are in pipeline order and every one carries a label and a blurb" do
    assert_equal %w[designed defined source model generation], Appearances::LookReading::STAGES
    Appearances::LookReading::STAGES.each do |stage|
      assert Appearances::LookReading::LABELS.key?(stage), "#{stage} has no label"
      assert Appearances::LookReading::BLURBS.key?(stage), "#{stage} has no column blurb"
    end
  end

  # ── what the card prints ──────────────────────────────────────────────────────

  test "the title names the person and the look" do
    r = reading(look(descriptor: "Bills home"), person_name: "Josh Allen")

    assert_equal "Josh Allen · Bills home", r.title
  end

  test "a look with no person name still titles itself" do
    assert_equal "Bills home", reading(look(descriptor: "Bills home")).title
  end

  # DEFINITION FACTS ARE FACTS, NOT A GATE. A blank physique description is the normal
  # state of every athlete until a separate backfill fills it, so it is reported as a
  # warning the operator can act on rather than as a failure that would demote the card.
  # A CHIP THAT IS ON EVERY CARD CARRIES NO INFORMATION. Measured on the board itself:
  # printing a chip per definition field, present or absent, put two coloured chips on
  # every card and made the one card that mattered — the traded one — impossible to pick
  # out of its column. So the definition speaks only when something is missing.
  test "a complete definition says nothing on the card" do
    r = reading(look(colorway: "bills home"),
                height_inches: 77, weight_lbs: 237, physique_described: true)

    assert_empty r.definition_facts
  end

  test "an undescribed physique is named in one warning chip" do
    r = reading(look(colorway: "bills home"), physique_described: false)

    assert_equal [{ label: "physique not described", tone: :warn }], r.definition_facts
    assert_equal "defined", r.derived_stage, "a gap in the physique does not demote the lane"
  end

  # MEASUREMENTS ARE NOT NAMED TWICE. They have a cell of their own in #sports_facts, and
  # a gap reported in two places is two chips of contrast spent on one fact.
  test "missing measurements are left to the sports row" do
    r = reading(look(colorway: "bills home"), physique_described: true)

    assert_empty r.definition_facts
    assert_equal "no size", r.sports_facts.find { |f| f[:key] == :size }[:label]
  end

  test "a non-athlete look reports no definition facts and no sports row" do
    r = reading(look(generation_notes: "notes"), athlete: false, physique_described: false)

    assert_empty r.definition_facts
    assert_empty r.sports_facts
  end

  # ── the sports-data row the operator asked for ────────────────────────────────

  test "the sports row carries team, position, number and size in that order" do
    r = reading(look(colorway: "c"), athlete_team_slug: "buffalo-bills",
                athlete_position: "QB", height_inches: 77, weight_lbs: 237)

    assert_equal %i[team position number size], r.sports_facts.map { |f| f[:key] }
    assert_equal ["Buffalo Bills", "QB", "no #", "6'5\" · 237lb"], r.sports_facts.map { |f| f[:label] }
  end

  # A ROW THAT COLLAPSED ITS EMPTY CELLS WOULD READ AS COMPLETE, so every absent value is
  # NAMED and toned as a gap rather than dropped.
  test "an absent sports value is named rather than dropped" do
    r = reading(look(colorway: "c"), athlete_team_slug: nil, athlete_position: nil)

    labels = r.sports_facts.to_h { |f| [f[:key], f[:label]] }
    assert_equal "no team", labels[:team]
    assert_equal "no position", labels[:position]
    assert_equal "no size", labels[:size]
    assert(r.sports_facts.all? { |f| f[:label].present? })
  end

  # THE JERSEY NUMBER HAS NO COLUMN ON ANY TABLE (re-checked 2026-09-27). The operator
  # named it as part of the define step and every character-sheet prompt substitutes one,
  # so the cell is permanent and carries its own explanation — a row that simply left it
  # out would read as complete.
  test "the jersey number cell is always a named gap and explains itself" do
    number = reading(look(colorway: "c"), athlete_team_slug: "buffalo-bills",
                     athlete_position: "QB", height_inches: 77, weight_lbs: 237)
                .sports_facts.find { |f| f[:key] == :number }

    assert_equal "no #", number[:label]
    assert_equal :neutral, number[:tone],
                 "muted, not a warning: no card can fill this cell until a column exists"
    assert_match(/no column on any table/, number[:title])
    refute_respond_to Athlete.new, :jersey_number,
                      "a jersey-number column landed — give the cell its value and retire this gap"
  end

  # ── who the card says this is ─────────────────────────────────────────────────

  test "the card names the person, and falls back to the slug for an orphan" do
    assert_equal "Josh Allen", reading(look, person_name: "Josh Allen").display_name
    assert_equal "josh-allen", reading(look, person_present: false).display_name
  end

  test "initials come from the name, and from the slug when there is no person" do
    assert_equal "JA", reading(look, person_name: "Josh Allen").initials
    assert_equal "JA", reading(look, person_present: false).initials
  end

  # AN ATHLETE WITH NO espn_id HAS NO CACHED HEADSHOT AT ALL — a real state (Bo Nix on a
  # development desk), not an accident. The card must have something to render.
  test "a look with no cached headshot still has an avatar fallback and no reference" do
    r = reading(look(colorway: "c"), avatar_url: nil)

    assert_nil r.avatar_url
    refute r.headshot?
    assert_equal "defined", r.derived_stage
    assert_equal "JA", r.initials
  end

  # NOTHING IN THIS OBJECT REACHES THE NETWORK OR THE DATABASE. The board renders
  # hundreds of readings on one page render, and either would be a per-card cost.
  test "a reading touches no database" do
    r = reading(look(colorway: "c", team_slug: BENGALS), athlete: true,
                athlete_team_slug: BRONCOS, candidate_count: 4, chosen_count: 1, artifact_count: 1)

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    begin
      r.derived_stage
      r.board_stage
      r.blocker
      r.definition_facts
      r.title
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_empty queries, "a reading must answer from the facts it was handed"
  end
end
