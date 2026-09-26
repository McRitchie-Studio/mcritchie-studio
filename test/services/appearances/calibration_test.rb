require "test_helper"

# [unit] THE AGREEMENT TALLY — the machine's picks against the operator's.
#
# THE FOUR CELLS ARE THE WHOLE CONTRACT, and the one worth naming is
# `:operator_promoted` — a photograph the ranking REJECTED that the operator would have
# used. Three of the four cells only describe how well the ranker orders candidates it
# was already going to rank; that one says it threw away something it should have kept,
# which is the only cell that can teach it something it does not already believe.
class Appearances::CalibrationTest < ActiveSupport::TestCase
  Photo = AppearanceReferencePhoto

  # BUILT IN MEMORY, NOT PERSISTED. The tally reads `chosen?` and `operator_verdict` off
  # each row and never queries, so a saved record would buy nothing and cost a look.
  def photo(chosen:, verdict: nil)
    Photo.new(appearance_slug: "look-x", image_url: "https://example.com/#{SecureRandom.hex(4)}.jpg",
              source: Photo::SOURCE_SEARCH, chosen: chosen, operator_verdict: verdict)
  end

  test "[unit] each of the four cells is classified from chosen plus the verdict" do
    assert_equal :agreed_keep, photo(chosen: true, verdict: "keep").calibration_state
    assert_equal :machine_overpicked, photo(chosen: true, verdict: "drop").calibration_state
    assert_equal :operator_promoted, photo(chosen: false, verdict: "keep").calibration_state
    assert_equal :agreed_reject, photo(chosen: false, verdict: "drop").calibration_state
  end

  test "[unit] an unjudged row is its OWN state, not a disagreement" do
    # READING AN ABSENT OPINION AS EITHER ANSWER is how a page the operator has barely
    # touched reports a confident score.
    assert_equal :unjudged, photo(chosen: true).calibration_state
    assert_equal :unjudged, photo(chosen: false).calibration_state
  end

  test "[unit] the tally counts every cell and separates the unjudged" do
    tally = Appearances::Calibration.for([
      photo(chosen: true, verdict: "keep"),
      photo(chosen: true, verdict: "keep"),
      photo(chosen: true, verdict: "drop"),
      photo(chosen: false, verdict: "keep"),
      photo(chosen: false, verdict: "drop"),
      photo(chosen: false)
    ])

    assert_equal 2, tally[:agreed_keep]
    assert_equal 1, tally[:machine_overpicked]
    assert_equal 1, tally[:operator_promoted]
    assert_equal 1, tally[:agreed_reject]
    assert_equal 6, tally.total
    assert_equal 5, tally.judged
    assert_equal 1, tally.unjudged
    assert_equal 3, tally.agreed
    assert_equal 2, tally.disagreed
    assert_equal 1, tally.promotions
  end

  test "[unit] the agreement rate is over the JUDGED rows, not over all of them" do
    # THE DENOMINATOR IS THE POINT. Three of four judged rows agreeing is 75 percent
    # whether or not sixteen more tiles have never been looked at; dividing by `total`
    # would make the figure fall every time the search found another candidate.
    tally = Appearances::Calibration.for([
      photo(chosen: true, verdict: "keep"),
      photo(chosen: true, verdict: "keep"),
      photo(chosen: false, verdict: "drop"),
      photo(chosen: false, verdict: "keep"),
      photo(chosen: false),
      photo(chosen: false)
    ])

    assert_equal 4, tally.judged
    assert_equal 75, tally.agreement_rate
  end

  test "[unit] the agreement rate is nil rather than zero when nothing is judged" do
    # A FRESH LOOK HAS NO MEASURED DISAGREEMENT. Rendering one as 0 percent would be a
    # damning result nobody earned, so the page prints "not judged yet" instead.
    tally = Appearances::Calibration.for([photo(chosen: true), photo(chosen: false)])

    assert_nil tally.agreement_rate
    refute tally.started?
    assert_equal 2, tally.unjudged
  end

  test "[unit] an empty set tallies to zeroes without dividing by zero" do
    tally = Appearances::Calibration.for([])

    assert_equal 0, tally.total
    assert_equal 0, tally.judged
    assert_nil tally.agreement_rate
    assert_equal 0, tally[:agreed_keep]
  end

  test "[unit] to_h carries every key the page and the write path both read" do
    # ONE SHAPE, TWO CONSUMERS. The page seeds Alpine with this hash and #verdict returns
    # it after a write, so a key in one spelling and not the other would make a figure
    # render on load and vanish on the first click.
    tally = Appearances::Calibration.for([photo(chosen: false, verdict: "keep")])
    payload = tally.to_h

    assert_equal %i[states total judged unjudged agreed disagreed promotions agreement_rate],
                 payload.keys
    assert_equal Appearances::Calibration::STATES.sort, payload[:states].keys.sort
    assert_equal 1, payload[:states][:operator_promoted]
    assert_equal 0, payload[:agreement_rate]
  end
end
