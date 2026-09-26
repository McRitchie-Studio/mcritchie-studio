require "test_helper"

# [unit] THE BACKFILL'S THREE PROMISES, which are the task's three acceptance
# criteria: it fills the three fields, it never overwrites one already on file, and
# it leaves a field blank rather than guessing it.
#
# Plus the two operational ones a 2,000-row production pass lives or dies by: one
# failure never aborts the run, and a re-run costs nothing.
#
# AND THE LEDGER THE RAKE TASK'S VERDICTS READ, which is the rest of this file. The
# two sources cost different amounts and fail in different ways — the free build lane
# always succeeds, the paid vision lane degrades to a blank answer without raising —
# so every counter belongs to exactly one lane. A counter that summed them let a
# total vision failure read as a healthy run, because the free half had filled 2,051
# rows. The tests below pin each lane's three steps separately: wanted it, a source
# could answer, something came back.
#
# ZERO NETWORK — a stub describer here, and Athletes::VisionTransport armed to raise
# for the whole suite behind it (test/test_helper.rb).
class Athletes::BackfillDescriptionsTest < ActiveSupport::TestCase
  BFD = Athletes::BackfillDescriptions
  DFH = Athletes::DescribeFromHeadshot

  setup do
    # The table carries fixtures; this suite reasons about counts, so start from a
    # known floor and create exactly the athletes each test is about.
    ImageCache.where(owner_type: "Athlete").delete_all
    Athlete.delete_all
  end

  # --- ACCEPTANCE: fill build, skin tone and hair ---------------------------

  test "it fills all three fields for an athlete that has none" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    outcome = run_backfill

    athlete.reload
    assert_equal "6 ft 0 in, 197 lb; athletic, well-built", athlete.build
    assert_equal "medium-deep, warm undertone", athlete.skin_tone
    assert_equal "short black fade, full beard", athlete.hair_description
    assert_equal 1, outcome.updated
    assert_equal 1, outcome.build_filled
    assert_equal 1, outcome.described
    assert_equal 1, outcome.vision_asked
    assert_equal 1, outcome.vision_billed
  end

  # THE WHOLE POINT OF THE FEATURE, asserted at the surface it exists to serve
  # rather than at the columns. Athlete#physical_brief feeds
  # Appearance#generation_brief, which is the text an image generator works from —
  # and before this ran it was the operator's typed descriptor plus nothing.
  test "the filled columns reach the brief an image generator works from" do
    athlete = athlete_with_headshot(height_inches: 75, weight_lbs: 230)
    look = Appearance.create!(person_slug: athlete.person_slug, descriptor: "Seahawks home")

    assert_equal "Seahawks home", look.generation_brief,
                 "this test is only meaningful while the brief starts out bare"

    run_backfill

    brief = look.reload.generation_brief
    assert_match "Build: 6 ft 3 in, 230 lb", brief
    assert_match "Skin tone: medium-deep, warm undertone", brief
    assert_match "Hair: short black fade, full beard", brief
  end

  # --- ACCEPTANCE: never overwrite a value already on file ------------------

  test "a value already on file is never overwritten" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197,
                                    build: "hand-written build",
                                    skin_tone: "hand-written tone",
                                    hair_description: "hand-written hair")

    outcome = run_backfill

    athlete.reload
    assert_equal "hand-written build", athlete.build
    assert_equal "hand-written tone", athlete.skin_tone
    assert_equal "hand-written hair", athlete.hair_description
    assert_equal 0, outcome.updated
    assert_equal 1, outcome.skipped_complete
    assert_equal 0, outcome.vision_asked, "a complete row must not be paid for"
  end

  # EACH FIELD INDEPENDENTLY, which is the case a whole-row skip would get wrong: a
  # human who filled in one field must not lose the other two.
  #
  # THIS IS THE TEST THAT ACTUALLY BITES #fill_blanks' never-overwrite guard, and the
  # one above is not — measured by mutation, 2026-09-26: dropping both `.blank?`
  # guards reddens only this test. The fully-filled athlete above is `complete?`, so
  # the loop skips it before #fill_blanks is ever reached; it pins the SKIP, which is
  # also required (it is what makes the re-run free), but it would stay green against
  # a writer that overwrites. Both are kept, for the two different properties.
  test "a partly filled athlete keeps what is there and gains what is missing" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197,
                                    skin_tone: "hand-written tone")

    run_backfill

    athlete.reload
    assert_equal "hand-written tone", athlete.skin_tone, "the human's value outranks the model's"
    assert_equal "short black fade, full beard", athlete.hair_description
    assert_equal "6 ft 0 in, 197 lb; athletic, well-built", athlete.build
  end

  # RESUMABLE, and the columns are the only progress record. A re-run must be free.
  test "a second run over the same athletes changes nothing and spends nothing" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    run_backfill

    second = run_backfill

    assert_equal 0, second.updated
    assert_equal 0, second.vision_asked, "a warm re-run must not pay for what it already has"
    assert_equal 1, second.skipped_complete
    # THE TWO NUMBERS THE RAKE VERDICTS READ. Both lanes must report that no
    # available source had anything to do, or the re-run aborts — see the permanently
    # incompletable athlete in test/lib/tasks/athletes_describe_rake_test.rb.
    assert_equal 0, second.build_measured, "the free lane must find no input wanting work"
    assert_equal 0, second.vision_asked, "and the paid lane must ask nothing"
  end

  # --- ACCEPTANCE: leave a field blank rather than guess it -----------------

  test "an athlete with no measurements gets no build rather than a guessed one" do
    athlete = athlete_with_headshot(height_inches: nil, weight_lbs: nil)

    run_backfill

    athlete.reload
    assert_nil athlete.build, "a headshot cannot see a body — blank invites a human, a guess does not"
    assert_equal "medium-deep, warm undertone", athlete.skin_tone
  end

  test "a describer that read nothing writes nothing, and does not touch the row" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    outcome = run_backfill(describer: stub_describer(skin_tone: nil, hair_description: nil))

    athlete.reload
    assert_nil athlete.skin_tone
    assert_nil athlete.hair_description
    assert_equal "6 ft 0 in, 197 lb; athletic, well-built", athlete.build,
                 "the free half still runs when the paid half comes back empty"
    assert_equal 1, outcome.vision_asked
    assert_equal 1, outcome.vision_billed, "the call happened and was paid for"
    assert_equal 0, outcome.described
    assert_equal 1, outcome.updated, "build alone is a real update"
  end

  # --- NO HEADSHOT IS A DATA GAP, NOT A FAILURE ----------------------------
  #
  # 8 of 2,051 production athletes have no cached headshot (measured 2026-09-26).
  # They still get their build, for free, which a vision-only pass could never do.

  test "an athlete with no headshot is never called for, and still gets a build" do
    athlete = bare_athlete(height_inches: 74, weight_lbs: 240)

    outcome = run_backfill

    athlete.reload
    assert_equal "6 ft 2 in, 240 lb; solidly built, muscular", athlete.build
    assert_nil athlete.skin_tone
    assert_equal 0, outcome.vision_asked
    assert_equal 1, outcome.vision_wanted, "it wanted a description; no source could give it one"
    assert_equal 1, outcome.skipped_no_headshot
    assert_equal 0, outcome.failed, "a missing headshot is a data gap, not a failure"
    assert_equal 1, outcome.updated
  end

  # --- ONE FAILURE NEVER ABORTS THE RUN ------------------------------------

  test "one athlete's failure costs that athlete alone" do
    first = athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    doomed = athlete_with_headshot(height_inches: 73, weight_lbs: 205)
    last = athlete_with_headshot(height_inches: 74, weight_lbs: 240)

    # RAISES FROM THE DESCRIBER SEAM to reach the loop's rescue in one step. In
    # production that rescue's population is the WRITE — an orphaned row, a database
    # error — because the real describer degrades; the property under test is the
    # loop's isolation, which is the same either way.
    exploding = lambda do |athlete|
      raise IOError, "connection reset" if athlete.id == doomed.id

      good_result
    end

    outcome = run_backfill(describer: describer_double(&exploding))

    assert_equal 1, outcome.failed
    assert_equal 2, outcome.updated
    assert_equal "medium-deep, warm undertone", first.reload.skin_tone
    assert_equal "medium-deep, warm undertone", last.reload.skin_tone,
                 "the athlete AFTER the failure must still be described — a run that " \
                 "stopped there would leave 2,000 rows undone and report success"
    assert_nil doomed.reload.skin_tone
  end

  test "a failure is filed where the operator looks, not only counted" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    boom = describer_double { raise IOError, "connection reset" }

    assert_difference -> { ErrorLog.count }, 1 do
      run_backfill(describer: boom)
    end
  end

  # --- THE TWO LANES ARE COUNTED APART ------------------------------------
  #
  # This is the accounting the rake task's three verdict rules read, and the reason it
  # is worth its own section: a run with a dead credential fills every free build and
  # writes not one paid description, and a ledger that summed the lanes reported that
  # as a total success. Each lane's three steps are pinned separately below.

  # THE PAID LANE'S EVIDENCE IS THE BILL, not the write. An answer of "null, null"
  # from a call that happened is the honest description of a covered face, and it must
  # read as a working lane — this is the population that would otherwise abort the
  # steady-state re-run for ever, because the row never becomes #complete?.
  test "a call that landed and described nothing is counted as billed, not as described" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    covered = describer_double do
      good_result(skin_tone: nil, hair_description: nil, person_visible: false)
    end

    outcome = run_backfill(describer: covered)

    assert_equal 1, outcome.vision_asked
    assert_equal 1, outcome.vision_billed, "the call reached the API and was paid for"
    assert_equal 0, outcome.described
  end

  # THE SHAPE OF A TOTAL VISION FAILURE, and the describer's real contract produces
  # it: a present-but-invalid credential, a sustained 429 and an unreadable S3 object
  # all rescue inside the describer and return BLANK, which carries no usage. Nothing
  # raises, so `failed` stays 0 — and the free lane fills the build anyway, so
  # `updated` climbs. `vision_billed` is the only counter that dissents.
  test "a blank answer that never reached the API bills nothing and fails nothing" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    outcome = run_backfill(describer: describer_double { DFH::BLANK })

    assert_equal 1, outcome.vision_asked
    assert_equal 0, outcome.vision_billed, "no usage means the call never landed"
    assert_equal 0, outcome.described
    assert_equal 0, outcome.failed, "the describer degrades rather than raising — this is the trap"
    assert_equal 1, outcome.updated, "and the FREE lane still succeeded, which is what hid it"
    assert_equal "6 ft 0 in, 197 lb; athletic, well-built", athlete.reload.build
  end

  # AN UNARMED LANE IS NEVER ASKED. Handing an athlete to a describer with no
  # credential returns a blank answer without making a call, so asking 2,043 times
  # reports a spend that never happened — and sleeps out the rate-limit pause 2,043
  # times for calls that were never made.
  test "an unarmed describer is never handed an athlete, and the free lane still runs" do
    athlete = athlete_with_headshot(height_inches: 74, weight_lbs: 240)
    refused = describer_double(armed: false) { flunk "an unarmed describer must not be called" }

    outcome = run_backfill(describer: refused)

    refute outcome.vision_armed
    assert_equal 1, outcome.vision_wanted, "it still wanted a description"
    assert_equal 0, outcome.vision_asked, "and was never asked for one"
    assert_equal 0, outcome.skipped_no_headshot, "the headshot was never looked for either"
    assert_equal "6 ft 2 in, 240 lb; solidly built, muscular", athlete.reload.build
  end

  # THE FREE LANE IS GRADED ON ITS INPUT, NOT ON ITS OWN VERDICT. A deriver that
  # answered nil for every row would otherwise report that it had nothing to do —
  # which is exactly how the sibling task reported a total failure as exit 0.
  test "the free lane counts the measurements on file even when the deriver writes nothing" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    outcome = Athletes::BuildFromMeasurements.stub(:call, nil) { run_backfill }

    assert_equal 1, outcome.build_wanted
    assert_equal 1, outcome.build_measured, "the height and weight were on the record"
    assert_equal 0, outcome.build_filled, "and not one build was written"
  end

  # AND A ROW WITH NO MEASUREMENTS IS A DATA GAP, counted as wanting a build and NOT
  # as having the input — so it can never make the free lane's verdict fire.
  test "an athlete with no measurements wants a build and is not counted as measured" do
    athlete_with_headshot(height_inches: nil, weight_lbs: nil)

    outcome = run_backfill

    assert_equal 1, outcome.build_wanted
    assert_equal 0, outcome.build_measured
    assert_equal 1, outcome.build_unmeasured, "reported as a gap in the data, not as work declined"
  end

  # --- THE COST REPORT ----------------------------------------------------

  test "it prices the run from the usage the calls actually reported" do
    3.times { |i| athlete_with_headshot(height_inches: 72 + i, weight_lbs: 197) }

    outcome = run_backfill

    assert_equal 3, outcome.vision_asked
    assert_equal 3, outcome.vision_billed
    assert_equal({ "input" => 1515, "output" => 114 }, outcome.usage)
    # 1515 in at $1/MTok + 114 out at $5/MTok = $0.002085, which UsagePricing ROUNDS
    # to the 4 decimals the cost column stores -> $0.0021. Pinned at the rounded
    # value on purpose: this is the same table and the same rounding the rest of the
    # ecosystem bills against, so the figure reconciles with /admin rather than
    # being a second, more precise opinion. The rounding is worth ~1% on a 3-call
    # sample and nothing on a 2,000-call run.
    assert_equal 0.0021, outcome.cost.to_f
    assert_equal 0.0007, outcome.cost_per_billed_call.to_f
  end

  test "a run that made no call reports no cost per call rather than dividing by zero" do
    bare_athlete(height_inches: 72, weight_lbs: 197)

    outcome = run_backfill

    assert_equal 0, outcome.vision_asked
    assert_nil outcome.cost_per_billed_call
  end

  # THE PRICE IS PER CALL THAT LANDED, not per athlete handed over. A run whose calls
  # mostly never reached the API would otherwise divide a real bill by an imaginary
  # call count and under-report what the remaining 2,000 will cost.
  test "the price per call divides by the calls that were billed, not the asks" do
    billed = athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    unbilled = athlete_with_headshot(height_inches: 73, weight_lbs: 205)

    answers = lambda do |athlete|
      athlete.id == billed.id ? good_result : DFH::BLANK
    end

    outcome = run_backfill(describer: describer_double(&answers))

    assert_equal 2, outcome.vision_asked
    assert_equal 1, outcome.vision_billed
    assert_equal 0.0007, outcome.cost_per_billed_call.to_f,
                 "one call was billed, so the whole bill belongs to it"
    assert_nil unbilled.reload.skin_tone
  end

  # --- THE SAMPLE CAP -----------------------------------------------------
  #
  # The operator asked for ~20 first, to read before spending on 2,000. The cap is on
  # ATHLETES CHANGED: a sample run must not quietly bulk-write the free column to the
  # other 2,000 rows nobody has approved yet either.
  #
  # IT BOUNDS THE WRITES, NOT THE SPEND. The walk advances on CHANGES, so an athlete
  # who is paid for and yields nothing to write — build already on file, both fields
  # answered null — does not consume the limit, and DESCRIBE_LIMIT=20 can cost more
  # than twenty calls. It cannot run away, because `find_each` visits each athlete
  # once and the ceiling is therefore one full pass (~2,043 calls, ~$2.25), but the
  # flag caps rows and the table caps the bill.

  test "the limit stops the run rather than continuing on the free column" do
    5.times { |i| athlete_with_headshot(height_inches: 70 + i, weight_lbs: 200) }

    outcome = run_backfill(limit: 2)

    assert_equal 2, outcome.updated
    assert_equal 2, outcome.vision_asked
    assert_equal 3, Athlete.where(build: [nil, ""]).count,
                  "the run must STOP at the limit, not walk on filling build everywhere"
  end

  test "the limit counts athletes changed, so a skipped complete row does not consume it" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197,
                          build: "done", skin_tone: "done", hair_description: "done")
    2.times { |i| athlete_with_headshot(height_inches: 73 + i, weight_lbs: 205) }

    outcome = run_backfill(limit: 2)

    assert_equal 2, outcome.updated
    assert_equal 1, outcome.skipped_complete
  end

  # --- RATE LIMITING ------------------------------------------------------

  test "it pauses after a paid call and not after a free one" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    bare_athlete(height_inches: 74, weight_lbs: 240)

    slept = []
    backfill = BFD.new(pause: 0.2, describer: stub_describer)
    backfill.stub(:sleep, ->(seconds) { slept << seconds }) do
      backfill.call
    end

    assert_equal [0.2], slept,
                 "one paid call, one free build fill — only the paid one waits"
  end

  test "a failed call still waits, so a rate-limited run does not retry faster than a healthy one" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    boom = describer_double { raise IOError, "429 rate limited" }

    slept = []
    backfill = BFD.new(pause: 0.2, describer: boom)
    backfill.stub(:sleep, ->(seconds) { slept << seconds }) do
      backfill.call
    end

    assert_equal [0.2], slept
  end

  private

  # A DESCRIBER WITH THE PRODUCTION CONTRACT, and both halves of it matter. It answers
  # #armed? — which the backfill asks before handing over a single athlete — and by
  # DEFAULT it degrades rather than raising, because Athletes::DescribeFromHeadshot
  # rescues StandardError and returns a blank Result by construction. A double that
  # raises is exercising the WRITE path's rescue, not the describer's, and the two
  # tests below that use one say so.
  def describer_double(armed: true, &answer)
    Struct.new(:answer, :armed) do
      def call(athlete) = answer.call(athlete)
      def armed? = armed
    end.new(answer, armed)
  end

  def good_result(**overrides)
    DFH::Result.new(**{ skin_tone: "medium-deep, warm undertone",
                        hair_description: "short black fade, full beard",
                        person_visible: true,
                        usage: { "input" => 505, "output" => 38 },
                        model: DFH::MODEL }.merge(overrides))
  end

  def stub_describer(**overrides)
    result = good_result(**overrides)
    describer_double { result }
  end

  def run_backfill(describer: nil, limit: nil)
    BFD.new(limit: limit, pause: 0, describer: describer || stub_describer).call
  end

  def bare_athlete(**attrs)
    person = Person.create!(first_name: "Backfill", last_name: SecureRandom.hex(4), athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "WR", **attrs)
  end

  def athlete_with_headshot(**attrs)
    athlete = bare_athlete(**attrs)
    ImageCache.create!(owner: athlete, purpose: "headshot",
                       variant: DFH::HEADSHOT_VARIANT,
                       s3_key: "headshots/nfl/free-agents/#{athlete.person_slug}/400.png",
                       content_type: "image/png")
    athlete.reload
  end
end
