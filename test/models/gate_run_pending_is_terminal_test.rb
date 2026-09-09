require "test_helper"

# Unit — /tasks/pending-ci-paints-check introduced GateRun::IN_FLIGHT_RESULTS, and this
# file exists to stop that set from being used where it does not belong.
#
# THE HAZARD THE SET CREATES. `IN_FLIGHT_RESULTS` sits directly beside `RUNNING_RESULT`
# and reads like a superset of it, but `append_sop!` and `supersede_running` read
# RUNNING_RESULT for a property `pending` DOES NOT SHARE:
#
#   * a `running` row is a BEAT — it may not open an attempt and may not land on a
#     closed one, because a straggler beat arriving after `close!` used to mint a
#     PHANTOM ATTEMPT the board then showed as live forever;
#   * a `running` row is COLLAPSED by the next row for its lane, so a seven-minute
#     lane leaves one row rather than nine.
#
# `pending` is neither. It is a one-shot terminal row the CI gate writes once per
# bin/dor-check run — it must open an attempt like any verdict, and consecutive ones are
# real history that must both survive. Widening either call site to the new set would
# trade a glyph fix for a history bug, and both halves would be silent.
#
# These tests are the tripwire. They assert BEHAVIOUR, not the constant's spelling, so
# they bite on the refactor rather than on a rename.
class GateRunPendingIsTerminalTest < ActiveSupport::TestCase
  def append(result, sop: "ci", slug: "t-pending", at: Time.current, key: "dor")
    GateRun.append_sop!(subject_type: "task", subject_slug: slug, key: key,
                        sop: { "sop" => sop, "cmd" => "bin/dor-check", "result" => result,
                               "at" => at.iso8601 })
  end

  def attempts(slug: "t-pending", key: "dor")
    GateRun.for_subject("task", slug).where(key: key)
  end

  # A PENDING ROW OPENS AN ATTEMPT. This is the ordinary submit-side path: bin/dor-check
  # runs against a freshly pushed PR whose checks have not settled, with no gate opened
  # ahead of it. If `pending` were treated as a beat this would return nil and the row
  # would vanish — the gate history would simply lose the fleet's most common CI row.
  test "[unit] a pending row opens an attempt, unlike a running beat" do
    run = append(GateRun::PENDING_RESULT)

    assert run, "pending must mint an attempt — it is a verdict-shaped row, not a heartbeat"
    assert_equal 1, attempts.count
    assert_equal [GateRun::PENDING_RESULT], run.sops.map { |s| s["result"] }
  end

  # THE CONTROL that gives the test above its meaning. If `running` also opened an
  # attempt, the assertion above would pass for the wrong reason and the tripwire would
  # be dead. This is the straggler rule the phantom-attempt fix installed.
  test "[unit] a running beat with nothing in flight still lands nowhere" do
    assert_nil append(GateRun::RUNNING_RESULT, slug: "t-beat"),
               "a beat may not open an attempt — that is the phantom-attempt rule"
    assert_equal 0, attempts(slug: "t-beat").count
  end

  # CONSECUTIVE PENDING ROWS ARE HISTORY AND BOTH SURVIVE. `supersede_running` drops a
  # prior row only when that row is `running`. Two dor-check runs against a CI that is
  # still unsettled are two real observations; collapsing them would hide that the gate
  # was asked twice and got the same non-answer.
  test "[unit] two pending rows for one lane both survive" do
    append(GateRun::PENDING_RESULT, at: 5.minutes.ago)
    run = append(GateRun::PENDING_RESULT, at: Time.current)

    assert_equal [GateRun::PENDING_RESULT, GateRun::PENDING_RESULT],
                 run.sops.map { |s| s["result"] },
                 "pending is not collapsible — widening supersede_running to IN_FLIGHT_RESULTS " \
                 "would silently eat one of these"
  end

  # THE CONTROL for collapsing: `running` DOES collapse, so the assertion above is
  # testing a real difference between the two members of IN_FLIGHT_RESULTS rather than a
  # property neither has.
  test "[unit] two running rows for one lane collapse to one" do
    GateRun.open!(subject_type: "task", subject_slug: "t-collapse", key: "dor")
    append(GateRun::RUNNING_RESULT, slug: "t-collapse", at: 5.minutes.ago)
    run = append(GateRun::RUNNING_RESULT, slug: "t-collapse", at: Time.current)

    assert_equal 1, run.sops.count { |s| s["result"] == GateRun::RUNNING_RESULT },
                 "beats collapse — this is the property pending must NOT inherit"
  end

  # A PENDING ROW IS SUPERSEDED BY NOTHING AND SUPERSEDES NOTHING, so a later real
  # verdict for the same lane stacks on top of it rather than replacing it. That is the
  # audit trail the gates card renders: asked, unsettled, then settled.
  test "[unit] a later verdict does not erase the pending row that preceded it" do
    append(GateRun::PENDING_RESULT, at: 5.minutes.ago)
    run = append("pass", at: Time.current)

    assert_equal [GateRun::PENDING_RESULT, "pass"], run.sops.map { |s| s["result"] },
                 "the record must show the gate was asked before CI settled"
  end

  # AND THE SET ITSELF IS RENDER-ONLY. Stated once, as a fact about membership, so a
  # reader who finds IN_FLIGHT_RESULTS first learns what it is for before reaching for
  # it: both members share a GLYPH, and nothing else.
  test "[unit] IN_FLIGHT_RESULTS holds exactly the two values the card paints in-flight" do
    assert_equal [GateRun::RUNNING_RESULT, GateRun::PENDING_RESULT].sort,
                 GateRun::IN_FLIGHT_RESULTS.sort
    refute_equal GateRun::RUNNING_RESULT, GateRun::PENDING_RESULT,
                 "they share a glyph, not an identity — the heartbeat rules key off RUNNING_RESULT alone"
  end
end
