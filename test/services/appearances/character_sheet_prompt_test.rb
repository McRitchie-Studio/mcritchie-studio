require "test_helper"

# [unit] THE SHEET PROMPT, tested without spending.
#
# Every revision of this text cost a generated sheet to learn, which is the whole
# reason it is a tested object rather than a heredoc inside the service. These
# tests are cheap; the lessons behind them were not.
class Appearances::CharacterSheetPromptTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    @person = people(:josh_allen)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  # ⚠ THE RULE THAT COST A ROUND. A global styling clause stated ONCE is overridden
  # by a local description that implies otherwise: "in full pads" at the top, then
  # panels called "head-and-shoulders portraits", produced photo-day crops with no
  # pads. So the clause is repeated INSIDE every panel's own instruction.
  #
  # COUNTS THE PANELS RATHER THAN ASSERTING "IT APPEARS SOMEWHERE". A single
  # occurrence in the preamble is exactly the failure mode, and `assert_includes`
  # would pass on it.
  test "the pads clause is repeated inside every panel, not stated once" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    occurrences = prompt.scan(Appearances::CharacterSheetPrompt::PADS_CLAUSE).length

    assert_operator occurrences, :>=, 9,
                    "expected the pads clause on the preamble, both full-body columns and all " \
                    "six head views — found #{occurrences}. One occurrence is the bug this rule exists for."
  end

  test "every head view is named and carries its own pads clause" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    Appearances::CharacterSheetPrompt::HEAD_VIEWS.each do |view|
      assert_includes prompt, "#{view}#{Appearances::CharacterSheetPrompt::PANEL_SUFFIX}",
                      "#{view.inspect} must carry the suffix on its own line"
    end
  end

  # THE OPERATOR-APPROVED LAYOUT, and the corrections that are not to be
  # re-litigated: 5x2, left two columns full body, fifteen degrees not ninety.
  test "the approved layout and the softened head turn survive" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    assert_includes prompt, "5-column by 2-row grid"
    assert_includes prompt, "LEFT TWO COLUMNS"
    assert_includes prompt, "RIGHT THREE COLUMNS"
    assert_includes prompt, "fifteen degrees"
    assert_includes prompt, "NOT a sharp ninety-degree"
  end

  # ⚠ THERE IS NO JERSEY NUMBER IN THE DATA MODEL. Measured 2026-09-27: neither
  # `athletes` nor `roster_spots` carries one. A template that emitted the
  # placeholder would have the model render the angle brackets.
  test "an unknown jersey number omits the clause rather than emitting a placeholder" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    assert_not_includes prompt, "<NUMBER>"
    assert_not_includes prompt, "jersey number ,"
    assert_not_includes prompt, "jersey number "
  end

  test "a supplied jersey number reaches both the uniform and the nameplate" do
    prompt = Appearances::CharacterSheetPrompt.call(@look, number: "14")

    assert_includes prompt, "jersey number 14"
    assert_includes prompt, "above number 14"
  end

  # THE NAMEPLATE IS THE SURNAME, UPPERCASED, because that is what is printed on
  # the back of a jersey.
  test "the nameplate uses the surname in upper case" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    assert_includes prompt, "nameplate ALLEN"
    assert_not_includes prompt, "nameplate Josh Allen"
  end

  # READS THE STORED VALUE, not the string that was typed. Appearance normalizes
  # `colorway` (it downcases), so asserting the input would test the fixture
  # rather than the prompt — and would break the day that normalization changes.
  test "the colourway falls back through the look rather than going blank" do
    assert_includes Appearances::CharacterSheetPrompt.call(@look), "Bills home game uniform",
                    "with no colorway on file the descriptor is what the operator typed"

    @look.update!(colorway: "Bills colour rush")
    @look.reload
    assert_includes Appearances::CharacterSheetPrompt.call(@look), "#{@look.colorway} game uniform"
    assert_not_includes Appearances::CharacterSheetPrompt.call(@look), "Bills home game uniform",
                        "a named colorway outranks the descriptor"
  end

  # THE ONE INSTRUCTION THE WHOLE SHEET DEPENDS ON.
  test "it asks for the same individual, faithful to the reference" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    assert_includes prompt, "SAME individual in every panel"
    assert_includes prompt, "faithful to the reference photograph"
  end
end
