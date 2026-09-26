require "test_helper"

# [unit] THE BACKFILL'S THREE PROMISES, which are the task's three acceptance
# criteria: it fills the three fields, it never overwrites one already on file, and
# it leaves a field blank rather than guessing it.
#
# Plus the two operational ones a 2,000-row production pass lives or dies by: one
# failure never aborts the run, and a re-run costs nothing.
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
    assert_equal 1, outcome.vision_calls
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
    assert_equal 0, outcome.vision_calls, "a complete row must not be paid for"
  end

  # EACH FIELD INDEPENDENTLY, which is the case a whole-row skip would get wrong: a
  # human who filled in one field must not lose the other two.
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
    assert_equal 0, second.vision_calls, "a warm re-run must not pay for what it already has"
    assert_equal 1, second.skipped_complete
    assert_equal 0, second.needed, "needed must be 0 on a warm run, or the rake verdict cries wolf"
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
    assert_equal 1, outcome.vision_calls
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
    assert_equal 0, outcome.vision_calls
    assert_equal 1, outcome.skipped_no_headshot
    assert_equal 0, outcome.failed, "a missing headshot is a data gap, not a failure"
    assert_equal 1, outcome.updated
  end

  # --- ONE FAILURE NEVER ABORTS THE RUN ------------------------------------

  test "one athlete's failure costs that athlete alone" do
    first = athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    doomed = athlete_with_headshot(height_inches: 73, weight_lbs: 205)
    last = athlete_with_headshot(height_inches: 74, weight_lbs: 240)

    exploding = lambda do |athlete|
      raise IOError, "connection reset" if athlete.id == doomed.id

      good_result
    end

    outcome = run_backfill(describer: Struct.new(:fn) { def call(a) = fn.call(a) }.new(exploding))

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
    boom = Struct.new(:x) { def call(_a) = raise(IOError, "connection reset") }.new(nil)

    assert_difference -> { ErrorLog.count }, 1 do
      run_backfill(describer: boom)
    end
  end

  # --- THE COST REPORT ----------------------------------------------------

  test "it prices the run from the usage the calls actually reported" do
    3.times { |i| athlete_with_headshot(height_inches: 72 + i, weight_lbs: 197) }

    outcome = run_backfill

    assert_equal 3, outcome.vision_calls
    assert_equal({ "input" => 1515, "output" => 114 }, outcome.usage)
    # 1515 in at $1/MTok + 114 out at $5/MTok = $0.002085, which UsagePricing ROUNDS
    # to the 4 decimals the cost column stores -> $0.0021. Pinned at the rounded
    # value on purpose: this is the same table and the same rounding the rest of the
    # ecosystem bills against, so the figure reconciles with /admin rather than
    # being a second, more precise opinion. The rounding is worth ~1% on a 3-call
    # sample and nothing on a 2,000-call run.
    assert_equal 0.0021, outcome.cost.to_f
    assert_equal 0.0007, outcome.cost_per_call.to_f
  end

  test "a run that made no call reports no cost per call rather than dividing by zero" do
    bare_athlete(height_inches: 72, weight_lbs: 197)

    outcome = run_backfill

    assert_equal 0, outcome.vision_calls
    assert_nil outcome.cost_per_call
  end

  # --- THE SAMPLE CAP -----------------------------------------------------
  #
  # The operator asked for ~20 first, to read before spending on 2,000. The cap is
  # on ATHLETES CHANGED, which bounds the spend AND the writes with one number: a
  # sample run must not quietly bulk-write the free column to the other 2,000 rows
  # nobody has approved yet either.

  test "the limit stops the run rather than continuing on the free column" do
    5.times { |i| athlete_with_headshot(height_inches: 70 + i, weight_lbs: 200) }

    outcome = run_backfill(limit: 2)

    assert_equal 2, outcome.updated
    assert_equal 2, outcome.vision_calls
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
    boom = Struct.new(:x) { def call(_a) = raise(IOError, "429 rate limited") }.new(nil)

    slept = []
    backfill = BFD.new(pause: 0.2, describer: boom)
    backfill.stub(:sleep, ->(seconds) { slept << seconds }) do
      backfill.call
    end

    assert_equal [0.2], slept
  end

  private

  def good_result
    DFH::Result.new(skin_tone: "medium-deep, warm undertone",
                    hair_description: "short black fade, full beard",
                    person_visible: true,
                    usage: { "input" => 505, "output" => 38 },
                    model: DFH::MODEL)
  end

  def stub_describer(skin_tone: "medium-deep, warm undertone",
                     hair_description: "short black fade, full beard")
    result = DFH::Result.new(skin_tone: skin_tone, hair_description: hair_description,
                             person_visible: true,
                             usage: { "input" => 505, "output" => 38 },
                             model: DFH::MODEL)
    Struct.new(:result) { def call(_athlete) = result }.new(result)
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
