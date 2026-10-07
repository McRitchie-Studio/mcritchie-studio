require "test_helper"

# [unit] WHAT THE SCOUTING PAGE ADDS TO A CANDIDATE ROW: the operator's verdict, the
# found-order scope, and the two MINT EVIDENCE readers.
#
# THE MINT READERS REPORT MEASUREMENT, NEVER PREDICTION, and the tests below are written
# to hold that line. Four real mints on 2026-09-25 showed wide action shots failing at
# prepare at any resolution while a tight ESPN headshot completed, so face size in frame
# is the variable.
#
# FACE SIZE IS NOW MEASURED WHERE A CLASSIFIER RAN — `face_fill` is
# Appearances::FaceVisibility's own answer to "how much of the frame does the head fill",
# asked as its own number because `face_score` provably could not be read back for it
# (the old prompt gave "small in frame" and "partly turned" the same 0.6). Where nothing
# ran the column is NULL, and a NULL is reported as an ABSENCE of evidence rather than as
# a small face: that distinction is what the two verdict readers rest on, and several
# cases below exist only to hold it.
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

  # appearance_slug carries a foreign key, so each test's photos hang off a real look.
  def look_on_file(hint)
    Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Scouting #{hint} #{SecureRandom.hex(3)}").slug
  end

  # ── FOUND ORDER VERSUS GALLERY ORDER ─────────────────────────────────────────────

  test "[unit] found_order returns the provider's rank, NOT our ranking" do
    # THESE TWO SCOPES ANSWER DIFFERENT QUESTIONS and the page asks both. gallery_order is
    # OUR ranking, the thing under examination; found_order is the archive's, the evidence
    # it is examined against. Shown one way only, a bad search and a bad ranker look
    # identical.
    look = look_on_file("order")
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
    look = look_on_file("nulls")
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

  # ── FACE SIZE, AND THE TWO VERDICTS IT DECIDES ───────────────────────────────────

  test "[unit] a scored row and a SIZED row are different states" do
    # THE ROW EVERY EARLIER SEARCH LEFT BEHIND: a visibility and no size. Reading the
    # first as the second is the whole defect this column was added for.
    scored_only = build(face_score: 0.92)

    assert scored_only.face_scored?
    refute scored_only.face_sized?
    assert_nil scored_only.face_fill_percent
    assert_equal 80, build(face_fill: 0.8).face_fill_percent
  end

  test "[unit] the two verdicts differ on an unmeasured face and agree on everything else" do
    # THE ASYMMETRY THE TWO GENERATORS NEED. The zero-shot sheet has no preparation stage
    # to refuse a reference; Higgsfield's trainer refused four of six measured mints.
    unmeasured = build(face_score: 0.9)

    assert unmeasured.reference_eligible?("Drew Lock")
    refute unmeasured.mint_eligible?("Drew Lock")
    assert_equal Photo::REJECTED_FACE_SIZE_UNMEASURED, unmeasured.mint_verdict("Drew Lock").to_s
  end

  test "[unit] a stranger's title is refused by both verdicts, on a row nothing classified" do
    # THE FREE HALF OF THE RULE, which is why it still holds on a legacy row: no
    # classifier ever looked at this photograph and it is still refused.
    stranger = build(title: "Drew Hutton.jpg")

    refute stranger.reference_eligible?("Drew Lock")
    refute stranger.mint_eligible?("Drew Lock")
    assert_equal Photo::REJECTED_WRONG_PERSON, stranger.reference_verdict("Drew Lock").to_s
  end

  test "[unit] the floor is exempt from both verdicts, and only the floor" do
    # OUR MIRRORED HEADSHOT IS THE ONE INPUT MEASURED TO MINT and the operator's URL is one
    # a human chose; neither came from a search, and neither has a face size because nobody
    # ever paid to classify a photograph we already trust.
    assert build(source: Photo::SOURCE_HEADSHOT).mint_eligible?("Drew Lock")
    assert build(source: Photo::SOURCE_OPERATOR).mint_eligible?("Drew Lock")
    refute build(source: Photo::SOURCE_SEARCH).mint_eligible?("Drew Lock")
  end

  test "[unit] the gallery is ordered by face SIZE before face visibility" do
    # THE ORDER MUST MATCH THE RANKER'S. GatherReferencePhotos#final_score puts a measured
    # size above a visibility score, and a gallery sorted the other way reads as a ranking
    # bug that is not there. This is the case the old order got wrong: a 92-visibility
    # photograph whose face is small in frame is precisely the one that cannot mint.
    look = look_on_file("size")
    small = Photo.create!(appearance_slug: look, image_url: "https://x.test/small.jpg",
                          source: Photo::SOURCE_SEARCH, chosen: true,
                          face_score: 0.92, face_fill: 0.2, position: 1)
    tight = Photo.create!(appearance_slug: look, image_url: "https://x.test/tight.jpg",
                          source: Photo::SOURCE_SEARCH, chosen: true,
                          face_score: 0.80, face_fill: 0.9, position: 9)

    ordered = Photo.where(appearance_slug: look).gallery_order.to_a

    assert_equal [tight, small], ordered,
                 "a smaller face with a better visibility score must not lead the gallery"
  end

  test "[unit] an unsized row sorts BELOW every measured one, never above" do
    # POSTGRES SORTS NULL FIRST IN DESCENDING ORDER, so without NULLS LAST a row nobody
    # measured would lead a gallery ordered by a measurement it does not have.
    look = look_on_file("unsized")
    unsized = Photo.create!(appearance_slug: look, image_url: "https://x.test/unsized.jpg",
                            source: Photo::SOURCE_SEARCH, chosen: true, position: 1)
    sized = Photo.create!(appearance_slug: look, image_url: "https://x.test/sized.jpg",
                          source: Photo::SOURCE_SEARCH, chosen: true, face_fill: 0.1, position: 2)

    assert_equal [sized, unsized], Photo.where(appearance_slug: look).gallery_order.to_a
  end
end
