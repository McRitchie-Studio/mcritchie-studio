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

  # ---- which of the four searches found a photograph ------------------------------
  #
  # THE LABEL IS HOW THE OPERATOR REFERS TO A VARIANT — "no helmet", not
  # "Josh Allen Buffalo Bills no helmet", which is unreadable on a thumbnail-sized tile.

  test "a variant query is shortened to the words that make it a variant" do
    subject = "Josh Allen Buffalo Bills"

    assert_equal "no helmet", search_variant_label("#{subject} no helmet", subject: subject)
    assert_equal "laughing", search_variant_label("#{subject} laughing", subject: subject)
  end

  # THE BARE SUBJECT IS NAMED RATHER THAN RENDERED BLANK. An empty string on a page is
  # indistinguishable from a missing value, and this is the variant the other three are
  # measured against — the one whose row a reader most needs to find.
  test "the bare-subject query is labelled rather than left empty" do
    assert_equal "name only", search_variant_label("Josh Allen", subject: "Josh Allen")
  end

  # ⚠ STRIPPED, NOT LOOKED UP AGAINST QUERY_VARIANTS, and this is the case that decides
  # between the two. A row filed by a variant since REMOVED from the list is exactly the
  # row a reader is trying to account for after re-tuning the list; a lookup would label it
  # as having no variant at all. Stripping reads the row's own stored query, so a retired
  # variant still names itself.
  test "a query from a variant we no longer ship still names its own variant" do
    assert_equal "winking", search_variant_label("Josh Allen winking", subject: "Josh Allen")
    refute_includes Appearances::GatherReferencePhotos::QUERY_VARIANTS, "winking",
                    "the precondition: this variant is not in the shipped list"
  end

  # A QUERY THAT DOES NOT START WITH THE SUBJECT IS GIVEN BACK WHOLE. It happens for real:
  # the subject carries the TEAM, so a traded player's older rows carry his old team. The
  # whole query is the honest answer — it says the row came from a question we no longer ask
  # — and truncating it against a subject it never contained would invent a variant.
  test "a query for a different subject is shown whole rather than mangled" do
    stale = "Josh Allen Denver Broncos no helmet"

    assert_equal stale, search_variant_label(stale, subject: "Josh Allen Buffalo Bills")
  end

  test "a row with no query at all says where it came from instead of nothing" do
    assert_equal "an earlier search", search_variant_label(nil, subject: "Josh Allen")
    assert_equal "an earlier search", search_variant_label("  ", subject: "Josh Allen")
  end

  # A MISSING SUBJECT MUST NOT SWALLOW THE QUERY. The partial reads `subject` through
  # local_assigns, so a caller that forgets to pass it gets the whole query — longer, never
  # wrong — rather than a stripped-to-nothing label.
  test "with no subject to strip the whole query is shown" do
    assert_equal "Josh Allen no helmet", search_variant_label("Josh Allen no helmet", subject: nil)
  end
end
