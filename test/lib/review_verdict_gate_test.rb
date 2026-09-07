# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/review_verdict_gate"
require_relative "../../bin/lib/bounce_ledger"

# The verdict-owner decision table, exercised as DATA. The integration siblings in
# test/commands/block_verdict_owner_gate_test.rb drive the real binary against a stub
# board and prove the refusal writes nothing; this file pins the rules themselves, where
# every branch is reachable without HTTP.
class ReviewVerdictGateTest < Minitest::Test
  OWNER_SOUL = "carl"
  LIGHT_SOUL = "alex"

  def live(agent: OWNER_SOUL)
    { "task_slug" => "t", "session" => "s", "agent" => agent, "live" => true }
  end

  # ── THE DEFECT ──────────────────────────────────────────────────────────────

  def test_unit_a_different_soul_under_a_live_review_is_foreign
    verdict = ReviewVerdictGate.verdict(kind: "rework", holder: live, actor: LIGHT_SOUL)

    assert_equal ReviewVerdictGate::FOREIGN, verdict
    refute ReviewVerdictGate.allowed?(verdict),
           "a light spending the primary's bounce is the whole incident; it must not be allowed"
  end

  def test_unit_the_recorded_owner_is_allowed
    verdict = ReviewVerdictGate.verdict(kind: "rework", holder: live, actor: OWNER_SOUL)

    assert_equal ReviewVerdictGate::OWNER, verdict
    assert ReviewVerdictGate.allowed?(verdict),
           "refusing the verdict's own owner would wedge every legitimate send-back"
  end

  # Slugs are lowercase-with-hyphens by contract, so case and surrounding space are
  # noise. Folding them keeps a refusal from resting on a stray capital.
  def test_unit_soul_comparison_ignores_case_and_surrounding_space
    assert_equal ReviewVerdictGate::OWNER,
                 ReviewVerdictGate.verdict(kind: "rework", holder: live(agent: "Carl"),
                                           actor: "  carl ")
  end

  # …and folds NOTHING else. `turf_monster` is a DIFFERENT string that the fast lane
  # already refuses rather than a spelling of `turf-monster`; treating them as equal
  # here would quietly authorise a soul the rest of the stack says does not exist.
  def test_unit_soul_comparison_does_not_fold_separators
    assert_equal ReviewVerdictGate::FOREIGN,
                 ReviewVerdictGate.verdict(kind: "rework", holder: live(agent: "turf-monster"),
                                           actor: "turf_monster")
  end

  # ── THE TRI-STATE. Collapsing any two of these is the fail-open. ─────────────

  def test_unit_a_board_that_did_not_answer_is_unreadable_not_absence
    verdict = ReviewVerdictGate.verdict(kind: "rework", holder: {}, actor: LIGHT_SOUL)

    assert_equal ReviewVerdictGate::UNREADABLE, verdict,
                 "an empty hash carries NO `live` key — it is 'we got no answer', and reading " \
                 "it as 'nobody is reviewing' hands the bounce to anyone who asks during an outage"
    refute ReviewVerdictGate.allowed?(verdict)
  end

  def test_unit_a_nil_holder_is_unreadable
    assert_equal ReviewVerdictGate::UNREADABLE,
                 ReviewVerdictGate.verdict(kind: "rework", holder: nil, actor: LIGHT_SOUL)
  end

  def test_unit_the_board_saying_nobody_reviews_is_not_gated
    verdict = ReviewVerdictGate.verdict(kind: "rework", holder: { "live" => false },
                                        actor: LIGHT_SOUL)

    assert_equal ReviewVerdictGate::NO_REVIEW, verdict,
                 "`live => false` is a POSITIVE answer: no review is in flight, so there is no " \
                 "verdict owner to usurp and an ordinary block must proceed"
    assert ReviewVerdictGate.allowed?(verdict)
  end

  def test_unit_a_live_review_naming_no_soul_is_unattributed
    [nil, "", "   "].each do |blank|
      verdict = ReviewVerdictGate.verdict(kind: "rework", holder: live(agent: blank),
                                          actor: LIGHT_SOUL)

      assert_equal ReviewVerdictGate::UNATTRIBUTED, verdict,
                   "a claim naming no reviewer cannot authorise anyone, including #{blank.inspect}"
      refute ReviewVerdictGate.allowed?(verdict)
    end
  end

  # A caller whose own soul did not resolve cannot be shown to own anything either.
  def test_unit_a_blank_actor_under_a_live_review_is_foreign
    verdict = ReviewVerdictGate.verdict(kind: "rework", holder: live, actor: "")

    refute ReviewVerdictGate.allowed?(verdict),
           "an unidentified caller must not inherit the owner's budget"
  end

  # ── SCOPE ───────────────────────────────────────────────────────────────────

  def test_unit_only_bounce_spending_kinds_are_gated
    %w[dependency environment].each do |kind|
      assert_equal ReviewVerdictGate::NOT_GATED,
                   ReviewVerdictGate.verdict(kind: kind, holder: live, actor: LIGHT_SOUL),
                   "--kind #{kind} spends no bounce; gating it would take the ESCALATION away " \
                   "from the agent most likely to need it"
    end
  end

  # THE DRIFT GUARD, DERIVED FROM BOTH REAL SOURCES rather than restated. The gate must
  # cover exactly those block kinds a caller can REQUEST that the breaker would COUNT.
  # Add a countable kind to BounceLedger, or a new spelling to bin/task's BLOCK_KINDS,
  # and this reddens until the gate is widened to match — which is the failure mode
  # this pairing exists to catch, because a countable kind outside the gate is a fresh
  # way to spend somebody else's bounce.
  #
  # `unknown` is deliberately not in the intersection: it is how a LEGACY row with no
  # stamped kind grades on the read side, never something `--kind` accepts.
  def test_unit_the_gated_kinds_are_exactly_the_requestable_countable_kinds
    requestable = block_kinds_from_bin_task
    countable = BounceLedger::COUNTABLE_KINDS

    assert_includes requestable, "rework", "fixture check: bin/task must still accept --kind rework"

    assert_equal (requestable & countable).sort, ReviewVerdictGate::GATED_KINDS.sort,
                 "every block kind a caller can request that the breaker COUNTS must be gated; " \
                 "requestable=#{requestable.inspect} countable=#{countable.inspect}"
  end

  # ── THE REFUSAL CARRIES WHAT THE READER ACTS ON ─────────────────────────────

  def test_unit_the_foreign_refusal_names_both_souls_and_the_scout_seam
    text = ReviewVerdictGate.refusal(ReviewVerdictGate::FOREIGN, slug: "some-task",
                                     actor: LIGHT_SOUL, holder: live).join("\n")

    assert_includes text, OWNER_SOUL, "it must name who DOES own the verdict"
    assert_includes text, LIGHT_SOUL, "and who was refused"
    assert_match(/scout report/i, text, "and the light's legitimate path")
    assert_includes text, "bin/task note some-task",
                     "with a pasteable way to record the finding without spending the bounce"
  end

  # Every refused verdict must produce a refusal that names the task. A branch that
  # returned bare lines would leave a reader with no handle to act on.
  def test_unit_every_refusing_verdict_renders_a_refusal_naming_the_task
    refusing = [ReviewVerdictGate::FOREIGN, ReviewVerdictGate::UNATTRIBUTED,
                ReviewVerdictGate::UNREADABLE]

    refusing.each do |verdict|
      text = ReviewVerdictGate.refusal(verdict, slug: "some-task", actor: LIGHT_SOUL,
                                       holder: live).join("\n")

      assert_includes text, "some-task", "#{verdict} must name the task it refused"
      refute_empty text.strip, "#{verdict} must say something"
    end
  end

  # The allowlist is POSITIVE: a verdict added later must be admitted on purpose.
  def test_unit_allowed_is_a_positive_allowlist
    refute ReviewVerdictGate.allowed?(:some_verdict_added_next_year),
           "an unrecognised verdict must NOT fall through to permission"
  end

  private

  # bin/task is a script, not a requirable library, so its constant is read out of the
  # source — the same technique test/commands/task_claim_gate_test.rb uses to derive a
  # fact from the real file instead of restating it here.
  def block_kinds_from_bin_task
    source = File.read(File.expand_path("../../bin/task", __dir__))
    list = source[/^BLOCK_KINDS = %w\[([^\]]+)\]/, 1] ||
           flunk("could not find BLOCK_KINDS in bin/task — this guard reads it from the real source")
    list.split
  end
end
