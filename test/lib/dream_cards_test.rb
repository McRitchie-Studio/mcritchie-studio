# frozen_string_literal: true

# [unit] DreamCards — the card standard for putting dream decisions to Alex in chat
# (docs/agents/modules/dream.md, "The card standard"), the formatter `bin/dream
# cards` prints for the dream-swap SOP and the wrap.
#   ruby -Itest test/lib/dream_cards_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/dream_cards"

class DreamCardsTest < Minitest::Test
  def dream(slug, status: "proposed", souls: [ "carl" ], answer: "Contest it with the evidence.", source: "2026-10-14 · t")
    DreamBank::Dream.new(slug: slug, question: "Is #{slug} right?", answer: answer, why: "A bounce costs more.",
                         status: status, tags: souls.empty? ? {} : { "soul" => souls }, home: souls.first || "platform",
                         source: source, story: "")
  end

  def approved(count, souls: [ "carl" ]) = Array.new(count) { |n| dream("old-#{n}", status: "approved", souls: souls) }

  def row(slug, mean: 0.5, grades: 2, fires: 3, last: "2026-10-01T09:00:00Z", home: "carl")
    { "dream_home" => home, "dream_slug" => slug, "mean_grade" => mean, "grades" => grades, "fires" => fires,
      "last_fired_at" => last }
  end

  def report(layer, approved:, budget:, full:, candidates: [])
    { "layer" => layer, "approved" => approved, "budget" => budget, "full" => full, "candidates" => candidates }
  end

  def test_unit_a_layer_with_room_is_an_add_with_the_full_card
    cards = DreamCards.build(proposed: [ dream("contest-a-wrong-block") ], approved: approved(7))
    text = DreamCards.render(cards)

    assert_equal "1 dream decision for you: 1 add.", text.lines.first.chomp
    assert_includes text, "1 · ADD · soul/carl · 7 of 20 used\n"
    assert_includes text, "   Q: \"Is contest-a-wrong-block right?\"\n   A: \"Contest it with the evidence.\"\n" \
                          "   Why: \"A bounce costs more.\"\n"
    assert_includes text, "   Evidence: source 2026-10-14 · t · carl/contest-a-wrong-block.md\n"
    assert_includes text, "   My call: <approve|change|drop> — <one line> (test first: a must-do belongs in a command, not a dream)"
    assert text.end_with?("#{DreamCards::REPLY}\n"), "the reply grammar closes the message"
  end

  def test_unit_a_full_layer_is_a_swap_naming_the_outs_slug_grade_fires_and_last_fire
    reports = [ report("soul/carl", approved: 20, budget: 20, full: true,
                       candidates: [ row("stale-habit", mean: 0.5, grades: 2, fires: 3), row("next-one") ]) ]
    text = DreamCards.render(DreamCards.build(proposed: [ dream("new-habit") ], approved: approved(20), reports: reports))

    assert_includes text, "1 · SWAP · soul/carl · 20 of 20 used"
    assert_includes text, "Evidence: source 2026-10-14 · t · carl/new-habit.md; OUT `carl/stale-habit` · mean 0.5 of 2 · " \
                          "3 fired · last 2026-10-01"
  end

  def test_unit_the_wrap_names_its_chosen_out_and_two_ins_never_share_one
    reports = [ report("soul/carl", approved: 20, budget: 20, full: true, candidates: [ row("a"), row("b") ]) ]
    chosen = DreamCards.build(proposed: [ dream("in-one") ], approved: [], reports: reports, out_key: "carl/b")
    assert_equal "carl/b", DreamCards.key(chosen.first.out)

    two = DreamCards.build(proposed: [ dream("in-one"), dream("in-two") ], approved: [], reports: reports)
    assert_equal [ "carl/a", "carl/b" ], two.map { |card| DreamCards.key(card.out) }
  end

  def test_unit_a_full_layer_with_no_eligible_out_says_so
    reports = [ report("soul/carl", approved: 20, budget: 20, full: true) ]
    text = DreamCards.render(DreamCards.build(proposed: [ dream("in-one") ], approved: [], reports: reports))
    assert_includes text, "layer full and no out is eligible"
  end

  def test_unit_without_a_board_report_the_local_count_decides
    full = DreamCards.build(proposed: [ dream("in-one", souls: []) ], approved: approved(15, souls: []))
    assert_equal [ "SWAP", "platform", 15, 15 ], full.first.to_h.values_at(:kind, :layer, :used, :cap)
  end

  def test_unit_retire_cards_come_only_from_grades_that_say_the_dream_misleads
    misled = dream("misleads", status: "approved")
    fine = dream("fine", status: "approved")
    thin = dream("thin", status: "approved")
    reports = [ report("soul/carl", approved: 3, budget: 20, full: false,
                       candidates: [ row("misleads", mean: 0.0, grades: 3), row("thin", mean: 0.0, grades: 1),
                                     row("fine", mean: 1.5, grades: 4) ]) ]
    cards = DreamCards.build(proposed: [], approved: [ misled, fine, thin ], reports: reports, retire: true)

    assert_equal [ [ "RETIRE", "misleads" ] ], cards.map { |card| [ card.kind, card.dream.slug ] }
    text = DreamCards.render(cards)
    assert_includes text, "1 · RETIRE · soul/carl · 3 of 20 used"
    assert_includes text, "Evidence: mean 0.0 of 3 · 3 fired · last 2026-10-01 · source"
    assert_empty DreamCards.build(proposed: [], approved: [ misled ], reports: reports), "no RETIRE card unless asked"
  end

  def test_unit_the_sessions_call_and_the_must_do_flag
    rule = dream("always-rerun", answer: "Always re-run the whole CI run before ejecting.")
    cards = DreamCards.build(proposed: [ rule ], approved: [], calls: { "always-rerun" => [ "drop", "bin/release can do it" ] })
    text = DreamCards.render(cards)

    assert_includes text, "   Must-do test: the answer reads as a rule; a must-do belongs in a command, not a dream.\n" \
                          "   My call: drop — bin/release can do it"
  end

  def test_unit_nothing_waiting_prints_one_idea_line
    assert_equal "No dream decisions are waiting.\n", DreamCards.render([])
  end

  def test_unit_parse_calls
    calls, bad = DreamCards.parse_calls([ "new-habit=approve:fills a gap", "old=drop" ])
    assert_nil bad
    assert_equal({ "new-habit" => [ "approve", "fills a gap" ], "old" => [ "drop", "" ] }, calls)
    assert_equal [ nil, "x=bless" ], DreamCards.parse_calls([ "x=bless" ])
  end
end
