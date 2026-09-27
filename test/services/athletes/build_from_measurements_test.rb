require "test_helper"

# [unit] BUILD COMES OFF THE MEASUREMENT, NOT THE PHOTOGRAPH.
#
# A headshot is head and shoulders and cannot see a body, so this is the source that
# can answer the question. Production carries height_inches AND weight_lbs for all
# 2,051 athletes (measured 2026-09-26), which is why the free path is also the
# complete one.
#
# The band expectations below are the same rows the constant's comment cites, so a
# re-tuned band has to change both and cannot drift from its own documentation.
class Athletes::BuildFromMeasurementsTest < ActiveSupport::TestCase
  BFM = Athletes::BuildFromMeasurements

  # THE MEASUREMENT LEADS, and that is the point of the format: the adjective is a
  # judgement and arguable, the numbers are facts. The worst case has to be a
  # debatable adjective attached to a correct measurement.
  test "the description states the recorded height and weight verbatim" do
    assert_equal "6 ft 0 in, 197 lb; athletic, well-built",
                 BFM.describe(height_inches: 72, weight_lbs: 197)
  end

  test "a height that is a whole number of feet reads as 0 inches, not blank" do
    assert_match(/\A6 ft 0 in, /, BFM.describe(height_inches: 72, weight_lbs: 197))
    assert_match(/\A5 ft 7 in, /, BFM.describe(height_inches: 67, weight_lbs: 158))
  end

  # EVERY BAND, at the real production rows its comment names.
  test "the bands read correctly at the rows they were chosen against" do
    # blake-grupe, K, BMI 24.4
    assert_match "lean", BFM.describe(height_inches: 67, weight_lbs: 156)
    # jaxon-smith-njigba, WR, BMI 26.7
    assert_match "athletic, well-built", BFM.describe(height_inches: 72, weight_lbs: 197)
    # a 74 in 240 lb linebacker, BMI 30.8
    assert_match "solidly built, muscular", BFM.describe(height_inches: 74, weight_lbs: 240)
    # a 75 in 310 lb defensive tackle, BMI 38.7
    assert_match "heavy, powerfully built", BFM.describe(height_inches: 75, weight_lbs: 310)
    # trent-brown, OT, BMI 41.7
    assert_match "very heavy, massive frame", BFM.describe(height_inches: 80, weight_lbs: 380)
  end

  # The lightest band is unreachable from today's football population but reachable
  # from the plausibility window, so it is tested rather than assumed dead.
  test "the lightest band is reachable" do
    assert_match "slight, wiry", BFM.describe(height_inches: 72, weight_lbs: 150)
  end

  # NO BAND MAY FALL THROUGH. `BANDS` ends at INFINITY for exactly this reason —
  # a `detect` with no catch-all returns nil, and a heavier-than-expected signing
  # would have come back with no build at all.
  test "no plausible measurement falls through the bands" do
    BFM::HEIGHT_INCHES.step(6) do |height|
      BFM::WEIGHT_LBS.step(25) do |weight|
        assert BFM.describe(height_inches: height, weight_lbs: weight).present?,
               "#{height} in / #{weight} lb fell through the bands"
      end
    end
  end

  # --- blank beats a guess ------------------------------------------------
  #
  # Nil is a real answer, and the caller writes nothing for it. An empty build
  # shows on the person page and invites a human to fill it.

  test "a missing measurement describes nothing rather than guessing" do
    assert_nil BFM.describe(height_inches: nil, weight_lbs: 197)
    assert_nil BFM.describe(height_inches: 72, weight_lbs: nil)
    assert_nil BFM.describe(height_inches: nil, weight_lbs: nil)
  end

  # THE UNIT MIX-UP IS THE CASE THIS WINDOW IS FOR. A height in centimetres landing
  # in an inches column (180) is a plausible-looking integer that produces a
  # confident, absurd description — 15 ft tall, BMI 3 — which is worse than blank
  # because nothing downstream can tell it is wrong.
  test "an implausible measurement describes nothing" do
    assert_nil BFM.describe(height_inches: 180, weight_lbs: 197), "centimetres in an inches column"
    assert_nil BFM.describe(height_inches: 0, weight_lbs: 0), "a zero-filled import"
    assert_nil BFM.describe(height_inches: 72, weight_lbs: 40), "a weight in kilograms"
    assert_nil BFM.describe(height_inches: 12, weight_lbs: 197)
  end

  test "a non-numeric measurement describes nothing rather than raising" do
    assert_nil BFM.describe(height_inches: "tall", weight_lbs: "heavy")
    assert_nil BFM.describe(height_inches: Object.new, weight_lbs: 200)
  end

  # --- through an Athlete -------------------------------------------------

  test "it reads the athlete's own columns" do
    # 6 ft 6 in / 250 lb is BMI 28.9 — a tight end, not a tackle.
    athlete = build_athlete(height_inches: 78, weight_lbs: 250)

    assert_equal "6 ft 6 in, 250 lb; athletic, well-built", BFM.call(athlete)
  end

  test "an athlete with no measurements on file gets no build" do
    assert_nil BFM.call(build_athlete(height_inches: nil, weight_lbs: nil))
  end

  test "a nil athlete is not an error" do
    assert_nil BFM.call(nil)
  end

  # --- #derivable?, the population the free lane's VERDICT grades ----------
  #
  # [unit] AN IMPLAUSIBLE MEASUREMENT IS A DATA GAP, NOT WORK DECLINED, and this is
  # the predicate that makes that distinction available to the rule. `measured?` asks
  # whether the two COLUMNS are on file; `derivable?` asks whether this source can use
  # what is on them. Grading rule 2 on the first made a permanently bad row look like a
  # lane refusing to work: on the warm re-run it is the only row still wanting a build,
  # so the lane read "had the input for 1, wrote 0" and aborted for ever.
  #
  # IT MUST NOT BE #describe IN DISGUISE. The whole value of the rule is that a broken
  # deriver cannot excuse itself, so these tests pin `derivable?` as true for rows whose
  # description this module is then obliged to produce — never as "whatever #describe
  # happened to return".

  test "a sound measurement is both measured and derivable" do
    athlete = build_athlete(height_inches: 72, weight_lbs: 197)

    assert BFM.measured?(athlete)
    assert BFM.derivable?(athlete)
  end

  # THE GAP BETWEEN THE TWO PREDICATES, which is the whole reason there are two. This
  # is the 180-inch unit mix-up that made rule 2 cry wolf on every re-run.
  test "an implausible measurement is measured but NOT derivable" do
    athlete = build_athlete(height_inches: 180, weight_lbs: 200)

    assert BFM.measured?(athlete), "both columns are on file — that is what made the old rule fire"
    refute BFM.derivable?(athlete), "and this source still cannot use them"
    assert_nil BFM.call(athlete), "so it writes nothing, which must not read as a refusal"
  end

  test "a missing measurement is neither measured nor derivable" do
    athlete = build_athlete(height_inches: nil, weight_lbs: nil)

    refute BFM.measured?(athlete)
    refute BFM.derivable?(athlete)
  end

  test "a nil athlete is not derivable and does not raise" do
    refute BFM.derivable?(nil)
    refute BFM.measured?(nil)
  end

  test "a non-numeric measurement is not derivable rather than raising" do
    refute BFM.derivable?(build_athlete(height_inches: nil, weight_lbs: 197))
  end

  # THE SUITE GUARDS THE PRECONDITION BECAUSE THE RULE NO LONGER CAN. A broken
  # #in_window? would SILENCE rule 2 rather than trip it — derivable? would read 0 and
  # the verdict would say nothing — so the boundary is pinned here instead. Both edges
  # of both ranges, and #derivable? and #describe walked together so the predicate and
  # the deriver cannot drift into disagreeing about where the window ends.
  test "derivable? and describe agree at every edge of the window" do
    heights = [BFM::HEIGHT_INCHES.min, BFM::HEIGHT_INCHES.max]
    weights = [BFM::WEIGHT_LBS.min, BFM::WEIGHT_LBS.max]

    heights.product(weights).each do |height, weight|
      athlete = build_athlete(height_inches: height, weight_lbs: weight)
      assert BFM.derivable?(athlete), "#{height} in / #{weight} lb is inside the window"
      assert BFM.call(athlete).present?,
             "#{height} in / #{weight} lb is derivable, so the deriver owes a description"
    end

    [[BFM::HEIGHT_INCHES.min - 1, 200], [BFM::HEIGHT_INCHES.max + 1, 200],
     [72, BFM::WEIGHT_LBS.min - 1], [72, BFM::WEIGHT_LBS.max + 1]].each do |height, weight|
      athlete = build_athlete(height_inches: height, weight_lbs: weight)
      refute BFM.derivable?(athlete), "#{height} in / #{weight} lb is outside the window"
      assert_nil BFM.call(athlete),
                 "#{height} in / #{weight} lb is not derivable, so the deriver owes nothing"
    end
  end

  private

  def build_athlete(**attrs)
    person = Person.create!(first_name: "Measured", last_name: SecureRandom.hex(4), athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "OT", **attrs)
  end
end
