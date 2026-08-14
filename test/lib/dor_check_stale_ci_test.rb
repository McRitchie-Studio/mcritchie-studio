# frozen_string_literal: true

# bin/dor-check's review gate-zero must not credit a GREEN CI whose base has moved.
# Standalone (no Rails — it shells out to the script with --file fixtures):
#   ruby -Itest test/lib/dor_check_stale_ci_test.rb
#
# THE DEFECT. `gh pr checks` answers for the HEAD COMMIT, and .github/workflows/ci.yml
# triggers on pull_request and on pushes to main/release ONLY. A merge into `accepted`
# therefore moves a PR's base and re-runs NOTHING: the green stays green while the
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

  def dor_check(drift:, role:, ci: "green")
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => d,
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => CODE,
        "DOR_CHECK_PR_FILES" => CODE,
        "DOR_CHECK_CI_STATUS" => ci,
        "DOR_CHECK_CI_BASE_DRIFT" => drift,
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      )
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
    assert_match(/pushes to main\/release only|BEHIND its base/i, errors_of(verdict),
                 "the refusal must name WHY the green is stale, or the reader will just re-run CI")
    refute verdict["ready"]
    assert_equal 1, code
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
