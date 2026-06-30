# The grading layer over AtomicAction — the learning heartbeat's feedback record.
#
# Every graded action can carry up to TWO ActionGrade rows, distinguished by the
# `grader` column:
#
#   grader = "alex"  — Alex's grade of the action itself.
#   grader = "mcr"   — Mr. McRitchie's audit OF Alex's grade for that action
#                      (the recursive audit: McRitchie grades Alex's grading).
#
# The (atomic_action_id, grader) pair is unique, so an action holds at most one
# Alex grade and one McRitchie audit — never two of either.
#
# Each grade is a 4–7 word feedback `slug` plus a BINARY `disposition`
# (good | not) and an optional `long_form` anchor. Two flags decide its fate:
# `banked` (curated into the Insight Bank) and `discarded` (set aside). They are
# mutually exclusive — #bank! clears discard and #discard! clears bank.
#
# The Insight Bank is exactly `ActionGrade.banked`: the curated set of lessons
# that make each next agent smarter. Mirrors the prototype's a/m feedback objects
# (sl=slug, d=disposition, lg=long-form, banked, discarded).
#
# Writes here RAISE on failure by design — a grade is a deliberate user action,
# not best-effort telemetry like AtomicAction.capture. The calling controller/job
# (the heartbeat UI wiring, T4) is responsible for wrapping these in rescue_and_log
# with target/parent context, per backend discipline.
class ActionGrade < ApplicationRecord
  # Who graded — TWO rows per action: Alex's grade, and the McRitchie audit of it.
  ALEX    = "alex"
  MCR     = "mcr"
  GRADERS = [ALEX, MCR].freeze

  # Binary disposition — the credit signal. No "pending" here: a row only exists
  # once a grader has committed to a verdict (the UI's pending state is the
  # ABSENCE of a row, not a stored value).
  GOOD         = "good"
  NOT          = "not"
  DISPOSITIONS = [GOOD, NOT].freeze

  belongs_to :atomic_action, inverse_of: :action_grades

  validates :grader, inclusion: { in: GRADERS }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validates :slug, presence: true
  # One Alex grade + one McRitchie audit per action — never two of either.
  validates :grader, uniqueness: { scope: :atomic_action_id }

  scope :by_grader,  ->(grader) { where(grader: grader) }
  scope :banked,     -> { where(banked: true) }            # the Insight Bank
  scope :discarded,  -> { where(discarded: true) }
  scope :for_action, ->(action) { where(atomic_action_id: action) }

  # Curate this grade into the Insight Bank. Banking and discarding are mutually
  # exclusive, so banking clears any prior discard. Raises on failure.
  def bank!
    update!(banked: true, discarded: false)
  end

  # Set this grade aside — out of the Insight Bank. Clears any prior bank. Raises
  # on failure.
  def discard!
    update!(discarded: true, banked: false)
  end

  def alex?
    grader == ALEX
  end

  def mcr?
    grader == MCR
  end

  def good?
    disposition == GOOD
  end

  # `not?` would read oddly and shadow nothing useful; the disposition value is
  # the string "not", so this predicate names the negative case explicitly.
  def not_good?
    disposition == NOT
  end
end
