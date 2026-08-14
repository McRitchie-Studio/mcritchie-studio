# frozen_string_literal: true

# [unit] The two-bounce circuit breaker's wiring inside bin/pr-review — the
# AUTOMATED review path's block seam.
#
# WHY A SOURCE-STRUCTURAL TEST HERE, when the breaker itself is behaviorally tested
# next door (test/lib/bounce_ledger_test.rb, test/lib/bounce_check_cli_test.rb).
# The behavior is already pinned where it lives: `bin/task block --kind rework`
# REFUSES a tripped second bounce, so no unacknowledged repeat bounce can land
# whatever this script does. What CANNOT be pinned by driving the script is its
# ROUTING — block_for_rework's callers launch real reviewer subprocesses and talk
# to GitHub, so the supervisor's decision table is only reachable from the source.
# Same reasoning, and same house pattern, as pr_review_zap_safety_test.rb.
#
# What it asserts is a PROPERTY over every rework block in the file, not the
# presence of a string: each one is either breaker-GUARDED or breaker-ACKNOWLEDGED.
# Add a fifth rework block tomorrow and this goes red until you classify it — which
# is the whole point, because an unclassified one silently re-arms the loop.
#
#   ruby -Itest test/lib/pr_review_breaker_test.rb

require "minitest/autorun"

class PrReviewBreakerTest < Minitest::Test
  SRC = File.read(File.expand_path("../../bin/pr-review", __dir__))

  # Every `task_write([... "block" ... "--kind", "rework" ...])` argv in the file,
  # as its own source slice.
  def rework_block_argvs
    SRC.scan(/task_write\(\[(?:[^\[\]]|\n)*?"--kind",\s*"rework"(?:[^\[\]]|\n)*?\]\)/)
  end

  def test_the_file_still_blocks_for_rework_somewhere
    refute_empty rework_block_argvs,
                 "no rework block found — if the shape changed, this whole file needs re-reading, not deleting"
  end

  # THE PROPERTY. A rework bounce from the supervisor is one of exactly two things,
  # and it must SAY which:
  #   MECHANICAL (red CI, merge conflict, stale base) — nothing for the operator to
  #     arbitrate, so it carries --breaker-ack and proceeds.
  #   A JUDGEMENT (request-changes) — a repeat one is a review DEADLOCK, so it is
  #     routed through breaker_tripped? and escalates instead.
  # A third, unclassified kind is the bug: it would either be refused (recorded as a
  # tool failure, and the builder never told) or, if the gate were ever loosened,
  # bounce forever.
  def test_every_rework_block_is_either_acknowledged_or_breaker_guarded
    guarded_body = SRC[/def block_for_rework\b.*?\nend\n/m]
    refute_nil guarded_body, "block_for_rework not found — the judgement path must exist"
    assert_includes guarded_body, "breaker_tripped?",
                    "the JUDGEMENT bounce must consult the breaker before sending the builder back again"

    rework_block_argvs.each do |argv|
      next if guarded_body.include?(argv)

      assert_includes argv, "--breaker-ack",
                      "an unguarded rework block must declare itself MECHANICAL with --breaker-ack, " \
                      "or route through breaker_tripped?. Unclassified: #{argv.gsub(/\s+/, " ")}"
    end
  end

  # A tripped judgement bounce ESCALATES rather than bouncing again — and escalation
  # means a `dependency` block, which is what parks the deadlock for the operator.
  def test_a_tripped_judgement_bounce_escalates_as_a_dependency_block
    body = SRC[/def block_for_rework\b.*?\nend\n/m]

    assert_includes body, '"--kind", "dependency"',
                    "a repeat bounce is the operator's call — escalate, never re-block the builder"
    assert_match(/"--summary",\s*"Escalated:/, body,
                 "the escalation must be recognizable as one from the task header alone " \
                 "(address-blocker.md routes on the leading `Escalated:`)")
  end

  # The read must only DIVERT on an affirmative TRIPPED. An unreadable ledger
  # turning every rework into an operator escalation would be the opposite failure:
  # noise instead of silence, but still a broken verdict.
  def test_the_breaker_read_diverts_only_on_an_affirmative_tripped
    body = SRC[/def breaker_tripped\?.*?\nend\n/m]
    refute_nil body, "breaker_tripped? not found in bin/pr-review"

    assert_match(/exitstatus == 10/, body,
                 "only exit 10 (TRIPPED) may divert; a failed read must not manufacture an escalation")
    assert_includes body, "OPTIONS.fetch(:run)",
                    "a dry run must not shell out to the board"
  end

  # The three MECHANICAL acknowledgments must name a mechanical cause. A reason like
  # "override" or "" would satisfy the flag and defeat the record it exists to leave.
  def test_the_mechanical_acknowledgments_name_a_mechanical_cause
    acks = SRC.scan(/"--breaker-ack",\s*"([^"]*)"/).flatten

    assert_equal 3, acks.size, "expected exactly the three CI gate-zero acknowledgments, got #{acks.inspect}"
    acks.each do |ack|
      assert_match(/mechanical/i, ack, "an acknowledgment must name WHY it is mechanical, not merely assert itself")
    end
  end
end
