require "test_helper"

# THE PARSER THAT MUST NEVER GUESS.
#
# A wrong integer here raises nothing: it lands in `athletes.height_inches`, feeds
# Athlete#physical_brief's "Build:" line and reaches the character-sheet prompt as a
# body of the wrong shape. So these tests assert BOTH halves of the contract — the
# shapes it must read, and the shapes it must REFUSE — because a parser that is
# merely permissive passes every "does it parse 6' 2\"" test ever written.
class Athletes::DisplayMeasurementTest < ActiveSupport::TestCase
  DM = Athletes::DisplayMeasurement

  # ─── height: the shapes measured on the wire ────────────────────────────────

  test "height reads the exact shape ESPN sends" do
    # Measured 2026-09-27: Bo Nix displayHeight "6' 2\"", Ashton Jeanty "5' 8\"",
    # and `height` nil on both, so these strings are the only source of the number.
    assert_equal 74, DM.height_inches("6' 2\"")
    assert_equal 68, DM.height_inches("5' 8\"")
    assert_equal 77, DM.height_inches("6' 5\"")
  end

  test "height reads a round height with or without its inches part" do
    assert_equal 72, DM.height_inches("6' 0\"")
    assert_equal 72, DM.height_inches("6'0\""), "no space between feet and inches"
    assert_equal 72, DM.height_inches("6'"), "no inches part at all"
  end

  test "height reads the hyphen and ft spellings a second source may use" do
    assert_equal 74, DM.height_inches("6-2")
    assert_equal 74, DM.height_inches("6 ft 2")
  end

  test "height refuses an inches part that is not an inches part" do
    # 12 is a foot the writer forgot to carry. Both readings are speculation, so
    # neither is stored — this is the case a lenient parser turns into 73 silently.
    assert_nil DM.height_inches("5' 12\"")
    assert_nil DM.height_inches("5' 13\"")
  end

  test "height refuses a bare number because the unit is unknowable" do
    # 72 inches or 72 feet? Reading it as inches would be right here and wrong the
    # day a source switches to centimetres.
    assert_nil DM.height_inches("72")
  end

  test "height refuses trailing prose rather than reading past it" do
    assert_nil DM.height_inches("6' 2\" (est)")
    assert_nil DM.height_inches("six feet")
  end

  test "height refuses a total outside the inhabited range" do
    assert_nil DM.height_inches("3' 0\""), "36in — a misparse, not a football player"
    assert_nil DM.height_inches("9' 0\"")
    assert_equal 48, DM.height_inches("4' 0\""), "the low bound itself is accepted"
    assert_equal 96, DM.height_inches("8' 0\""), "the high bound itself is accepted"
  end

  test "height reads every blank marker as nothing known" do
    [nil, "", "  ", "-", "--", "N/A", "n/a", "none", "TBD"].each do |blank|
      assert_nil DM.height_inches(blank), "#{blank.inspect} should read as unknown"
    end
  end

  # ─── weight ────────────────────────────────────────────────────────────────

  test "weight reads the exact shape ESPN sends" do
    assert_equal 217, DM.weight_lbs("217 lbs")
    assert_equal 208, DM.weight_lbs("208 lbs")
  end

  test "weight reads the unit spellings and its absence" do
    assert_equal 217, DM.weight_lbs("217")
    assert_equal 217, DM.weight_lbs("217 lb")
    assert_equal 217, DM.weight_lbs("217 pounds")
  end

  test "weight refuses trailing prose and out-of-range numbers" do
    assert_nil DM.weight_lbs("217 lbs (est)")
    assert_nil DM.weight_lbs("99 lbs")
    assert_nil DM.weight_lbs("451 lbs")
    assert_nil DM.weight_lbs("2026"), "a stray year must not become a weight"
  end

  test "weight reads zero and the blank markers as nothing known" do
    # A weight of zero is not a weight, unlike a jersey number of zero.
    assert_nil DM.weight_lbs("0")
    assert_nil DM.weight_lbs("0 lbs")
    [nil, "", "--", "N/A"].each { |blank| assert_nil DM.weight_lbs(blank) }
  end

  # ─── jersey number: the column this task added ──────────────────────────────

  test "jersey number reads the string and display spellings" do
    assert_equal 30, DM.jersey_number("30")
    assert_equal 2, DM.jersey_number("2")
    assert_equal 41, DM.jersey_number("41")
    assert_equal 30, DM.jersey_number("#30")
  end

  test "jersey number zero is a number, not a blank" do
    # The league has allowed 0 since 2023, so the usual "0 means unknown" shortcut
    # would erase a real number.
    assert_equal 0, DM.jersey_number("0")
    assert_equal 0, DM.jersey_number("#0")
  end

  test "jersey number refuses anything that is not one or two digits" do
    assert_nil DM.jersey_number("300")
    assert_nil DM.jersey_number("QB")
    [nil, "", "--"].each { |blank| assert_nil DM.jersey_number(blank) }
  end
end
