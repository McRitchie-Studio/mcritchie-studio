# The grading layer over the learning heartbeat — Alex's feedback record.
#
# A grade targets EXACTLY ONE of two things (an additive dual-FK, not a
# polymorphic rewrite): a raw `atomic_action` (the original per-tool-call path)
# OR a narrated `atomic_event` SPAN (the agent-declared trajectory). The model
# enforces the XOR; each FK is independently unique per grader.
#
# Either target can carry up to TWO ActionGrade rows, distinguished by the
# `grader` column:
#
#   grader = "alex"  — Alex's grade of the action/span itself.
#   grader = "mcr"   — Mr. McRitchie's audit OF Alex's grade for that target
#                      (the recursive audit: McRitchie grades Alex's grading).
#
# The (atomic_action_id, grader) and (atomic_event_id, grader) pairs are each
# unique, so a target holds at most one Alex grade and one McRitchie audit —
# never two of either.
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

  # Feed-forward: how many banked insights a fresh session loads by default, and
  # the hard cap. A session's context budget is finite, so the feed NEVER floods
  # it — .insight_feed clamps to 1..MAX_FEED_LIMIT.
  DEFAULT_FEED_LIMIT = 12
  MAX_FEED_LIMIT     = 50

  # Dual, mutually exclusive targets — both optional at the association level so a
  # grade can hang off EITHER one. The XOR below guarantees exactly one is set.
  belongs_to :atomic_action, optional: true, inverse_of: :action_grades
  belongs_to :atomic_event,  optional: true, inverse_of: :action_grades

  validates :grader, inclusion: { in: GRADERS }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validates :slug, presence: true
  # Exactly one target — a grade is of an action OR a span, never both, never
  # neither (replaces the old atomic_action presence guarantee).
  validate :exactly_one_target
  # One Alex grade + one McRitchie audit PER TARGET — never two of either. The
  # uniqueness is scoped per FK and only fires for the FK that is actually set,
  # so an action grade and a span grade by the same grader never collide.
  validates :grader, uniqueness: { scope: :atomic_action_id }, if: -> { atomic_action_id.present? }
  validates :grader, uniqueness: { scope: :atomic_event_id },  if: -> { atomic_event_id.present? }

  scope :by_grader,  ->(grader) { where(grader: grader) }
  scope :banked,     -> { where(banked: true) }            # the Insight Bank
  scope :discarded,  -> { where(discarded: true) }
  scope :for_action, ->(action) { where(atomic_action_id: action) }
  scope :for_event,  ->(event) { where(atomic_event_id: event) }

  # The learning loop's OUTPUT — the curated lessons a FRESH session carries in.
  # Today `banked` is read by one HTML page; .insight_feed is the feed-forward
  # read path (GET /api/v1/insights → the SessionStart hook), so a new agent
  # hatches already knowing what past sessions learned. Newest curation first,
  # capped (clamped 1..MAX_FEED_LIMIT). Eager-loads both possible sources so
  # #to_insight reads provenance with no N+1. (Relevance-by-app/shape ranking is a
  # documented follow-up; v1 is the most recently curated set.)
  def self.insight_feed(limit: DEFAULT_FEED_LIMIT)
    capped = limit.to_i.clamp(1, MAX_FEED_LIMIT)
    banked.includes(:atomic_action, :atomic_event).order(updated_at: :desc).limit(capped)
  end

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

  # True when this grade targets a narrated span rather than a raw action.
  def event_grade?
    atomic_event_id.present?
  end

  # The record this banked lesson was mined from — its action OR its span (the XOR
  # target), or nil when that source was later removed (has_many :nullify), so a
  # banked insight can outlive what it graded. The Insight Bank reads provenance
  # through this instead of dereferencing atomic_action unconditionally (which 500'd
  # the whole bank the moment a SPAN grade was banked).
  def insight_source
    atomic_action || atomic_event
  end

  # A short human label for the insight's source: a span reads by its narration
  # category, a raw action by its event slug (falling back to its tool kind). nil
  # when the source is unknown/removed.
  def insight_label
    source = insight_source
    return nil unless source

    event_grade? ? source.category : (source.event_slug.presence || source.kind)
  end

  # The feed-forward shape of one banked insight: the lesson (`slug` + optional
  # `long_form`), its GOOD-do-this / NOT-avoid-this signal, who curated it, and the
  # task it was mined from. Provenance is read INLINE from whichever source is set
  # (kept independent of any richer provenance helper so this doesn't couple to
  # other in-flight work). No raw trajectory body — a fresh session wants the
  # LESSON, not the tool calls. nil fields are dropped.
  def to_insight
    {
      "slug"        => slug,
      "disposition" => disposition,
      "long_form"   => long_form.presence,
      "grader"      => grader,
      "task_slug"   => (atomic_action&.task_slug || atomic_event&.task_slug)
    }.compact
  end

  private

  # XOR: a grade must target EXACTLY ONE of an action or a span. Zero targets
  # (the old "atomic_action must exist") and two targets are both invalid.
  def exactly_one_target
    targets = [atomic_action_id, atomic_event_id].count(&:present?)
    return if targets == 1

    errors.add(:base, "must grade exactly one of an action or an event")
  end
end
