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
    listed = []
    { said: said, edited: edited, listed: listed,
      list: ->(head) { listed << head; [list_json, list_ok] },
      edit: ->(head) { edited << head; true },
      say: ->(line) { said << line } }
  end

  def guard(base, sp, accepted: "accepted")
    StackedPr.guard_base(base: base, base_read_ok: true, repo_scope: "o/r", accepted: accepted,
                         slug: "demo-task", pr_url: "https://github.com/o/r/pull/701",
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

  # ── AT A MERGE, ANYTHING UNPROVEN REFUSES (/tasks/review-refuses-unread-base) ────
  #
  # These two INVERT the answers bin/ship gets, deliberately, and the inversion is the
  # point. ship calls StackedPr.assess and repairs on a doubt: a wrongly-retargeted stack
  # is loud and recoverable (`gh pr edit <n> --base <parent>`) and ship never merges, so
  # guessing wrong costs a retarget. guard_base is REVIEW's caller, and there the retarget
  # is followed one line later by a MERGE — so guessing wrong costs the parent's unmerged
  # work on `accepted`, which `bin/release prepare` then promotes to QA and production.
  # The cost asymmetry inverts at the merge, so the decision inverts with it.
  #
  # This deliberately contradicts ms#1391's bullet "Empty or unread base falls to the
  # repair path". That bullet was written for bin/ship's arm and is still right there.
  def test_an_unreadable_probe_REFUSES_rather_than_retargeting
    sp = spies("gh: 502 Bad Gateway", false)

    assert_equal :refused, guard("feat/unknown", sp)
    assert_empty sp[:edited], "a base the guard could not READ must not be retargeted into a merge"
    assert_match(/could not read/, sp[:said].join("\n"), "the refusal must name the question that went unasked")
  end

  # The refusal must name the call that actually DIED. The base read SUCCEEDED on this arm —
  # it returned the branch — and only the PROBE failed, so saying "the base could not be read"
  # would send the reader to the wrong gh call.
  def test_the_unreadable_refusal_names_the_probe_not_the_base_read
    sp = spies("gh: 502 Bad Gateway", false)
    guard("feat/parent", sp)
    said = sp[:said].join("\n")

    assert_match(/whether feat\/parent is another open PR's head/, said)
    refute_match(/base could not be READ/, said, "the base read fine on this arm; the probe did not")
  end

  # A gate that says only "no" is one reviewers route around. Each arm refuses for a different
  # reason, so each names a different way forward.
  def test_every_refusal_carries_a_remedy
    [["feat/parent", spies(OPEN_PARENT)], ["", spies(OPEN_PARENT)], ["feat/x", spies("gh: 502", false)]].each do |base, sp|
      guard(base, sp)
      assert_match(/^  → /, sp[:said].join("\n"), "the #{base.inspect} refusal named no way forward")
    end
  end

  def test_an_empty_base_REFUSES_at_a_merge
    sp = spies(OPEN_PARENT)

    assert_equal :refused, guard("", sp)
    assert_empty sp[:edited]
    assert_empty sp[:listed], "an empty base must not be sent to gh, where --head means NO FILTER"
  end

  # The base READ itself failing was not even reaching the guard: merge_feature_pr skipped
  # the whole block on base_ok=false and merged with no base check at all.
  def test_a_failed_base_read_refuses_before_anything_is_asked
    sp = spies(OPEN_PARENT)
    outcome = StackedPr.guard_base(base: "feat/parent", base_read_ok: false, repo_scope: "o/r",
                                   accepted: "accepted", slug: "demo-task",
                                   pr_url: "https://github.com/o/r/pull/701",
                                   list: sp[:list], edit: sp[:edit], say: sp[:say])

    assert_equal :refused, outcome
    assert_empty sp[:listed], "a base that could not be read is not a base to probe against"
    assert_empty sp[:edited]
  end

  # The probe is repo-scoped from a regex on the PR url. If that misses, an unscoped
  # `gh pr list` runs against the CWD repo (the hub) and a real satellite stack comes back
  # :not_stacked with ok=true — a false NEGATIVE that never even surfaces as unreadable.
  def test_an_unresolvable_repo_scope_refuses_rather_than_probing_the_wrong_repo
    sp = spies(OPEN_PARENT)
    outcome = StackedPr.guard_base(base: "feat/parent", base_read_ok: true, repo_scope: "",
                                   accepted: "accepted", slug: "demo-task",
                                   pr_url: "https://github.com/o/r/pull/701",
                                   list: sp[:list], edit: sp[:edit], say: sp[:say])

    assert_equal :refused, outcome
    assert_empty sp[:listed], "asking the WRONG repo answers a different question than the one owed"
    assert_empty sp[:edited]
  end

  def test_a_failed_retarget_reports_itself
    said = []
    outcome = StackedPr.guard_base(base: "feat/x", base_read_ok: true, repo_scope: "o/r",
                                   accepted: "accepted", slug: "demo-task",
                                   pr_url: "https://github.com/o/r/pull/701",
                                   list: ->(_h) { ["[]", true] }, edit: ->(_h) { false },
                                   say: ->(l) { said << l })

    assert_equal :retarget_failed, outcome
    assert_match(/could not retarget/, said.join("\n"))
  end
end
