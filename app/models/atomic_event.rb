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
  #   AtomicEvent.open_event!(session_id:, category:, reason_slug:,
  #                           task_slug: nil, mascot: nil, stage: nil,
  #                           prior_outcome_slug: nil,
  #                           opened_at: Time.current) => AtomicEvent
  def self.open_event!(session_id:, category:, reason_slug:, task_slug: nil,
                       mascot: nil, stage: nil, prior_outcome_slug: nil,
                       opened_at: Time.current)
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
      close_attrs = { closed_at: opened_at, updated_at: opened_at }
      # Stamp the crossed-over span's outcome only when the agent narrated one, so
      # a bare open never blanks an outcome a prior close already set.
      close_attrs[:outcome_slug] = prior_outcome_slug if prior_outcome_slug.present?
      for_session(session_id).open.update_all(close_attrs)
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
end
