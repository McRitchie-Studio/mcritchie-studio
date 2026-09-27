require "test_helper"

# [unit] THE CHIPS AND EXPLANATIONS ON A REFERENCE-PHOTO TILE.
#
# ⚠ WHY THIS FILE EXISTS AT ALL, stated plainly because it is a lesson rather than a
# convention: every chip here was previously exercised only through a rendered page, and
# every page fixture with a face score used 0.92. `face_score_chip` is a three-band
# `if / elsif / else`, and a 0.92 returns on the FIRST branch — so the `elsif` naming a
# threshold constant was never once evaluated by 3,390 green tests. When that constant
# moved to another class the line became `uninitialized constant`, the suite stayed green,
# and the whole scouting page answered HTTP 500 on the first locally rendered row scored
# 0.70.
#
# THE RULE THAT FOLLOWS: a banded helper needs a case PER BAND. An untested band is
# unexecuted code that reads as covered, and the coverage of the branch above it is what
# hides it.
class AppearancesHelperTest < ActionView::TestCase
  Photo = AppearanceReferencePhoto

  def photo(**attrs)
    Photo.new({ appearance_slug: "look-helper", image_url: "https://x.test/a.jpg",
                source: Photo::SOURCE_SEARCH }.merge(attrs))
  end

  # ---- the face-score chip, one case per band ------------------------------------

  test "a clearly visible face is styled as a pass" do
    assert_includes face_score_chip(photo(face_score: 0.92)), "text-success-ink"
  end

  # THE BAND THAT HAD NO CASE. Any value between FACE_VISIBLE and 0.75 lands here, and
  # this is the only test in the suite that evaluates that line.
  test "a face above the visible floor but below the good band is styled as a warning" do
    middle = (Appearances::ReferenceEligibility::FACE_VISIBLE + 0.75) / 2

    assert_includes face_score_chip(photo(face_score: middle)), "text-warning-ink"
    assert_includes face_score_chip(photo(face_score: Appearances::ReferenceEligibility::FACE_VISIBLE)),
                    "text-warning-ink", "the floor itself is visible enough to warn, not to fail"
  end

  # A HELMET. Styled as a failure, and the band boundary is the same constant that refuses
  # it — so the colour and the rejection can never disagree on one tile.
  test "a hidden face is styled as a failure" do
    assert_includes face_score_chip(photo(face_score: 0.15)), "text-danger-ink"
  end

  # ---- the wrong-person note ------------------------------------------------------

  test "the wrong-person note names the stranger and the person we wanted" do
    note = wrong_person_note(photo(title: "Keenan Allen.jpg"), "Josh Allen")

    assert_equal "the title names Keenan Allen, not Josh Allen", note
  end

  test "a photograph of the right person earns no note, and neither does an absent name" do
    assert_nil wrong_person_note(photo(title: "Josh Allen, 22 October 2023"), "Josh Allen")
    assert_nil wrong_person_note(photo(title: "Keenan Allen.jpg"), nil)
    assert_nil wrong_person_note(photo(title: nil), "Josh Allen")
  end

  # THE NOTE LEADS THE REASONING AND RETURNS EARLY. Once the answer is "this is somebody
  # else", the photograph's aspect ratio is not what the operator is asking about.
  test "a wrong-person tile explains only that, not its shape and rank" do
    reasons = photo_merit_reasons(photo(title: "Keenan Allen.jpg", width: 3000, height: 2000,
                                       position: 4), "Josh Allen")

    assert_equal 1, reasons.length
    assert_match "Keenan Allen", reasons.first[:label]
    assert_equal :bad, reasons.first[:tone]
  end

  # ---- the mint-evidence chip -----------------------------------------------------

  # EVERY BRANCH, because this is the chip that tells the operator which generator a
  # photograph can reach and a wrong one is a confident lie about a purchase.
  test "the cached headshot is the only input labelled as measured to mint" do
    evidence = mint_evidence(photo(source: Photo::SOURCE_HEADSHOT), "Josh Allen")

    assert_equal :good, evidence[:tone]
    assert_match "measured", evidence[:label]
  end

  test "a measured, big enough face is reported with its own percentage" do
    evidence = mint_evidence(photo(face_score: 0.9, face_fill: 0.82, face_subjects: 1), "Josh Allen")

    assert_equal :good, evidence[:tone]
    assert_match "82%", evidence[:label]
  end

  test "a measured tiny face names the percentage and the floor it missed" do
    evidence = mint_evidence(photo(face_score: 0.9, face_fill: 0.12, face_subjects: 1), "Josh Allen")

    assert_equal :bad, evidence[:tone]
    assert_match "12%", evidence[:label]
    assert_match "60%", evidence[:title]
  end

  # SOMETHING LOOKED AND REPORTED NO SIZE. The chip has to say what that costs — the sheet
  # still uses this photograph, the trainer does not.
  test "an unmeasured face size says so, and says the sheet still uses it" do
    evidence = mint_evidence(photo(face_score: 0.9), "Josh Allen")

    assert_match "not measured", evidence[:label]
    assert_match "character sheet", evidence[:title]
  end

  # NOTHING LOOKED AT ALL — the state production was choosing from, and the one with no
  # number on the tile for an operator to disbelieve. Its chip must not read the same as the
  # one above: those two have different remedies and different consequences.
  test "a photograph nothing looked at gets its own words, not the unmeasured ones" do
    evidence = mint_evidence(photo(face_score: nil), "Josh Allen")

    assert_equal :bad, evidence[:tone]
    assert_match "nothing looked", evidence[:label]
    refute_equal mint_evidence(photo(face_score: 0.9), "Josh Allen")[:label], evidence[:label]
  end

  # THE FREE EVIDENCE STILL BEATS NO EVIDENCE: three of the four measured failures were
  # wide sideline crops, so an unmeasured WIDE photograph gets the stronger sentence.
  test "an unjudged wide crop is labelled with the shape that failed every mint" do
    evidence = mint_evidence(photo(width: 3207, height: 2135), "Josh Allen")

    assert_equal :bad, evidence[:tone]
    assert_match "wide crop", evidence[:label]
  end

  test "a photograph refused as somebody else carries no mint chip at all" do
    assert_nil mint_evidence(photo(title: "Keenan Allen.jpg", face_fill: 0.9), "Josh Allen"),
               "a chip about minting would be furniture on a tile that is the wrong man"
  end

  # ---- the rejection labels -------------------------------------------------------

  # EVERY DECLARED REASON NEEDS A LABEL, or a tile prints the fallback "not chosen" and the
  # operator is told nothing. This is the assertion that fails when a reason is added and
  # its label is not.
  test "every rejection reason the model declares has words for the operator" do
    Photo::REJECTION_REASONS.each do |reason|
      label = rejection_label(photo(rejection_reason: reason))

      assert_not_equal "not chosen", label, "#{reason} has no label, so its tile says nothing"
    end
  end
end
