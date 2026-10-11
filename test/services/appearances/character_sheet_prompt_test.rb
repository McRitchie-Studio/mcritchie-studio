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
    assert_includes prompt, %(nameplate reading "ALLEN" in block capitals, clearly legible), "the nameplate stands without a number"
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
    assert_includes prompt, %(nameplate reading "ALLEN" in block capitals above number 23, clearly legible)
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
    assert_includes line, %(nameplate reading "ALLEN" in block capitals above number 23)
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

    assert_includes prompt, 'nameplate reading "ALLEN"'
    assert_not_includes prompt, "Josh Allen"
  end

  # ── THE SURNAME IS QUOTED LITERAL TEXT (task sheet-nameplate-quotes-surname) ──
  #
  # Production, 2026-10-11: "nameplate LITTLE above number 39" came back reading
  # PLAYER. A surname that is an English word read as a description of the plate.
  # Synthetic surnames only; the read is the back-view line that ships.

  %w[Little Young Will].each do |word|
    test "a common-word surname (#{word}) is quoted literal text on the back view" do
      line = back_view_line(Appearances::CharacterSheetPrompt.call(@look, surname: word, number: "39"))

      assert_includes line, %(, nameplate reading "#{word.upcase}" in block capitals above number 39, clearly legible)
      assert_not_includes line, "nameplate #{word.upcase}", "the bare unquoted form is the defect"
    end
  end

  test "the clause reads cleanly with no number" do
    @look.update_columns(jersey_number: nil)
    line = back_view_line(Appearances::CharacterSheetPrompt.call(@look.reload, surname: "Little"))

    assert_includes line, %(, nameplate reading "LITTLE" in block capitals, clearly legible,)
  end

  { "O'Neil" => "O'NEIL", "Smith-Njigba" => "SMITH-NJIGBA", "St. Brown" => "ST. BROWN" }.each do |given, plate|
    test "a punctuated surname (#{given}) survives intact inside the quotes" do
      line = back_view_line(Appearances::CharacterSheetPrompt.call(@look, surname: given))

      assert_includes line, %(nameplate reading "#{plate}" in block capitals)
      assert_not_includes line, "\\", "no escaping artefacts"
    end
  end

  test "a double quote inside the surname cannot close the literal early" do
    line = back_view_line(Appearances::CharacterSheetPrompt.call(@look, surname: %(Lit"tle)))

    assert_includes line, %(nameplate reading "LITTLE")
    assert_equal 2, line.count('"')
  end

  test "no surname means no nameplate clause and no empty quotes" do
    [nil, "  ", %("")].each do |given|
      prompt = Appearances::CharacterSheetPrompt.call(nil, surname: given, number: "39")

      assert_not_includes prompt, "nameplate", "surname #{given.inspect} draws no plate"
      assert_not_includes prompt, '""'
      assert_includes back_view_line(prompt), "visible from behind, #{Appearances::CharacterSheetPrompt::PADS_CLAUSE}"
    end
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
    assert_includes prompt, "faithful to the IDENTITY ANCHOR photograph"
  end

  # ── THE BADGES, THE ROLES AND THE BUILD (task player-sheet-uniform-and-build) ──

  # A stand-in for the build's Appearances::SheetReferences with fixed counts, so the
  # prompt is read without any photo row or fetch check.
  FakeRefs = Struct.new(:roles, :uniform_urls, :body_url, :archetype, keyword_init: true)

  def refs(identity: 1, uniform: 0, body: false, archetype: body_archetypes(:nfl_qb_skill))
    spans = []
    cursor = 1
    [[:identity, identity], [:uniform, uniform], [:body, body ? 1 : 0]].each do |role, n|
      next if n.zero?

      spans << [cursor, cursor + n - 1, role]
      cursor += n
    end
    FakeRefs.new(roles: spans, uniform_urls: Array.new(uniform) { |i| "https://u.test/#{i}.jpg" },
                 body_url: body ? "https://b.test/body.png" : nil, archetype: archetype)
  end

  test "the badges are named on every sheet, and copied from photos when there are photos" do
    plain = Appearances::CharacterSheetPrompt.call(@look, references: refs)
    assert_includes plain, Appearances::CharacterSheetPrompt::UNIFORM_FROM_TEXT
    assert_includes plain, "the team logo on BOTH shoulders, the NFL shield at the collar"
    assert_includes plain, "No captain patch."
    assert_not_includes plain, "UNIFORM REFERENCE"

    with_photos = Appearances::CharacterSheetPrompt.call(@look, references: refs(uniform: 3))
    assert_includes with_photos, Appearances::CharacterSheetPrompt::UNIFORM_FROM_PHOTOS
    assert_includes with_photos, "copy them EXACTLY from the UNIFORM REFERENCE images"
    assert_includes with_photos, "captain \"C\" patch on the chest ONLY if the uniform references show one"
    assert_not_includes with_photos, "No captain patch."
  end

  test "every attached image is named by its role, in the fixed order face, uniform, body" do
    prompt = Appearances::CharacterSheetPrompt.call(@look, references: refs(uniform: 3, body: true))

    identity = prompt.index("  - Image 1: IDENTITY ANCHOR - this man's face.")
    uniform = prompt.index("  - Images 2-4: UNIFORM REFERENCE - real game photos")
    body = prompt.index("  - Image 5: BODY BUILD REFERENCE - match this body's build and proportions; " \
                        "take nothing else from it: not the face, not the uniform.")
    assert identity && uniform && body, "all three roles are named with their positions"
    assert_operator identity, :<, uniform
    assert_operator uniform, :<, body
    assert_includes prompt, "Take NOTHING else: not a face, not a body, not a pose"
  end

  test "a role with no image is not named, and the numbering closes up" do
    prompt = Appearances::CharacterSheetPrompt.call(@look, references: refs(body: true))

    assert_includes prompt, "  - Image 1: IDENTITY ANCHOR"
    assert_includes prompt, "  - Image 2: BODY BUILD REFERENCE"
    assert_not_includes prompt, "UNIFORM REFERENCE -"
  end

  test "the archetype's description always rides; the image rule only with its image" do
    lineman = body_archetypes(:nfl_lineman)

    text_only = Appearances::CharacterSheetPrompt.call(@look, references: refs(archetype: lineman))
    assert_includes text_only, "BUILD: he has #{lineman.description}."
    assert_not_includes text_only, Appearances::CharacterSheetPrompt::BODY_IMAGE_RULE

    with_image = Appearances::CharacterSheetPrompt.call(@look, references: refs(body: true, archetype: lineman))
    assert_includes with_image, Appearances::CharacterSheetPrompt::BODY_IMAGE_RULE
  end

  test "a look that resolves no archetype still asks for an NFL build" do
    prompt = Appearances::CharacterSheetPrompt.call(@look, references: refs(archetype: nil))

    assert_includes prompt, Appearances::CharacterSheetPrompt::GENERIC_BUILD
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
