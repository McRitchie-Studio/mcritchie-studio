# frozen_string_literal: true

# bin/dor-check's review gate-zero must not credit a GREEN CI whose base has moved.
# Standalone (no Rails — it shells out to the script with --file fixtures):
#   ruby -Itest test/lib/dor_check_stale_ci_test.rb
#
# THE DEFECT. `gh pr checks` answers for the HEAD COMMIT, and .github/workflows/ci.yml
# triggers on pull_request and on pushes to main, release AND `accepted`. A merge into
# `accepted` therefore DOES start a run — but that run grades the `accepted` TIP, a tree
# this PR is not in, and nothing re-runs THIS PR against the moved base.
# The green stays green while the
# tree it described stops being the tree the merge would produce. On 2026-08-13 the
# review gate advanced on a green dated three days earlier against a base 30+ commits
# ahead, and twice more the same day a green predated the change on `accepted` it was
# implicitly claiming to cover.
#
# WHY :unknown MUST NOT REFUSE, and why that is the subtle half. GitHub computes
# mergeability asynchronously and lags, so a review that races the computation reads
# UNKNOWN through no fault of the branch. Refusing there would wedge the review lane
# on a fact nobody asserted — the mirror-image bug of the one above. So the rule is
# "refuse on an ASSERTED drift", never "refuse on the absence of a reassurance", and
# `test_an_unknown_mergeability_does_not_refuse` is what holds that line.
#
# THE ROLE SPLIT IS ALSO LOAD-BEARING. The builder's submit-side run is provisional
# by construction (the CI wait moved to the review handoff), so staleness there is
# not its business — review re-reads it. A fix that refused in BOTH roles would block
# every handoff on a base that moves several times a day.
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../../bin/lib/ci_status"

class DorCheckStaleCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/77"
  CODE = "app/models/thing.rb"

  STALE = /STALE/

  # THE TWO-SIDED GUARD (/tasks/audit-vanishes-when-git-fails).
  #
  # This assertion used to be a single `assert_match` over the alternation
  # /pushes to main\/release only|BEHIND its base/ — and its FIRST ARM IS THE FALSE
  # WORDING THIS GATE ONCE SHIPPED, kept alive beside the corrected one. A regression all
  # the way back to the retracted claim therefore stayed GREEN: a guard that accepts
  # exactly what it was written to reject.
  #
  # The fact, checkable in one `sed -n 26,27p .github/workflows/ci.yml`:
  #   push: branches: [ main, release, accepted ]
  # `accepted` has been in that list since 2026-08-14 (ecd0ffe8). A merge into `accepted`
  # DOES start a run. The gate's argument is NOT "no run exists" — it is that the run
  # which exists graded the `accepted` TIP, a tree this PR is not in, and that the true
  # argument is strictly STRONGER because it survives the objection "but I can see the
  # run".
  #
  # So the guard is now TWO-SIDED, and both halves are load-bearing: an `assert_match`
  # alone cannot notice a message that makes the true claim AND the false one, and a
  # `refute_match` alone cannot notice a message that makes neither.
  RUNS_ON_BASE = /DOES run on pushes to/i
  RETRACTED    = /pushes to main\/release only/i

  def task
    {
      "slug" => "task-stale-ci", "title" => "T",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
        "acceptance" => ["reject a CI verdict older than its base"],
        "repositories" => ["myapp"],
        "risk_tags" => ["gate-integrity"],
        "test_plan" => ["[unit] drift", "[integration] gate"],
        "post_deploy_cmd" => "none",
        "checks_run" => ["[unit] drift", "[integration] gate"]
      } }
    }
  end

  # `base:` injects the PR's BASE BRANCH. It exists for the stacked-PR row below: the
  # refusal's remedy has to name the branch this PR actually merges into, and until
  # /tasks/audit-vanishes-when-git-fails that string was the literal "accepted".
  def dor_check(drift:, role:, ci: "green", base: nil)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = SessionEnv.neutralized({
        "DOR_CHECK_DIFF_ROOT" => d,
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => CODE,
        "DOR_CHECK_PR_FILES" => CODE,
        "DOR_CHECK_CI_STATUS" => ci,
        "DOR_CHECK_CI_BASE_DRIFT" => drift,
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      }.merge(base ? { "DOR_BASE_BRANCH" => base } : {}))
      out = IO.popen(env, "#{BIN} --file #{path} --json --gate-role #{role} 2>/dev/null", &:read)
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def errors_of(verdict)
    Array(verdict["errors"]).join(" | ")
  end

  # ── [unit] CiStatus.base_drift, the pure reader ─────────────────────────────

  def test_base_drift_reads_behind_current_and_unknown
    behind = JSON.generate("state" => "OPEN", "mergeStateStatus" => "BEHIND", "mergeable" => "MERGEABLE")
    clean  = JSON.generate("state" => "OPEN", "mergeStateStatus" => "CLEAN",  "mergeable" => "MERGEABLE")
    blank  = JSON.generate("state" => "OPEN", "mergeStateStatus" => "UNKNOWN", "mergeable" => "UNKNOWN")

    assert_equal :behind,  CiStatus.base_drift(behind)
    assert_equal :current, CiStatus.base_drift(clean)
    assert_equal :unknown, CiStatus.base_drift(blank),
                 "'GitHub has not computed it' must never read as 'we checked, it is fine'"
    assert_equal :unknown, CiStatus.base_drift("not json at all")
  end

  # ── [unit] a green whose base moved is named stale, not credited ────────────

  def test_a_green_behind_its_base_is_refused_at_review
    verdict, code = dor_check(drift: "behind", role: "review")

    assert_match STALE, errors_of(verdict),
                 "a green describing a superseded tree must not advance a review"
    assert_match(/BEHIND its base/i, errors_of(verdict),
                 "the refusal must name WHY the green is stale, or the reader will just re-run CI")
    assert_match RUNS_ON_BASE, errors_of(verdict),
                 "the refusal must make the TRUE argument (a run for that merge EXISTS, and it " \
                 "graded the base TIP) — the false one is disprovable in one sed and gets the " \
                 "whole gate routed around"
    refute_match RETRACTED, errors_of(verdict),
                 "THE RETRACTED CLAIM IS BACK. ci.yml's `push:` list is [ main, release, accepted ] " \
                 "(.github/workflows/ci.yml:26-27, `accepted` added 2026-08-14 in ecd0ffe8), so a " \
                 "merge into `accepted` DOES start a run and this sentence is false"
    refute verdict["ready"]
    assert_equal 1, code
  end

  # THE STACKED-PR ROW (reported during the review of gate-credits-a-stale-green).
  #
  # The refusal used to hardcode the literal "accepted" into both halves of its remedy —
  # the trigger claim and the `git rebase origin/accepted` instruction — while the PR's
  # REAL base was read into `base_branch` eighty lines later. On a stacked PR based on a
  # feature branch, the gate therefore refused correctly and then told the reviewer to
  # rebase onto the wrong branch. Same family as the row above: a gate whose text asserts
  # something the reviewer can disprove is a gate they learn to route around.
  def test_the_refusal_names_the_pr_s_actual_base_not_a_hardcoded_accepted
    verdict, code = dor_check(drift: "behind", role: "review", base: "feat/parent")

    assert_equal 1, code, "the refusal itself is unchanged — only the branch it names"
    assert_match(/feat\/parent/, errors_of(verdict),
                 "the remedy must name the branch this PR actually merges into; sending a stacked " \
                 "PR to rebase onto `accepted` is a wrong instruction stated with a gate's authority" \
                 "\n#{errors_of(verdict)}")
    refute_match(/origin\/accepted/, errors_of(verdict),
                 "…and it must not ALSO name `accepted`, which is the hardcode surviving beside " \
                 "the fix rather than being replaced by it")

    # THE OTHER HALF OF THE NEW CONDITIONAL. Re-pointing the trigger sentence at
    # base_branch instead of withholding it would trade the retracted claim for its
    # MIRROR IMAGE: ci.yml's push list is [main, release, accepted], so "ci.yml DOES run
    # on pushes to `feat/parent`" is exactly as disprovable as "main/release only" was.
    # Without this row a fix that merely interpolated would pass every assertion above.
    refute_match RUNS_ON_BASE, errors_of(verdict),
                 "the trigger claim must be WITHHELD on a base ci.yml does not push-trigger, not " \
                 "re-pointed at it — that is the same false sentence facing the other way"
    assert_match(/not one of ci\.yml's push branches/, errors_of(verdict),
                 "…and the reader must be TOLD why no run exists, or they will go hunting for one " \
                 "and conclude the gate is wrong\n#{errors_of(verdict)}")
  end

  # ── [unit] the hardcoded trigger list cannot go stale in silence ────────────
  #
  # bin/dor-check keeps its own copy of ci.yml's push branches, because the refusal has to
  # decide WHICH true sentence it is entitled to make about the base it just named. A
  # second copy of a fact is a drift risk, and the fact in question is the one this whole
  # file exists because the gate once got wrong — so the copy is pinned to the source.
  #
  # ci_workflow_triggers_test.rb asserts ci.yml INCLUDES each ladder rung. That is a
  # floor, not an equality: a fourth push branch added there would leave this list short
  # and dor-check would tell a reviewer on that branch that no run exists when one does.
  def test_dor_check_s_trigger_list_matches_ci_yml
    source = File.read(File.expand_path("../../bin/dor-check", __dir__))
    literal = source[/^CI_PUSH_BRANCHES = %w\[([^\]]*)\]/, 1]

    refute_nil literal,
               "CI_PUSH_BRANCHES is gone or was reshaped — this guard reads it by source, so a " \
               "rename must fail here rather than quietly stop checking anything"

    yml = File.read(File.expand_path("../../.github/workflows/ci.yml", __dir__))
    push = yml[/^  push:\n    branches: \[([^\]]*)\]/, 1]
    refute_nil push, "could not read ci.yml's `push: branches:` list"

    assert_equal push.split(",").map(&:strip).sort, literal.split.sort,
                 "dor-check's copy of ci.yml's push branches has DRIFTED from ci.yml. The refusal " \
                 "picks its argument off this list: a branch missing here is told 'no run exists' " \
                 "when one does, and that is the retracted claim wearing a different name"
  end

  # ── [unit] the control: a green on the current base is still credited ──────

  def test_a_green_on_the_current_base_still_advances
    verdict, code = dor_check(drift: "current", role: "review")

    refute_match STALE, errors_of(verdict), "a current green is exactly what review advances on"
    assert verdict["ready"], "the gate must still pass work that is genuinely ready: #{errors_of(verdict)}"
    assert_equal 0, code
  end

  # THE OTHER HALF OF THE CONTROL. Refusing on "GitHub has not told us yet" would be
  # the same class of defect in the opposite direction.
  def test_an_unknown_mergeability_does_not_refuse
    verdict, code = dor_check(drift: "unknown", role: "review")

    refute_match STALE, errors_of(verdict),
                 "mergeability lags by design — racing it is not evidence of drift"
    assert_equal 0, code
  end

  # ── [integration] the role split ───────────────────────────────────────────

  def test_the_builder_role_is_not_blocked_by_a_moved_base
    verdict, code = dor_check(drift: "behind", role: "builder")

    refute_match STALE, errors_of(verdict),
                 "submit-side is provisional by construction; review owns the authoritative CI verdict"
    assert_equal 0, code
  end

  # A red CI must keep its OWN remedy — staleness must not overwrite the louder,
  # more actionable refusal.
  def test_a_red_ci_keeps_its_own_refusal
    verdict, code = dor_check(drift: "behind", role: "review", ci: "red")

    assert_match(/RED/, errors_of(verdict), "red outranks stale — the remedy is different")
    refute verdict["ready"]
    assert_equal 1, code
  end
end
