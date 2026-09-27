# frozen_string_literal: true

require "test_helper"

# [component] ONE CARD ON THE MODEL PIPELINE BOARD.
#
# The card's whole job is to answer "what is this and why is it stuck" WITHOUT a click,
# so these are assertions about what a human can read off it at a glance:
#
#   THE BLOCKER SENTENCE is always present. It is the one element that may never be
#                        dropped for space.
#   THE BOARD CONTRACT   id="card-<slug>", .kanban-card, data-slug, data-stage — and
#                        data-stage carries the RENDERED lane, not the `stage` column,
#                        which is NULL on most looks.
#   NO VENDOR NAME       the Generation lane names a stage; a card reports whatever
#                        `artifacts.source` holds, so a new generator needs no view change.
#   CONTRAST IS SPENT ON EXCEPTIONS a chip that appeared on every card would make the one
#                        card that needs attention invisible in its column.
#
# NAMED FOR ITS TIER (…ViewTest) per the convention test/views/app_ladder_row_test.rb
# sets out: two files defining the same class name under different superclasses raise
# `superclass mismatch` the moment something loads both, and bin/fast-check does.
class ModelPipelineCardViewTest < ActionView::TestCase
  include ModelPipelineHelper

  def look(**attrs)
    Appearance.new({ slug: "look-abc123", person_slug: "josh-allen", descriptor: "Bills home" }.merge(attrs))
  end

  def reading(appearance = look, **facts)
    Appearances::LookReading.new(appearance: appearance, person_name: "Josh Allen", **facts)
  end

  # RETURNS THIS RENDER'S OWN HTML, and the tests that render more than once assert
  # against THAT rather than against `rendered` / `css_select`.
  #
  # Measured 2026-09-27: a second `render` in one test method does not cleanly replace
  # what `css_select` reads — a card rendered with `draggable: false` still answered with
  # the first render's `cursor-grab` class, so the negative half of a two-render test
  # passed against the positive half's markup. `ActionView::TestCase#render` returns the
  # output of the call that produced it, which is unambiguous whatever the ivar is doing.
  def render_card(reading, draggable: true)
    render partial: "model_pipeline/look_card", locals: { reading: reading, draggable: draggable }
  end

  test "the card emits the board identity contract with the RENDERED lane" do
    render_card reading(look(colorway: "c", stage: "generation"), athlete: true, headshot: true)

    card = css_select("#card-look-abc123.kanban-card").first
    refute_nil card, "the card must carry the dom id and class the studioBoard factory reads"
    assert_equal "look-abc123", card["data-slug"]
    assert_equal "generation", card["data-stage"],
                 "data-stage is the lane the card renders in, not the hand-placement column"
  end

  test "the card names the person and the look and links to the model page" do
    render_card reading

    assert_select "[data-test='look-card-link']", text: /Josh Allen · Bills home/
    assert_select "a[data-test='look-card-link'][href='/people/josh-allen/models/look-abc123']", 1
  end

  # THE ONE LINE THE BOARD EXISTS FOR.
  test "every card carries its blocker sentence" do
    [
      [reading(look(colorway: nil)), /Nothing says what to generate/],
      [reading(look(colorway: "c")), /No photograph on file/],
      [reading(look(colorway: "c"), athlete: true, headshot: true), /cached headshot/],
      [reading(look(colorway: "c"), candidate_count: 20), /20 candidates found/],
      [reading(look(colorway: "c"), candidate_count: 20, chosen_count: 6), /6 chosen/],
      [reading(look(colorway: "c"), artifact_count: 2), /2 images delivered/]
    ].each do |card_reading, sentence|
      html = render_card(card_reading)
      blocker = Nokogiri::HTML.fragment(html).at_css("[data-test='look-card-blocker']")

      refute_nil blocker, "a #{card_reading.derived_stage} card rendered no blocker sentence"
      assert_match sentence, blocker.text, "the #{card_reading.derived_stage} card's sentence"
    end
  end

  # THE TRADE IS THE ONE CARD THE OPERATOR MUST NOT SCROLL PAST, so it gets the red edge
  # and a chip, and the captured team is restyled as the thing that is wrong.
  test "a traded look is flagged and edged in danger" do
    render_card reading(look(team_slug: "cincinnati-bengals", stage: "generation"),
                        athlete: true, athlete_team_slug: "denver-broncos", artifact_count: 1)

    assert_select "[data-test='look-card-stale']", text: /re-define · traded/
    assert_select "[data-test='look-card-blocker']", text: /captured cincinnati-bengals, now denver-broncos/
    assert_includes css_select(".kanban-card").first["class"], "border-l-danger"
  end

  # A PLACEMENT SET ASIDE IS SAID OUT LOUD. The alternative is a card that appears to
  # have moved itself, which teaches the operator the board eats his input.
  test "a hand placement a trade set aside is named on the card" do
    render_card reading(look(team_slug: "cincinnati-bengals", stage: "generation"),
                        athlete: true, athlete_team_slug: "denver-broncos", artifact_count: 1)

    assert_select "[data-test='look-card-placement-set-aside']", text: /your Generation placement set aside/
  end

  test "a card placed ahead of its evidence says where the data puts it" do
    render_card reading(look(colorway: "c", stage: "generation"), athlete: true, headshot: true)

    assert_select "[data-test='look-card-hand-placed']", text: /placed by hand · data says Source/
    assert_includes css_select(".kanban-card").first["class"], "border-l-primary"
    assert_select "[data-test='look-card-stale']", 0
  end

  test "a card resting where its evidence puts it carries no placement chip and no edge" do
    render_card reading(look(colorway: "c"), athlete: true, headshot: true)

    assert_select "[data-test='look-card-hand-placed']", 0
    assert_select "[data-test='look-card-placement-set-aside']", 0
    assert_select "[data-test='look-card-stale']", 0
    assert_includes css_select(".kanban-card").first["class"], "border-l-transparent"
  end

  # ── the generator is DATA ──────────────────────────────────────────────────────

  test "the card reports which generator produced its image, whatever it is called" do
    render_card reading(look(colorway: "c"), artifact_count: 1, artifact_source: "a-generator-nobody-has-written-yet")

    assert_select "[data-test='look-card-generator']", text: /via a-generator-nobody-has-written-yet/
  end

  test "a card with no delivered image names no generator" do
    render_card reading(look(colorway: "c"), candidate_count: 9, chosen_count: 3)

    assert_select "[data-test='look-card-generator']", 0
  end

  # THE STRUCTURE OUTLIVES ANY ONE PROVIDER. The operator's constraint: the Generation
  # lane names a STAGE, so no vendor may be hard-coded into the markup. Asserted against
  # the rendered card for EVERY lane, because a name in a `case` in one branch is exactly
  # what this forbids and exactly what a single-lane check would miss.
  test "no vendor name is rendered on any card in any lane" do
    vendors = /higgsfield|openai|fal\b|midjourney|stability/i
    [
      reading(look(colorway: nil)),
      reading(look(colorway: "c")),
      reading(look(colorway: "c"), athlete: true, headshot: true),
      reading(look(colorway: "c"), candidate_count: 9, chosen_count: 3),
      reading(look(colorway: "c", higgsfield_reference_id: "r",
                   higgsfield_reference_status: Appearances::CreateCharacterReference::PENDING_STATUSES.first),
              candidate_count: 9, chosen_count: 3),
      reading(look(colorway: "c"), artifact_count: 1)
    ].each do |card_reading|
      refute_match vendors, render_card(card_reading),
                   "a lane names a stage, never a provider — #{card_reading.derived_stage} card named one"
    end
  end

  # ── contrast is spent on exceptions ───────────────────────────────────────────

  test "a complete definition adds no chip" do
    html = render_card(reading(look(colorway: "c"), athlete: true, height_inches: 77,
                               weight_lbs: 237, physique_described: true))

    refute_match(/no measurements/, html)
    refute_match(/no physique/, html)
  end

  test "an incomplete definition adds exactly one chip in the Defined lane" do
    html = render_card(reading(look(colorway: "c"), athlete: true))

    assert_match(/no measurements or physique/, html)
    assert_equal 1, html.scan(/no measurements/).length
  end

  # THE GAP BELONGS TO THE LANE THAT OWNS IT. Printed on every card it was an amber chip
  # in all five lanes — it is the normal state of every athlete until a backfill runs —
  # competing with the one red card that actually needed attention. And it blocks nothing:
  # the recipe generates from a headshot, a colourway and a number.
  test "the definition gap is not printed outside the Defined lane" do
    %w[source model generation].each do |lane|
      card_reading = case lane
                     when "source" then reading(look(colorway: "c"), athlete: true, headshot: true)
                     when "model" then reading(look(colorway: "c"), athlete: true, candidate_count: 9, chosen_count: 4)
                     else reading(look(colorway: "c"), athlete: true, artifact_count: 1)
                     end

      assert_equal lane, card_reading.board_stage
      refute_match(/no measurements/, render_card(card_reading),
                   "the #{lane} lane printed a define-step gap it does not own")
    end
  end

  # ONE FACT, ONE CHIP. Appearance.file_for_colorway! titleizes the colorway INTO the
  # descriptor, so the common look would otherwise print the same words twice.
  test "a colorway the descriptor already says is not printed twice" do
    html = render_card(reading(look(descriptor: "Bills Home", colorway: "bills home"),
                               athlete: true, headshot: true))

    assert_equal 1, html.scan(/[Bb]ills [Hh]ome/).length
  end

  test "a colorway the descriptor does not say is printed" do
    html = render_card(reading(look(descriptor: "Primary", colorway: "bills home"),
                               athlete: true, headshot: true))

    assert_match(/bills home/, html)
  end

  # A PUBLIC READER CANNOT DRAG, so the card does not invite them to: the grab cursor is
  # the affordance, and the board passes no move or reorder endpoint for them either.
  # Asserted against each render's OWN returned HTML — see #render_card's note on why a
  # second render in one test method is not safe to read through `css_select`.
  test "the grab cursor appears only when the board is draggable" do
    assert_match(/cursor-grab/, render_card(reading(look(colorway: "c")), draggable: true))
    refute_match(/cursor-grab/, render_card(reading(look(colorway: "c")), draggable: false))
  end

  # NOTHING ON THIS BOARD SPENDS. The three paths that do are admin-gated POSTs on
  # AppearancesController, reached from the card's LINK — never from a control on the card.
  test "a card carries no form and no button that could start work" do
    render_card reading(look(colorway: "c"), athlete: true, headshot: true)

    assert_select "form", 0
    assert_select "button", 0
    assert_select "[data-method='post']", 0
  end
end
