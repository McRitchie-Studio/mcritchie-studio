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

  private

  def build_athlete(**attrs)
    person = Person.create!(first_name: "Measured", last_name: SecureRandom.hex(4), athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "OT", **attrs)
  end
end
