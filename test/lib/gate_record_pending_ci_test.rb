require "test_helper"
require Rails.root.join("bin/lib/ci_gate").to_s

# /tasks/pending-ci-paints-check — the PRODUCER half of "a running CI is not a CI that
# passed".
#
# THE DEFECT, AND WHY IT IS THE DANGEROUS DIRECTION. `CiGate.gate_row` has answered the
# builder role "pending" for an unsettled CI since the arm was written. The gates card's
# glyph chain was fail → ✗, `running` → ◌, NO_VERDICT_RESULTS → ⚠, DEFAULT → ✓ — and
# "pending" is in none of the first three. So the durable GateRun row for a CI that was
# STILL RUNNING rendered with the PASS glyph. Its four siblings
# (/tasks/gate-logs-auth-as-red, /tasks/refused-review-records-fail,
# /tasks/no-pr-records-as-fail) each manufactured a FAILURE, which gets audited because
# it blocks somebody; this one manufactured a SUCCESS, which nobody audits.
#
# THE VALUE DID NOT CHANGE, AND THAT IS DELIBERATE. `"pending"` is pinned builder-side
# by test/lib/dor_check_exempt_ci_test.rb and rides bin/dor-check's --json as
# `ci_gate_result`. This task gave the word a CONSTANT and a GLYPH; renaming it would
# have been a second, unrelated break dressed as a fix.
#
# Pure: no subprocess, no ENV, no board — `gate_row` is the single function that decides
# the recorded word, so the producer's half is testable without a fixture.
class GateRecordPendingCiTest < ActiveSupport::TestCase
  # THE TWO ROLES ANSWER DIFFERENTLY HERE, UNLIKE EVERY NO-VERDICT VALUE, because they
  # ask different questions. Review's gate-zero asks "may this merge NOW" — an unsettled
  # CI is a legitimate no. The builder asks "is my work certified" before the checks have
  # had time to run — where an unsettled CI is not yet an answer.
  test "[unit] a pending CI records the pending row for the builder and a refusal for review" do
    builder = CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)

    assert_equal CiGate::GATE_ROW_PENDING, builder
    assert_equal "pending", builder,
                 "the literal is pinned by dor_check_exempt_ci_test and bin/dor-check's --json; " \
                 "this task glyphs the word, it does not rename it"
    assert_equal "fail", CiGate.gate_row({ state: :pending }, review_role: true, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :pending }, review_role: true, review_refused: true)
  end

  # THE PRODUCER AND THE RENDERER MUST AGREE ON THE WORD. bin/lib/ci_gate.rb is a bin/
  # lib and cannot load the model, so the value exists twice — the split RUNNING_RESULT
  # and the no-verdict four already live with. Drift here means the producer writes a
  # word the card does not match; before this task that was a silent ✓, and it is now a
  # visible `?`, but it is still wrong and this pins it shut.
  test "[unit] the producer's pending value equals the one the card paints" do
    assert_equal GateRun::PENDING_RESULT, CiGate::GATE_ROW_PENDING
  end

  # IN-FLIGHT IS NOT NO-VERDICT. The distinction is the reason `pending` did not simply
  # get appended to NO_VERDICT_RESULTS, which would have been the one-line fix and the
  # wrong one: that family means the answer was never GIVEN and prescribes finding out
  # why, while this means the answer is COMING and prescribes waiting.
  test "[unit] pending is an in-flight result and NOT a member of the no-verdict family" do
    assert_includes GateRun::IN_FLIGHT_RESULTS, GateRun::PENDING_RESULT
    assert_includes GateRun::IN_FLIGHT_RESULTS, GateRun::RUNNING_RESULT

    refute_includes GateRun::NO_VERDICT_RESULTS, GateRun::PENDING_RESULT,
                    "pending means the answer is coming; the no-verdict family means it was never given, " \
                    "and their remedies differ (wait vs. go find out why)"
    refute_includes CiGate::GATE_ROW_NO_VERDICT, CiGate::GATE_ROW_PENDING
  end

  # AND :pending IS NOT A CERT-WAIVER STATE. /tasks/no-pr-records-as-fail established
  # that the row family and the waiver family are two separate questions; this is the
  # second value where they diverge. A full local cert may not stand in for a CI that
  # simply has not finished — the answer is coming, so wait for it.
  test "[unit] a pending CI is not a state a local cert may stand in for" do
    refute_includes CiGate::CI_NO_VERDICT_STATES, :pending,
                    "a cert stands in for missing evidence, never for evidence that is merely late"
  end

  # THE SET IS EXACTLY WHAT THE PRODUCERS EMIT — the same both-directions assertion
  # gate_record_no_verdict_ci_test makes for its family. Set equality alone would let a
  # value be declared in-flight that nothing can produce, or produced without being
  # declared; either drift paints a row wrong.
  test "[unit] every declared in-flight value is one a producer actually writes" do
    assert_equal %w[running pending].sort, GateRun::IN_FLIGHT_RESULTS.sort
    assert_equal GateRun::PENDING_RESULT,
                 CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false),
                 "CiGate is the producer of the pending row"
  end

  # THE 1:1 PIN THE NO-VERDICT SUITE LEFT OPEN. Its "[unit] the producer's no-verdict
  # values equal the ones the card paints" pins UNREADABLE / NO_CHECKS / UNVERIFIED
  # individually but stops short of NO_PR — noted as a non-blocker on #1320, folded in
  # here because this task is where the pairing rule is being written down. Set equality
  # already catches a drifted PAIR; it does NOT catch both halves being renamed together
  # to a word the card has no arm for, which is exactly the failure this family keeps
  # having.
  test "[unit] the no_pr producer and model values are pinned 1:1" do
    assert_equal GateRun::NO_PR_RESULT, CiGate::GATE_ROW_NO_PR
  end
end
