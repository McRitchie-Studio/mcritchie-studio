require "test_helper"

# [unit] THE ONE RULE BOTH GENERATORS ASK, and the one extra demand only the trainer
# makes.
#
# WHY TWO ANSWERS. Appearances::GenerateArtifact reads references AT GENERATION TIME
# through a zero-shot model: there is no preparation stage, so no stage can refuse, and a
# weak reference costs a weaker sheet rather than a failed purchase. Higgsfield's trainer
# PREPARES the set first and refused four of six measured mints (2026-09-25), and face
# size in frame is the variable those failures turned on — so it demands a MEASURED face
# size and the sheet does not.
#
# THE ASYMMETRY IS THE POINT OF EVERY CASE BELOW. Collapsing the two answers starves the
# sheet the operator asked for, or gambles a training purchase on photographs nobody
# measured.
class Appearances::ReferenceEligibilityTest < ActiveSupport::TestCase
  RE = Appearances::ReferenceEligibility

  def candidate(title: nil, image_url: "https://cdn.example.com/a.jpg", page_url: nil)
    Appearances::ImageSearch::Result.new(image_url: image_url, page_url: page_url, title: title)
  end

  def verdict(**measurements) = RE.verdict(candidate(**measurements.extract!(:title)),
                                           person_name: "Drew Lock", **measurements)

  def mint(**measurements) = RE.mint_verdict(candidate(**measurements.extract!(:title)),
                                             person_name: "Drew Lock", **measurements)

  # ---- the happy answers ---------------------------------------------------------

  test "a measured, visible, single, correctly titled face is eligible for both" do
    assert_equal RE::ELIGIBLE, verdict(visibility: 0.9, fill: 0.8, subjects: 1)
    assert_equal RE::ELIGIBLE, mint(visibility: 0.9, fill: 0.8, subjects: 1)
  end

  # THE WHOLE DIFFERENCE BETWEEN THE TWO QUESTIONS, in one case: something LOOKED and
  # reported no face size. The sheet takes it, the trainer does not.
  test "a photograph looked at but not sized is a reference and not a training input" do
    assert_equal RE::ELIGIBLE, verdict(visibility: 0.9)
    assert_equal RE::FACE_SIZE_UNMEASURED, mint(visibility: 0.9)
  end

  # ⚠ THE ONE ABSENCE BOTH QUESTIONS REFUSE ON, and it came from production. Measured
  # 2026-09-27 on `jaylen-waddle`: five candidates returned, three scored, ALL FIVE chosen —
  # two of them never judged, and one of those two titled "...Jaylen Waddle and L'Jarius
  # Sneed", a correctly titled photograph of two men. A photograph nothing examined cannot
  # be shown to hold one person's face.
  test "a photograph nothing looked at is refused by both, and says so in its own words" do
    assert_equal RE::FACE_UNSCORED, verdict
    assert_equal RE::FACE_UNSCORED, mint
    refute_equal RE::FACE_SIZE_UNMEASURED, verdict,
                 "nothing examined it — that is a different sentence from 'no size reported'"
  end

  # THE SIZE MEASUREMENT IS NOT WHAT THE REFERENCE RULE REFUSES ON. `.verdict` may never
  # return FACE_SIZE_UNMEASURED, because the operator asked for more references and a photo
  # something looked at is one we can stand behind for a generator that cannot refuse it.
  test "the reference rule never refuses for want of a face SIZE" do
    [{ visibility: 0.9 }, { visibility: 0.9, subjects: 1 }, { visibility: 1.0 }].each do |args|
      refute_equal RE::FACE_SIZE_UNMEASURED, verdict(**args)
      assert_equal RE::ELIGIBLE, verdict(**args)
    end
  end

  # ---- refusals on evidence, which BOTH paths honour -----------------------------

  # A DOCUMENT IS REFUSED FOR WHAT IT IS, EVEN UNJUDGED, and the ORDER of the refusals is
  # what makes that true: `face_unscored` is tested after the evidence-based refusals, so a
  # scanned book with no classifier answer still says "not a photo" rather than the weaker
  # "nobody looked".
  test "an unjudged document still says not a photo, not merely unjudged" do
    scan = candidate(title: "The Rape of the Lock, 1896",
                     image_url: "https://x.test/page1-book.pdf.jpg")

    assert_equal RE::NOT_A_PHOTO, RE.verdict(scan, person_name: "Drew Lock")
  end

  # AND SO IS A STRANGER. The title check is free and deterministic, so it holds on a row
  # nothing ever classified — which is the half of the wrong-person guard that protects
  # every machine with no vision credential.
  test "an unjudged photograph of somebody else still says wrong person" do
    stranger = candidate(title: "Drew Hutton.jpg")

    assert_equal RE::WRONG_PERSON, RE.verdict(stranger, person_name: "Drew Lock")
  end

  test "a document is refused by both, at any score" do
    scan = candidate(title: "The Rape of the Lock, 1896", image_url: "https://x.test/page1-book.pdf.jpg")

    assert_equal RE::NOT_A_PHOTO,
                 RE.verdict(scan, person_name: "Drew Lock", visibility: 0.9, fill: 0.9)
    assert_equal RE::NOT_A_PHOTO,
                 RE.mint_verdict(scan, person_name: "Drew Lock", visibility: 0.9, fill: 0.9)
  end

  # THE 0.15 / 0.0 SPLIT FaceVisibility's PROMPT IS WRITTEN TO MAKE: below NO_PERSON
  # there is nobody in the picture at all, which is a different refusal from a hidden
  # face and the page words it differently.
  test "no person in the picture is not the same refusal as a hidden face" do
    assert_equal RE::NOT_A_PHOTO, verdict(visibility: 0.0, fill: 0.0)
    assert_equal RE::FACE_OBSCURED, verdict(visibility: 0.15, fill: 0.9)
  end

  # THE MEASURED DEFECT. `Drew Hutton.jpg` scored 90 for visibility and ranked second.
  test "a title naming somebody else is refused however good the face is" do
    assert_equal RE::WRONG_PERSON,
                 verdict(title: "Drew Hutton.jpg", visibility: 1.0, fill: 1.0, subjects: 1)
    assert_equal RE::WRONG_PERSON,
                 mint(title: "Drew Hutton.jpg", visibility: 1.0, fill: 1.0, subjects: 1)
  end

  test "more than one visible face cannot be attributed to one man" do
    assert_equal RE::MIXED_SUBJECTS, verdict(visibility: 0.9, fill: 0.9, subjects: 2)
  end

  # A HELMET FILLING THE FRAME IS STILL A HIDDEN FACE. The two numbers are independent
  # and this is the case that proves the size one cannot rescue the other.
  test "a big hidden face is refused on visibility, not rescued by its size" do
    assert_equal RE::FACE_OBSCURED, verdict(visibility: 0.15, fill: 1.0, subjects: 1)
  end

  test "a measured face too small in frame is refused by both" do
    small = RE::MINT_FACE_FILL - 0.01

    assert_equal RE::FACE_TOO_SMALL, verdict(visibility: 0.9, fill: small)
    assert_equal RE::FACE_TOO_SMALL, mint(visibility: 0.9, fill: small)
  end

  # THE THRESHOLD IS INCLUSIVE, which matters because MINT_FACE_FILL is set exactly ON
  # the prompt's "head and shoulders" anchor rather than above it.
  test "a face exactly at the threshold is big enough" do
    assert_equal RE::ELIGIBLE, verdict(visibility: 0.9, fill: RE::MINT_FACE_FILL)
  end

  # ---- the vocabularies that must not drift -------------------------------------

  # THE VERDICT **IS** THE REJECTION REASON, stamped verbatim by
  # Appearances::GatherReferencePhotos. A mapping table between the two lists is exactly
  # where a new refusal gets forgotten and lands on the page as the old reassuring "past
  # the limit".
  test "every refusal is a declared rejection reason, spelled identically" do
    RE::REFUSALS.each do |refusal|
      assert_includes AppearanceReferencePhoto::REJECTION_REASONS, refusal.to_s,
                      "#{refusal} has no home on the model, so no tile could label it"
    end
  end

  test "the thresholds sit in the order the prompt's bands describe" do
    assert_operator RE::NO_PERSON, :<, RE::FACE_VISIBLE,
                    "no-person must sit below the helmet band or every helmet reads as empty"
    assert_operator RE::FACE_VISIBLE, :<=, RE::MINT_FACE_FILL
  end
end
