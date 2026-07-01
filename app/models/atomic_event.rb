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
# INVARIANT: at most one OPEN span per session at a time. Opening a new span
# auto-closes the prior open one (see .open_event!), so the "current open event"
# an incoming action attributes to is always unambiguous.
class AtomicEvent < ApplicationRecord
  # The agent-declared span vocabulary — a fixed, small set so spans stay
  # comparable across sessions. The agent picks ONE per span.
  CATEGORIES = %w[
    Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan
  ].freeze

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

  scope :for_session,  ->(session_id) { where(session_id: session_id) }
  scope :open,         -> { where(closed_at: nil) }
  scope :closed,       -> { where.not(closed_at: nil) }
  scope :chronological, -> { order(opened_at: :asc, seq: :asc, id: :asc) }

  # Open a new span for the session, auto-closing any prior OPEN span first.
  #
  # Backend discipline — VALIDATE BEFORE the irreversible side effect: we reject an
  # invalid span (e.g. a bad category) BEFORE auto-closing the prior span, so a
  # typo never strands the session with everything closed and nothing open. The
  # auto-close + insert then run in one transaction to preserve the single-open
  # invariant. Raises ActiveRecord::RecordInvalid on an invalid span (the caller —
  # the controller — turns that into a 422).
  #
  #   AtomicEvent.open_event!(session_id:, category:, reason_slug:,
  #                           task_slug: nil, mascot: nil, stage: nil,
  #                           opened_at: Time.current) => AtomicEvent
  def self.open_event!(session_id:, category:, reason_slug:, task_slug: nil,
                       mascot: nil, stage: nil, opened_at: Time.current)
    event = new(
      session_id:  session_id,
      category:    category,
      reason_slug: reason_slug,
      task_slug:   task_slug,
      mascot:      mascot,
      stage:       stage,
      seq:         next_seq_for(session_id),
      opened_at:   opened_at
    )
    raise ActiveRecord::RecordInvalid, event unless event.valid?

    transaction do
      for_session(session_id).open.update_all(closed_at: opened_at, updated_at: opened_at)
      event.save!
    end
    event
  end

  # Close the session's current OPEN span, stamping the outcome the agent
  # narrates. Returns the closed span, or nil when the session has no open span
  # (a stray close is a no-op, never an error).
  def self.close_event!(session_id:, outcome_slug: nil, closed_at: Time.current)
    event = for_session(session_id).open.order(:seq).last
    return nil unless event

    event.update!(outcome_slug: outcome_slug.presence, closed_at: closed_at)
    event
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
end
