# An agent-narrated trajectory EVENT — a meaningful span the agent self-declares
# as it works. Where an AtomicAction is one raw tool call (best-effort, captured
# by the PostToolUse hook), an AtomicEvent is the SPAN the agent opens and closes
# around a chunk of work:
#
#   Explore · "find issue with api"   →   (raw reads/greps attribute here)   →
#     close · "located the nil-guard in AtomicAction.capture"
#
# The agent NARRATES its own trajectory — there is no per-call classifier and no
# reader sub-agent. It declares the span (category + reason), the raw tool-calls
# attribute server-side to whatever span is currently OPEN, and the agent closes
# the span with an outcome. A simple task that used to log ~100 noisy rows
# collapses to a handful of narrated spans.
#
# INVARIANT: at most one OPEN span per (session, AGENT) at a time — a per-agent
# LANE. Opening a new span auto-closes the prior open one FOR THAT AGENT (see
# .open_event!). This is what lets the documented reviewer fan-out work: a
# PRIMARY and its nested LIGHT both narrate `--agent <soul>` in the SAME parent
# session (subagents inherit the session id), and each soul's start/end operates
# on its OWN lane instead of silently closing the other's in-flight span and
# dropping its verdict. The orchestrator's un-agented spans are the nil lane.
#
# (Raw AtomicAction attribution stays best-effort last-open-span within the
# session — an action carries no agent, and a subagent's PostToolUse hook posts
# under the parent session id, so per-agent ACTION attribution is a harness-level
# limit this does not claim to fix. The span/verdict integrity — the graded
# signal — is what the per-agent lane protects.)
class AtomicEvent < ApplicationRecord
  # The agent-declared span vocabulary — a fixed, small set so spans stay
  # comparable across sessions. The agent picks ONE per span.
  CATEGORIES = %w[
    Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan
  ].freeze

  # The McRitchie soul roster — the ONE acting agent a span may be attributed to
  # (via `bin/atomic-event --agent <soul>`), distinct from the base session
  # `mascot`. A nil `agent` means "the base session mascot did it" (no soul
  # override); the heartbeat can later STACK the acting soul over the stable base
  # mascot. An unknown slug is coerced to nil by #normalize_agent — non-fatal, so
  # a typo'd soul never fails a narration.
  SOULS = %w[avi carl shannon jasper steffon alex].freeze

  # Slug FK to tasks (the ecosystem convention). Optional: PRE-task spans (boot,
  # intake) carry a null task_slug and must never fail a task lookup.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug,
                    optional: true, inverse_of: :atomic_events

  # The raw tool-calls that attributed to this span. Nullify (not destroy) so
  # closing/removing a span never destroys the actions it framed.
  has_many :atomic_actions, dependent: :nullify, inverse_of: :atomic_event

  # The grades targeting this span — Alex's grade and the McRitchie audit-of-Alex
  # are two ActionGrade rows (distinguished by grader), the span-level mirror of
  # AtomicAction#action_grades. Nullify (not destroy), matching the FK's
  # on_delete: :nullify — removing a span orphans its grades rather than deleting
  # the recorded feedback.
  has_many :action_grades, dependent: :nullify, inverse_of: :atomic_event

  validates :session_id, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :reason_slug, presence: true
  validates :opened_at, presence: true
  validates :seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Coerce the acting soul to a known roster slug (down-cased), else nil. This is
  # deliberately NON-FATAL — an unknown/typo'd `agent` becomes nil rather than an
  # invalid record, so a bad --agent value never sinks a best-effort narration.
  before_validation :normalize_agent

  scope :for_session,  ->(session_id) { where(session_id: session_id) }
  scope :open,         -> { where(closed_at: nil) }
  scope :closed,       -> { where.not(closed_at: nil) }
  scope :chronological, -> { order(opened_at: :asc, seq: :asc, id: :asc) }

  # Default batch size for the Alex heartbeat grade-events loop (the SOP's "10 most
  # recent resolved spans"), and the hard cap.
  DEFAULT_GRADE_BATCH = 10
  MAX_GRADE_BATCH     = 100

  # The RESOLVED (closed) spans that carry NO grade by `grader` yet — the "spans
  # awaiting grade" the Alex heartbeat works through, newest-resolved first, capped.
  # This is the READ half of the first-class agent grading flow (the WRITE is
  # ActionGrade.record_event_grade); together they let grade-events run as a bearer
  # CLI SOP instead of scraping the HTML page.
  def self.awaiting_grade(grader: ActionGrade::ALEX, limit: DEFAULT_GRADE_BATCH)
    capped = limit.to_i.clamp(1, MAX_GRADE_BATCH)
    graded = ActionGrade.by_grader(grader).where.not(atomic_event_id: nil).select(:atomic_event_id)
    closed.where.not(id: graded).order(closed_at: :desc, seq: :desc).limit(capped)
  end

  # The shape an agent needs to JUDGE a span: its id + what happened (category,
  # reason → outcome) + provenance (task, session, acting soul). No raw actions —
  # the grader judges the narrated span, not the tool stream. nil fields dropped.
  def to_grading_row
    { "id" => id, "category" => category, "reason" => reason_slug, "outcome" => outcome_slug,
      "task_slug" => task_slug, "session_id" => session_id, "agent" => agent }.compact
  end

  # Open a new span for the session, auto-closing any prior OPEN span first.
  #
  # The BOUNDARY transition (see `bin/atomic-event next` / `start --outcome`):
  # pass `prior_outcome_slug:` to stamp the auto-closed prior span's outcome as we
  # cross into the new span — so a span resolves with "what happened" in the SAME
  # call that opens "what's next", instead of hanging half-narrated with a NULL
  # outcome (the production failure this fixes). Without it, the prior span still
  # auto-closes, just with a NULL outcome (the legacy behavior).
  #
  # Backend discipline — VALIDATE BEFORE the irreversible side effect: we reject an
  # invalid span (e.g. a bad category) BEFORE auto-closing the prior span, so a
  # typo never strands the session with everything closed and nothing open. The
  # auto-close + insert then run in one transaction to preserve the single-open
  # invariant. Raises ActiveRecord::RecordInvalid on an invalid span (the caller —
  # the controller — turns that into a 422).
  #
  # `agent:` is the acting soul (see SOULS) — an unknown value is coerced to nil
  # (via #normalize_agent) rather than raising, so a bad --agent never sinks the
  # open. `mascot:` stays the STABLE base session mascot; the agent stacks on top.
  #
  #   AtomicEvent.open_event!(session_id:, category:, reason_slug:,
  #                           task_slug: nil, mascot: nil, stage: nil,
  #                           agent: nil, prior_outcome_slug: nil,
  #                           opened_at: Time.current) => AtomicEvent
  def self.open_event!(session_id:, category:, reason_slug:, task_slug: nil,
                       mascot: nil, stage: nil, agent: nil, prior_outcome_slug: nil,
                       opened_at: Time.current)
    event = new(
      session_id:  session_id,
      category:    category,
      reason_slug: reason_slug,
      task_slug:   task_slug,
      mascot:      mascot,
      stage:       stage,
      agent:       agent,
      seq:         next_seq_for(session_id),
      opened_at:   opened_at
    )
    raise ActiveRecord::RecordInvalid, event unless event.valid?

    transaction do
      close_attrs = { closed_at: opened_at, updated_at: opened_at }
      # Stamp the crossed-over span's outcome only when the agent narrated one, so
      # a bare open never blanks an outcome a prior close already set.
      close_attrs[:outcome_slug] = prior_outcome_slug if prior_outcome_slug.present?
      # Per-agent lanes: auto-close only THIS agent's open span (event.agent is the
      # already-normalized lane key — a known soul or nil), so a parallel soul
      # narration in the same session never closes another soul's in-flight span.
      for_session(session_id).where(agent: event.agent).open.update_all(close_attrs)
      event.save!
    end
    event
  end

  # Close the current OPEN span for (session, agent), stamping the narrated
  # outcome. `agent` selects the LANE (normalized like the record's own agent — an
  # unknown/blank value is the nil lane, the orchestrator's), so a reviewer's close
  # resolves ITS OWN span, not whichever soul opened last. Returns the closed span,
  # or nil when that lane has no open span (a stray close is a no-op, never an error).
  def self.close_event!(session_id:, agent: nil, outcome_slug: nil, closed_at: Time.current)
    event = for_session(session_id).where(agent: normalize_agent_value(agent)).open.order(:seq).last
    return nil unless event

    event.update!(outcome_slug: outcome_slug.presence, closed_at: closed_at)
    event
  end

  # Close EVERY still-open span for the session — the session-end teardown behind
  # `bin/atomic-event close-open` + the Claude Code SessionEnd hook. By the
  # single-open invariant this is usually one span, but a session that ended
  # mid-narration would otherwise leave its last span open FOREVER (and trailing
  # actions falling into "Unlabeled"); this closes them all with a shared generic
  # outcome (e.g. "session ended"). Returns the count closed — 0 is a no-op, never
  # an error (telemetry must not surface a session teardown as a failure).
  def self.close_all_open!(session_id:, outcome_slug: nil, closed_at: Time.current)
    attrs = { closed_at: closed_at, updated_at: closed_at }
    attrs[:outcome_slug] = outcome_slug if outcome_slug.present?
    for_session(session_id).open.update_all(attrs)
  end

  # The next span position for a session — max+1, 0-based (0 for the first span).
  # Best-effort: a lookup hiccup falls back to 0 rather than sinking the open.
  def self.next_seq_for(session_id)
    return 0 if session_id.blank?

    (where(session_id: session_id).maximum(:seq) || -1) + 1
  rescue StandardError
    0
  end

  def open?
    closed_at.nil?
  end

  def closed?
    !open?
  end

  private

  # Normalize `agent` to a known soul slug (down-cased + stripped) or nil. An
  # unknown/blank value becomes nil — the coercion is deliberately silent so a
  # typo'd --agent degrades to "base session mascot did it", never a hard error.
  def normalize_agent
    self.agent = self.class.normalize_agent_value(agent)
  end

  # The lane key for an agent value: a known SOULS slug (down-cased + stripped),
  # else nil (the orchestrator's un-agented lane). Shared by #normalize_agent (the
  # record) and the per-lane close scopes (open_event!/close_event!) so a WHERE on
  # `agent` matches the SAME normalized value the record was stored under.
  def self.normalize_agent_value(value)
    slug = value.to_s.strip.downcase
    SOULS.include?(slug) ? slug : nil
  end
end
