# The grading layer over the learning heartbeat — Alex's feedback record.
#
# A grade targets EXACTLY ONE of two things (an additive dual-FK, not a
# polymorphic rewrite): a raw agent action OR a narrated agent activity. The model
# enforces the XOR; each FK is independently unique per grader.
#
# Either target can carry up to TWO ActionGrade rows, distinguished by the
# `grader` column:
#
#   grader = "alex"  — Alex's grade of the action/activity itself.
#   grader = "mcr"   — Mr. McRitchie's audit OF Alex's grade for that target
#                      (the recursive audit: McRitchie grades Alex's grading).
#
# The (agent_action_id, grader) and (agent_activity_id, grader) pairs are each
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
# not best-effort telemetry like AgentAction.capture. The calling controller/job
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
  belongs_to :agent_action, optional: true, inverse_of: :action_grades
  belongs_to :agent_activity,  optional: true, inverse_of: :action_grades
  belongs_to :atomic_action, class_name: "AgentAction", foreign_key: :agent_action_id,
                             optional: true
  belongs_to :atomic_event, class_name: "AgentActivity", foreign_key: :agent_activity_id,
                            optional: true
  alias_attribute :atomic_action_id, :agent_action_id
  alias_attribute :atomic_event_id, :agent_activity_id

  # Provenance for a machine-seeded CANDIDATE (see Insights::BlockMiner): the
  # qa_feedback Activity (the QA block) this grade was mined from. Slug FK (the
  # ecosystem convention). Present ONLY on mined candidates — a hand-authored grade
  # leaves it nil, which is what #seeded_candidate? keys off.
  belongs_to :source_activity, class_name: "Activity", foreign_key: :source_activity_slug,
                               primary_key: :slug, optional: true, inverse_of: :seeded_grades

  validates :grader, inclusion: { in: GRADERS }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validates :slug, presence: true
  # Exactly one target — a grade is of an action OR an activity, never both, never
  # neither (replaces the old agent_action presence guarantee).
  validate :exactly_one_target
  # One Alex grade + one McRitchie audit PER TARGET — never two of either. The
  # uniqueness is scoped per FK and only fires for the FK that is actually set,
  # so an action grade and an activity grade by the same grader never collide.
  validates :grader, uniqueness: { scope: :agent_action_id }, if: -> { agent_action_id.present? }
  validates :grader, uniqueness: { scope: :agent_activity_id },  if: -> { agent_activity_id.present? }

  scope :by_grader,  ->(grader) { where(grader: grader) }
  scope :banked,     -> { where(banked: true) }            # the Insight Bank
  scope :discarded,  -> { where(discarded: true) }
  scope :for_action, ->(action) { where(agent_action_id: action) }
  scope :for_activity, ->(activity) { where(agent_activity_id: activity) }
  scope :for_event, ->(event) { for_activity(event) }
  # Machine-seeded candidates mined from resolved QA blocks (Insights::BlockMiner).
  scope :seeded_candidates, -> { where.not(source_activity_slug: nil) }
  # Candidates still AWAITING grade — seeded but not yet banked into the Insight
  # Bank nor set aside. The read the pipeline surfaces (heartbeat#pipeline): the
  # queue of block-mined lessons for the operator/Alex to promote or discard.
  scope :pending_candidates, -> { seeded_candidates.where(banked: false, discarded: false) }

  # The learning loop's OUTPUT — the curated lessons a FRESH session carries in.
  # Today `banked` is read by one HTML page; .insight_feed is the feed-forward
  # read path (GET /api/v1/insights → the SessionStart hook), so a new agent
  # hatches already knowing what past sessions learned. Newest curation first,
  # capped (clamped 1..MAX_FEED_LIMIT). Eager-loads both possible sources so
  # #to_insight reads provenance with no N+1. (Relevance-by-app/shape ranking is a
  # documented follow-up; v1 is the most recently curated set.)
  def self.insight_feed(limit: DEFAULT_FEED_LIMIT)
    capped = limit.to_i.clamp(1, MAX_FEED_LIMIT)
    banked.includes(:agent_action, :agent_activity).order(updated_at: :desc).limit(capped)
  end

  # Upsert the ONE grade for (activity, grader) — the shared write behind BOTH the
  # admin browser drawer and the bearer agent path (bin/agent-activity grade). It
  # matches the drawer's semantics: disposition defaults to GOOD, slug defaults to
  # the activity's reason, `long_form` only writes when GIVEN (pass :unset to leave it),
  # and an `intent` of "bank"/"discard" routes through bank!/discard!. Raises on an
  # invalid write (a grade is a deliberate act, not best-effort telemetry).
  #
  # `grader` is the CALLER's responsibility to constrain — the agent path passes
  # ALEX and NEVER MCR, so McRitchie's audit-of-Alex lane stays admin-only.
  def self.record_activity_grade(activity:, grader:, disposition: nil, slug: nil, long_form: :unset, intent: nil)
    grade = for_activity(activity).by_grader(grader).first_or_initialize(grader: grader)
    grade.disposition = disposition.presence || grade.disposition.presence || GOOD
    grade.slug        = slug.presence || grade.slug.presence || activity.reason_slug
    grade.long_form   = long_form unless long_form == :unset
    grade.save!

    case intent.to_s
    when "bank"    then grade.bank!
    when "discard" then grade.discard!
    end
    grade
  end

  def self.record_event_grade(event:, **kwargs)
    record_activity_grade(activity: event, **kwargs)
  end

  # The JSON shape returned to an agent after a grade write — the recorded grade,
  # so the CLI can echo what landed (banked/discarded reflect the intent applied).
  def to_grade_json
    { "id" => id, "grader" => grader, "disposition" => disposition, "slug" => slug,
      "long_form" => long_form, "banked" => banked, "discarded" => discarded,
      "agent_activity_id" => agent_activity_id }.compact
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

  # True when this grade targets a narrated activity rather than a raw action.
  def activity_grade?
    agent_activity_id.present?
  end

  alias_method :event_grade?, :activity_grade?

  # True when this grade was MACHINE-SEEDED from a resolved QA block
  # (Insights::BlockMiner) rather than authored by a grader — carries the
  # provenance FK back to the qa_feedback Activity. Lets a reader treat a mined
  # candidate distinctly (e.g. the pipeline's "awaiting grade" band).
  def seeded_candidate?
    source_activity_slug.present?
  end

  # The record this banked lesson was mined from — its action OR its activity (the XOR
  # target), or nil when that source was later removed (has_many :nullify), so a
  # banked insight can outlive what it graded. The Insight Bank reads provenance
  # through this instead of dereferencing agent_action unconditionally (which 500'd
  # the whole bank the moment an activity grade was banked).
  def insight_source
    agent_action || agent_activity
  end

  # A short human label for the insight's source: an activity reads by its narration
  # category, a raw action by its event slug (falling back to its tool kind). nil
  # when the source is unknown/removed.
  def insight_label
    source = insight_source
    return nil unless source

    activity_grade? ? source.category : (source.event_slug.presence || source.kind)
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
      "task_slug"   => (agent_action&.task_slug || agent_activity&.task_slug)
    }.compact
  end

  private

  # XOR: a grade must target EXACTLY ONE of an action or an activity. Zero targets
  # (the old "agent_action must exist") and two targets are both invalid.
  def exactly_one_target
    targets = [agent_action_id, agent_activity_id].count(&:present?)
    return if targets == 1

    errors.add(:base, "must grade exactly one of an action or an activity")
  end
end
