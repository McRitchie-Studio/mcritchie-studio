# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../../bin/lib/stacked_pr"

# The shared predicate both halves of the stacked-PR guard ask
# (/tasks/review-guards-stacked-prs). bin/ship and bin/pr-review answered this question
# separately for a release, which is how the reviewer half kept retargeting and merging
# stacks after the builder half stopped.
class StackedPrTest < Minitest::Test
  OPEN_PARENT = JSON.generate([{ "number" => 624, "url" => "https://github.com/o/r/pull/624" }])

  def reader(json, ok = true) = ->(_base) { [json, ok] }

  def test_a_base_that_is_an_open_prs_head_is_a_stack_and_names_it
    got = StackedPr.assess("feat/parent", &reader(OPEN_PARENT))

    assert_equal :stacked, got[:state]
    assert_equal 624, got[:parent]["number"]
    refute StackedPr.repair?(got), "a deliberate stack must never be repaired"
    assert_match(/open PR #624/, StackedPr.why(got))
  end

  def test_a_base_no_open_pr_heads_is_repaired
    got = StackedPr.assess("feat/merged-and-deleted", &reader("[]"))

    assert_equal :not_stacked, got[:state]
    assert StackedPr.repair?(got)
  end

  # An empty base is the live hole this closed: real gh treats `--head ""` as NO FILTER and
  # returns every open PR, so believing it would preserve a mis-based PR by coincidence.
  # The reader must not even be CALLED.
  def test_an_empty_base_is_no_answer_and_never_reaches_gh
    called = false
    got = StackedPr.assess("") { |_b| called = true; [OPEN_PARENT, true] }

    assert_equal :no_base, got[:state]
    assert StackedPr.repair?(got)
    refute called, "an empty base must not be sent to gh, where it means NO FILTER"
  end

  def test_a_nil_base_is_treated_as_empty
    assert_equal :no_base, StackedPr.assess(nil, &reader(OPEN_PARENT))[:state]
  end

  # An unreadable probe falls to the repair, because nothing else repairs a mis-based PR.
  def test_an_unreadable_probe_is_repaired_and_says_which_question_went_unasked
    got = StackedPr.assess("feat/parent", &reader("gh: 403", false))

    assert_equal :unreadable, got[:state]
    assert StackedPr.repair?(got)
    assert_match(/could not read/, StackedPr.why(got))
  end

  def test_every_state_renders_a_sentence
    %i[no_base unreadable not_stacked stacked].each do |state|
      refute_empty StackedPr.why({ state: state, parent: { "number" => 1 } }).to_s
    end
  end
  # ── guard_base: THE DECISION, DRIVEN ────────────────────────────────────────────
  #
  # These exist because a SOURCE test could not see the refusal being disabled: a mutant
  # replacing its condition with `if false` left the refusal text in place and every
  # source assertion green. Here the writer is a SPY, so "it did not retarget" is an
  # assertion rather than a reading.
  def spies(list_json, list_ok = true)
    said = []
    edited = []
    { said: said, edited: edited,
      list: ->(_head) { [list_json, list_ok] },
      edit: ->(head) { edited << head; true },
      say: ->(line) { said << line } }
  end

  def guard(base, sp, accepted: "accepted")
    StackedPr.guard_base(base: base, accepted: accepted, slug: "demo-task",
                         pr_url: "https://github.com/o/r/pull/701",
                         list: sp[:list], edit: sp[:edit], say: sp[:say])
  end

  def test_a_stacked_base_is_refused_and_NOTHING_is_retargeted
    sp = spies(OPEN_PARENT)

    assert_equal :refused, guard("feat/parent", sp)
    assert_empty sp[:edited], "a deliberate stack must never be retargeted — this is the whole guard"
    assert_match(/REFUSING to merge demo-task/, sp[:said].join("\n"))
    assert_match(/open PR #624/, sp[:said].join("\n"), "the refusal must NAME the parent")
    assert_match(/#624 merges FIRST/, sp[:said].join("\n"), "…and say what has to land first")
  end

  def test_a_mis_based_pr_is_still_retargeted
    sp = spies("[]")

    assert_equal :retargeted, guard("feat/merged-and-deleted", sp)
    assert_equal ["feat/merged-and-deleted"], sp[:edited], "the repair arm must survive"
  end

  def test_an_accepted_base_touches_nothing
    sp = spies(OPEN_PARENT)

    assert_equal :proceed, guard("accepted", sp)
    assert_empty sp[:edited]
    assert_empty sp[:said], "the ordinary case must be silent"
  end

  def test_an_empty_base_proceeds_without_asking_gh
    sp = spies(OPEN_PARENT)

    assert_equal :proceed, guard("", sp)
    assert_empty sp[:edited]
  end

  def test_an_unreadable_probe_still_retargets
    sp = spies("gh: 403", false)

    assert_equal :retargeted, guard("feat/unknown", sp)
    assert_equal ["feat/unknown"], sp[:edited]
  end

  def test_a_failed_retarget_reports_itself
    said = []
    outcome = StackedPr.guard_base(base: "feat/x", accepted: "accepted", slug: "demo-task",
                                   pr_url: "https://github.com/o/r/pull/701",
                                   list: ->(_h) { ["[]", true] }, edit: ->(_h) { false },
                                   say: ->(l) { said << l })

    assert_equal :retarget_failed, outcome
    assert_match(/could not retarget/, said.join("\n"))
  end
end
