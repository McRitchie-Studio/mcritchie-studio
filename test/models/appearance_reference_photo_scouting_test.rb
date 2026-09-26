require "test_helper"

# [unit] WHAT THE SCOUTING PAGE ADDS TO A CANDIDATE ROW: the operator's verdict, the
# found-order scope, and the two MINT EVIDENCE readers.
#
# THE MINT READERS REPORT MEASUREMENT, NEVER PREDICTION, and the tests below are written
# to hold that line. Four real mints on 2026-09-25 showed wide action shots failing at
# prepare at any resolution while a tight ESPN headshot completed, so face size in frame
# is the variable — and face size is precisely what cannot be measured without a vision
# credential that exists on no machine. Anything here that started answering "will this
# mint?" would be inventing an answer.
class AppearanceReferencePhotoScoutingTest < ActiveSupport::TestCase
  Photo = AppearanceReferencePhoto

  def build(**attrs)
    Photo.new({ appearance_slug: "look-scout", image_url: "https://example.com/#{SecureRandom.hex(4)}.jpg",
                source: Photo::SOURCE_SEARCH }.merge(attrs))
  end

  # ── THE VERDICT COLUMN ───────────────────────────────────────────────────────────

  test "[unit] only keep and drop are storable verdicts" do
    assert build(operator_verdict: "keep").valid?
    assert build(operator_verdict: "drop").valid?
    refute build(operator_verdict: "promote").valid?,
           "a third value would encode the same fact as keep-on-a-reject and let the two disagree"
  end

  test "[unit] a blank verdict is valid and means NO OPINION" do
    assert build(operator_verdict: nil).valid?
    refute build(operator_verdict: nil).judged?
  end

  # ── FOUND ORDER VERSUS GALLERY ORDER ─────────────────────────────────────────────

  test "[unit] found_order returns the provider's rank, NOT our ranking" do
    # THESE TWO SCOPES ANSWER DIFFERENT QUESTIONS and the page asks both. gallery_order is
    # OUR ranking, the thing under examination; found_order is the archive's, the evidence
    # it is examined against. Shown one way only, a bad search and a bad ranker look
    # identical.
    look = "look-order-#{SecureRandom.hex(3)}"
    third = Photo.create!(appearance_slug: look, image_url: "https://example.com/c.jpg",
                          source: Photo::SOURCE_SEARCH, position: 3, face_score: 0.9, chosen: true)
    first = Photo.create!(appearance_slug: look, image_url: "https://example.com/a.jpg",
                          source: Photo::SOURCE_SEARCH, position: 1, face_score: 0.1, chosen: false)
    second = Photo.create!(appearance_slug: look, image_url: "https://example.com/b.jpg",
                           source: Photo::SOURCE_SEARCH, position: 2, face_score: 0.5, chosen: false)

    scope = Photo.where(appearance_slug: look)

    assert_equal [first, second, third], scope.found_order.to_a
    # The same three rows, ordered by the ranking, come back differently — which is what
    # makes showing both worth the screen space.
    assert_equal [third, second, first], scope.gallery_order.to_a
  end

  test "[unit] an unranked row sorts LAST in found order, not first" do
    # Postgres sorts NULL FIRST in ascending order, so without NULLS LAST the two floor
    # rows — which carry no provider rank — would lead a column whose entire point is the
    # rank.
    look = "look-nulls-#{SecureRandom.hex(3)}"
    ranked = Photo.create!(appearance_slug: look, image_url: "https://example.com/r.jpg",
                           source: Photo::SOURCE_SEARCH, position: 7)
    unranked = Photo.create!(appearance_slug: look, image_url: "https://example.com/u.jpg",
                             source: Photo::SOURCE_HEADSHOT, position: nil)

    assert_equal [ranked, unranked], Photo.where(appearance_slug: look).found_order.to_a
  end

  # ── MINT EVIDENCE ────────────────────────────────────────────────────────────────

  test "[unit] only our mirrored headshot is marked mint-proven" do
    # THE ONE INPUT MEASURED TO COMPLETE A REFERENCE. It is our own ESPN mirror and a tight
    # face crop; every other measured input failed.
    assert build(source: Photo::SOURCE_HEADSHOT).mint_proven?
    refute build(source: Photo::SOURCE_SEARCH).mint_proven?
    refute build(source: Photo::SOURCE_OPERATOR).mint_proven?
  end

  test "[unit] a wide search crop carries the shape that failed every measured mint" do
    # 3207x2135 is ratio 1.50 and is a REAL hit — the widest candidate in the labelled
    # example, a distant sideline photograph.
    assert build(width: 3207, height: 2135).mint_shape_failed_before?
    # 556x780 is the portrait-ish winner; it is not the wide shape, which is NOT the same
    # as saying it will mint. It was in fact one of the measured failures.
    refute build(width: 556, height: 780).mint_shape_failed_before?
  end

  test "[unit] the mint-proven headshot is never ALSO flagged as a failed shape" do
    # A HEADSHOT CROPPED WIDE IS STILL THE ONE THAT MINTED. Two contradictory chips on one
    # tile would leave the operator with no reading at all.
    assert build(source: Photo::SOURCE_HEADSHOT, width: 4000, height: 2000).mint_proven?
    refute build(source: Photo::SOURCE_HEADSHOT, width: 4000, height: 2000).mint_shape_failed_before?
  end

  test "[unit] no dimensions means no shape claim, not a wide one" do
    # AN UNKNOWN SHAPE IS NOT A WIDE SHAPE. Serper may report no dimensions at all, and
    # inferring a failure from an absence would put a red chip on a photograph nobody has
    # measured anything about.
    refute build(width: nil, height: nil).mint_shape_failed_before?
    refute build(width: 800, height: nil).mint_shape_failed_before?
  end
end
