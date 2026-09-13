# frozen_string_literal: true

# TaskPrSet — the PRs a task actually has, and which of their CI verdicts governs.
# Standalone (no Rails):
#   ruby -Itest test/lib/task_pr_set_test.rb
#
# The gate-level proof lives in test/lib/dor_check_multi_repo_pr_test.rb, which drives
# the whole of bin/dor-check; this file pins the properties that file cannot cheaply
# enumerate — every branch of the target resolver, and the ordering law of the fold.
#
# EVERY REGEX ALTERNATIVE IS SHOWN TO MATCH SOMETHING. A guard shipped in this repo
# with /\bn't\b/ — which matches no English contraction — while claiming soundness
# against negation, so a pattern here is never trusted for looking right: each shape
# it is meant to accept is asserted to be accepted, and each shape it is meant to
# reject is asserted to be rejected.
require "minitest/autorun"
require_relative "../../bin/lib/task_pr_set"

class TaskPrSetTest < Minitest::Test
  HUB_PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/11"
  SAT_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/575"
  VAULT_PR = "https://github.com/McRitchie-Studio/turf-vault/pull/17"

  # ── the URL reader ──────────────────────────────────────────────────────────

  def test_it_reads_the_repo_out_of_a_pr_url
    assert_equal "turf-monster", TaskPrSet.repo_from_url(SAT_PR)
    assert TaskPrSet.pr_url?(SAT_PR)
  end

  # THE REJECTING HALF, shown to reject. A pattern asserted only on what it accepts is
  # satisfied by /.*/, which would classify every string as a readable PR.
  def test_it_refuses_things_that_are_not_pull_request_urls
    [
      "https://github.com/McRitchie-Studio/turf-monster",           # a repo, no PR
      "https://github.com/McRitchie-Studio/turf-monster/issues/575", # an ISSUE
      "https://github.com/McRitchie-Studio/turf-monster/pull/",      # no number
      "turf-monster", "", "   "
    ].each do |value|
      refute TaskPrSet.pr_url?(value), "#{value.inspect} is not a PR URL, but was read as one"
      assert_equal "", TaskPrSet.repo_from_url(value)
    end
  end

  # ── the target list ─────────────────────────────────────────────────────────

  def test_the_primary_pr_comes_first_then_the_register_by_sorted_key
    targets = TaskPrSet.targets("pr_url" => SAT_PR,
                                "pr_urls" => { "turf-vault" => VAULT_PR,
                                               "mcritchie-studio" => HUB_PR,
                                               "turf-monster" => SAT_PR })

    assert_equal %w[turf-monster mcritchie-studio turf-vault], targets.map { |t| t[:repo] },
                 "the primary must lead (every existing caller means it by 'the PR'), and the register " \
                 "must follow in SORTED key order so two runs never disagree about what they described"
  end

  # The primary is normally ALSO registered under its own key. Counting it twice would
  # read one PR twice and report a single-repo task as multi-repo — which would drag it
  # onto the fail-closed multi-repo path for no reason.
  def test_the_primary_is_not_counted_twice_when_the_register_repeats_it
    targets = TaskPrSet.targets("pr_url" => HUB_PR, "pr_urls" => { "mcritchie-studio" => HUB_PR })

    assert_equal 1, targets.size, "the same URL under two fields is ONE pull request: #{targets.inspect}"
    refute TaskPrSet.multi?("pr_url" => HUB_PR, "pr_urls" => { "mcritchie-studio" => HUB_PR })
  end

  def test_a_blank_or_missing_field_contributes_nothing
    assert_empty TaskPrSet.targets({})
    assert_empty TaskPrSet.targets("pr_url" => "  ", "pr_urls" => { "x" => "" })
    assert_empty TaskPrSet.targets("pr_url" => nil, "pr_urls" => "not-a-hash")
  end

  # A RECORDED url the gate cannot parse is NOT the same fact as "no PR yet", and the
  # distinction is what lets bin/dor-check refuse a repo whose verdict cannot be
  # obtained instead of silently skipping it.
  def test_a_recorded_but_unparseable_url_is_kept_and_flagged_unreadable
    targets = TaskPrSet.targets("pr_url" => HUB_PR,
                                "pr_urls" => { "turf-monster" => "https://example.com/not-a-pr" })

    assert_equal 2, targets.size, "an unparseable entry must not be dropped — dropping it is the silence"
    unreadable = targets.last
    refute unreadable[:readable]
    assert_equal "turf-monster", unreadable[:repo], "it falls back to the REGISTER KEY for its repo name, " \
                                                    "which is the only name a refusal can print"
  end

  # ── the fold ────────────────────────────────────────────────────────────────

  def entry(state)
    { target: { url: "u-#{state}", repo: state.to_s }, ci: { state: state } }
  end

  def test_the_worst_verdict_governs_whatever_order_it_arrives_in
    forward = TaskPrSet.governing([entry(:green), entry(:red)])
    reverse = TaskPrSet.governing([entry(:red), entry(:green)])

    assert_equal :red, forward[:ci][:state]
    assert_equal :red, reverse[:ci][:state],
                 "order decided the verdict — a first-non-green fold can be steered by which URL somebody " \
                 "recorded first"
  end

  # WORST-OF IS NOT FIRST-NON-GREEN, and only a case with TWO non-green states can
  # tell them apart. Both refuse, so `ready` cannot distinguish them — but the state
  # and the PR the remedy names both would, and a refusal that names the pending PR
  # while a sibling is RED sends the reader to wait on the wrong thing.
  def test_the_worst_of_two_non_green_states_governs_not_the_first_of_them
    assert_equal :red, TaskPrSet.governing([entry(:pending), entry(:red)])[:ci][:state]
    assert_equal :red, TaskPrSet.governing([entry(:unreadable), entry(:red)])[:ci][:state]
    assert_equal :conflicted, TaskPrSet.governing([entry(:pending), entry(:conflicted)])[:ci][:state]
  end

  # Each rung of the table, shown to outrank green. Asserting only red would leave the
  # rest of the ordering unmeasured, and the no-verdict family is exactly the half a
  # sibling's green must never be allowed to paper over.
  # ── the staged-merge exception (/tasks/gate-zero-blocks-staged-merges) ─────────────

  def primary(state, base: nil) = { target: { url: "u-primary", repo: "engine", recorded_as: nil },
                                    ci: { state: state, base: base }.compact }
  def sibling(state, base: nil, key: "turf-monster") = { target: { url: "u-#{key}", repo: key, recorded_as: key },
                                                         ci: { state: state, base: base }.compact }

  def test_a_sibling_merged_into_accepted_does_not_govern
    got = TaskPrSet.governing([primary(:green), sibling(:merged, base: "accepted"),
                               sibling(:merged, base: "accepted", key: "mcritchie-studio")])
    assert_equal :green, got[:ci][:state], "landed staged siblings governed a green review target"
    assert_equal "u-primary", got[:target][:url]
  end

  def test_a_merged_review_target_still_governs
    assert_equal :merged, TaskPrSet.governing([primary(:merged, base: "accepted"), sibling(:green)])[:ci][:state]
  end

  def test_only_a_merge_into_accepted_qualifies
    assert_equal :merged, TaskPrSet.governing([primary(:green), sibling(:merged, base: "release")])[:ci][:state]
    assert_equal :merged, TaskPrSet.governing([primary(:green), sibling(:merged)])[:ci][:state],
                 "a merged verdict with NO recorded base is not evidence of landing"
    assert_equal :closed, TaskPrSet.governing([primary(:green), sibling(:closed, base: "accepted")])[:ci][:state]
  end

  def test_a_landed_sibling_never_hides_a_live_failure
    got = TaskPrSet.governing([primary(:green), sibling(:merged, base: "accepted"), sibling(:red, key: "rolio")])
    assert_equal :red, got[:ci][:state]
  end

  def test_a_set_with_no_live_target_left_still_governs
    got = TaskPrSet.governing([sibling(:merged, base: "accepted"), sibling(:merged, base: "accepted", key: "rolio")])
    assert_equal :merged, got[:ci][:state], "nothing left to review must refuse, not return nil or pass"
  end

  def test_every_non_green_state_outranks_a_green_sibling
    %i[red conflicted ci_less closed merged pending unreadable unverified no_pr none].each do |state|
      governing = TaskPrSet.governing([entry(:green), entry(state)])

      assert_equal state, governing[:ci][:state], "#{state} lost to a green sibling"
    end
  end

  def test_a_state_the_table_has_never_heard_of_governs_above_all_of_them
    governing = TaskPrSet.governing([entry(:red), entry(:a_state_nobody_classified)])

    assert_equal :a_state_nobody_classified, governing[:ci][:state],
                 "an unclassified state must govern — a table that defaults novel states to 'harmless' is a " \
                 "deny-list, and every state added to ci_status.rb later joins the safe side silently"
    assert_equal TaskPrSet::UNKNOWN_CI_SEVERITY, TaskPrSet.severity(:a_state_nobody_classified)
  end

  def test_all_green_still_returns_a_green_entry_and_an_empty_list_returns_nothing
    assert_equal :green, TaskPrSet.governing([entry(:green), entry(:green)])[:ci][:state]
    assert_nil TaskPrSet.governing([])
  end

  # The governing entry carries its own PR URL, because every remedy bin/dor-check
  # prints names a repo — and a refusal about turf-monster's red CI that tells you to
  # look at turf-vault is the same cross-repo confusion in different clothes.
  def test_the_governing_entry_carries_the_pr_the_verdict_came_from
    governing = TaskPrSet.governing([
      { target: { url: HUB_PR, repo: "mcritchie-studio" }, ci: { state: :green } },
      { target: { url: SAT_PR, repo: "turf-monster" }, ci: { state: :red } }
    ])

    assert_equal SAT_PR, governing[:target][:url]
  end
end
