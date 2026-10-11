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

  # A LOOK WITH NO NUMBER OMITS THE CLAUSES rather than emitting a placeholder. A
  # template that emitted one would have the model render the angle brackets.
  test "a look with no jersey number omits the clause rather than emitting a placeholder" do
    @look.update_columns(jersey_number: nil)
    prompt = Appearances::CharacterSheetPrompt.call(@look.reload)

    assert_not_includes prompt, "<NUMBER>"
    assert_not_includes prompt, "jersey number ,"
    assert_not_includes prompt, "jersey number "
    assert_not_includes prompt, "above number"
    assert_includes prompt, "nameplate ALLEN clearly legible", "the nameplate stands without a number"
  end

  test "a supplied jersey number reaches both the uniform and the nameplate" do
    prompt = Appearances::CharacterSheetPrompt.call(@look, number: "14")

    assert_includes prompt, "jersey number 14"
    assert_includes prompt, "above number 14"
  end

  # THE LOOK'S OWN COLUMN IS READ BY DEFAULT (task player-sheet-uniform-and-build): a
  # sheet built with no `number:` argument came back numberless on production.
  test "the look's stored jersey number reaches the prompt when no number is passed" do
    @look.update!(jersey_number: 23)
    prompt = Appearances::CharacterSheetPrompt.call(@look.reload)

    assert_includes prompt, "game uniform, jersey number 23"
    assert_includes prompt, "nameplate ALLEN above number 23 clearly legible"
  end

  test "a passed number outranks the stored one, and jersey 0 is a number" do
    @look.update!(jersey_number: 23)

    assert_includes Appearances::CharacterSheetPrompt.call(@look.reload, number: "7"), "jersey number 7,"
    @look.update!(jersey_number: 0)
    assert_includes Appearances::CharacterSheetPrompt.call(@look.reload), "jersey number 0,"
  end

  test "an iced twin with no number of its own wears its base's" do
    @look.update!(jersey_number: 23)
    twin = Appearances::IcedTwin.create!(@look)
    twin.update_columns(jersey_number: nil)

    assert_includes Appearances::CharacterSheetPrompt.call(twin.reload), "jersey number 23"
  end

  # ── THE BACK VIEW IS BARE-HEADED (the operator's review, 2026-10-11) ──

  def back_view_line(prompt) = prompt.lines.find { |l| l.start_with?("Column 2:") }

  test "the back view is bare-headed: no helmet, hair visible, nameplate and number" do
    @look.update!(jersey_number: 23)
    line = back_view_line(Appearances::CharacterSheetPrompt.call(@look.reload))

    assert line, "column 2 has its own line"
    assert_includes line, "NO helmet, bare head with his hair visible from behind"
    assert_includes line, "nameplate ALLEN above number 23"
    assert_includes line, "about fifteen degrees"
    assert_not_includes line, "wearing his helmet"
    assert_not_includes line, "edge of the helmet"
    assert_equal ["NO helmet"], line.scan(/\S*\s?helmet/i).map(&:strip),
                 "the only helmet word left on the back view is the refusal of one"
  end

  test "no panel on either sheet asks for a helmet" do
    [Appearances::CharacterSheetPrompt.call(@look), iced_prompt].each do |prompt|
      assert_not_includes prompt, "wearing his helmet"
      assert_not_includes prompt, "edge of the helmet"
      assert_equal 2, prompt.scan("NO helmet").length, "both full-body columns refuse a helmet"
    end
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

  # ── THE ICED VARIANT (piece 15). Synthetic jewelry only. ──

  def iced_prompt(look = @look, **kwargs) = Appearances::CharacterSheetPrompt.call(look, iced: true, **kwargs)

  test "the standard sheet is untouched: no shades, no jewelry, the original head views" do
    prompt = Appearances::CharacterSheetPrompt.call(@look)

    assert_not_includes prompt, "sunglasses"
    assert_not_includes prompt, "ICED-OUT"
    assert_includes prompt, "  - front smiling#{Appearances::CharacterSheetPrompt::PANEL_SUFFIX}."
    assert_includes prompt, "  - three-quarter looking up#{Appearances::CharacterSheetPrompt::PANEL_SUFFIX}."
  end

  test "the iced sheet keeps the grid, the identity rule and the pads in every panel" do
    prompt = iced_prompt

    assert_includes prompt, "5-column by 2-row grid"
    assert_includes prompt, "SAME individual in every panel"
    assert_includes prompt, "fifteen degrees"
    assert_operator prompt.scan(Appearances::CharacterSheetPrompt::PADS_CLAUSE).length, :>=, 9
  end

  # The operator asked for the SAME shades in every panel. Per the file's rule a
  # must-hold attribute is repeated per panel, so count the panels carrying it.
  test "the same shades and jewelry set are demanded inside every panel" do
    prompt = iced_prompt

    assert_includes prompt, Appearances::CharacterSheetPrompt::SHADES
    assert_equal 8, prompt.scan(Appearances::CharacterSheetPrompt::ICED_PANEL_SUFFIX).length,
                 "two full-body columns and six head views each carry the consistency suffix"
    assert_includes prompt, "CONSISTENCY: the sunglasses and every piece of jewelry are ONE fixed set"
  end

  test "two head views become the rings shot and the grill shot; the other four stay" do
    prompt = iced_prompt
    views = Appearances::CharacterSheetPrompt::ICED_HEAD_VIEWS

    assert_equal 6, views.length
    assert_includes views, Appearances::CharacterSheetPrompt::RINGS_VIEW
    assert_includes views, Appearances::CharacterSheetPrompt::GRILL_VIEW
    assert_not_includes views, "front smiling"
    assert_not_includes views, "three-quarter looking up"
    ["front neutral", "three-quarter left", "right profile", "rear view of the head"].each { |v| assert_includes views, v }
    assert_includes prompt, "GRILL SHOT: front, a big wide open smile"
    assert_includes prompt, "RINGS SHOT: facing the camera, both hands raised"
  end

  test "with no jewelry on file every piece is generic, rings included" do
    prompt = iced_prompt

    generic = Appearances::CharacterSheetPrompt::GENERIC_PIECES
    assert_includes prompt, "chain: #{generic['chain']}"
    assert_includes prompt, "watch on his LEFT wrist: #{generic['watch']}"
    assert_includes prompt, "bracelet on his RIGHT wrist (the hand without the watch): #{generic['bracelet']}"
    assert_includes prompt, "grill: #{generic['grill']}"
    assert_includes prompt, "rings: #{generic['rings']}"
  end

  test "the person's ring records replace the generic rings, named and described" do
    ringer = Person.create!(first_name: "Novice", last_name: "Ringer")
    look = Appearance.create!(person_slug: ringer.slug, descriptor: "Comets home")
    PersonJewelry.create!(person_slug: ringer.slug, kind: "super_bowl_ring", name: "Big Game XC ring", year: 2031,
                          description: "white gold, a pavé comet on a blue stone face")
    PersonJewelry.create!(person_slug: ringer.slug, kind: "championship_ring", name: "Conference ring", year: 2030,
                          description: "yellow gold, red stones around the bezel")
    PersonJewelry.create!(person_slug: ringer.slug, kind: "watch", name: "Moon dial", description: "rose gold, baguette bezel")
    PersonJewelry.create!(person_slug: ringer.slug, kind: "other", name: "Ear studs", description: "two square diamond studs")

    prompt = iced_prompt(look)

    assert_includes prompt, "rings: his own championship rings, each rendered faithfully - " \
                            "2031 Big Game XC ring: white gold, a pavé comet on a blue stone face; " \
                            "2030 Conference ring: yellow gold, red stones around the bezel"
    assert_not_includes prompt, Appearances::CharacterSheetPrompt::GENERIC_PIECES["rings"]
    assert_includes prompt, "watch on his LEFT wrist: Moon dial: rose gold, baguette bezel"
    assert_includes prompt, "also: Ear studs: two square diamond studs"
    assert_includes prompt, "chain: #{Appearances::CharacterSheetPrompt::GENERIC_PIECES['chain']}",
                    "a kind with no record stays generic"
  end

  test "an iced twin reads the iced prompt by default and its base's uniform" do
    twin = Appearances::IcedTwin.create!(@look)
    prompt = Appearances::CharacterSheetPrompt.call(twin, number: "14")

    assert_includes prompt, "ICED-OUT LOOK"
    assert_includes prompt, "Bills home game uniform, jersey number 14"
    assert_not_includes prompt, "· iced game uniform"
    assert_not_includes Appearances::CharacterSheetPrompt.call(@look), "ICED-OUT LOOK"
  end
end
