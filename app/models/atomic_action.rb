# One DB record per agent action — the FORWARD-ONLY atomic trajectory.
#
# Where TaskEvent records a COMPLETED stage CHANGE (the coarse spine), an
# AtomicAction records a SINGLE step within a stage: a read, an edit, a bash run,
# a test/verify, a delegate. The two compose — a stage's worth of AtomicActions
# rolls up under the TaskEvent that closes that stage. There is no historical
# backfill; capture starts the moment this ships and only ever moves forward.
#
# Capture is BEST-EFFORT (backend discipline): AtomicAction.capture writes one row
# and NEVER lets a telemetry failure break the calling action — any exception is
# swallowed into an ErrorLog and capture returns nil. Telemetry must not be able
# to take down the work it observes.
#
# Usage attribution (model/tokens/cost) mirrors TaskEvent: capture takes explicit
# attrs first, then falls back to the request/job's Current.task_event_* context
# (the same seam Task#write_stage_event drains), then to the column defaults. So a
# harness that sets Current usage once gets every action it captures attributed
# for free, exactly like a `bin/task move` does.
class AtomicAction < ApplicationRecord
  # The outcome of a single action — the local credit signal.
  OK       = "ok"
  ERROR    = "error"
  PENDING  = "pending"
  OUTCOMES = [OK, ERROR, PENDING].freeze

  # Who took the action. Mirrors the prototype's actor lane.
  HARNESS = "harness" # Claude Code / Codex runtime
  AGENT   = "agent"   # the session agent (on-policy)
  BOARD   = "board"   # Rails board / bin command
  HUMAN   = "human"   # the operator
  ACTORS  = [HARNESS, AGENT, BOARD, HUMAN].freeze

  # Slug FK to tasks (the ecosystem convention). Optional: PRE-task actions (boot,
  # intake) carry a null task_slug, and capture must never fail on a task lookup.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug,
                    optional: true, inverse_of: :atomic_actions

  validates :session_id, presence: true
  validates :kind, presence: true
  validates :occurred_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :actor, inclusion: { in: ACTORS }
  validates :seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :chronological, -> { order(occurred_at: :asc, seq: :asc, id: :asc) }
  scope :for_session,   ->(session_id) { where(session_id: session_id) }
  scope :anchors,       -> { where(feedback_anchor: true) }
  scope :errored,       -> { where(outcome: ERROR) }

  # Best-effort forward write of ONE action record. Returns the persisted
  # AtomicAction, or nil if anything went wrong (already logged). Accepts string
  # OR symbol keys so harness, service, and in-process callers all work.
  #
  #   AtomicAction.capture(
  #     session_id:, kind:,                      # required
  #     task_slug: nil, mascot: nil, seq: nil,   # seq auto-derives per session when omitted
  #     event_slug: nil, result_slug: nil,
  #     input: nil, output: nil,
  #     outcome: "pending", actor: "agent",
  #     model: nil, tokens_in: nil, tokens_out: nil, cost: nil,  # fall back to Current.task_event_*
  #     stage: nil, feedback_anchor: false,
  #     occurred_at: Time.current, duration_ms: nil
  #   ) => AtomicAction | nil
  def self.capture(attrs = {})
    attrs = attrs.to_h.symbolize_keys

    create!(
      session_id:      attrs[:session_id],
      task_slug:       attrs[:task_slug],
      mascot:          attrs[:mascot],
      seq:             attrs[:seq] || next_seq_for(attrs[:session_id]),
      kind:            attrs[:kind],
      event_slug:      attrs[:event_slug],
      result_slug:     attrs[:result_slug],
      input:           attrs[:input],
      output:          attrs[:output],
      outcome:         attrs[:outcome].presence || PENDING,
      model:           attrs.fetch(:model) { Current.task_event_model }.presence,
      tokens_in:       (attrs.fetch(:tokens_in)  { Current.task_event_tokens_in }  || 0).to_i,
      tokens_out:      (attrs.fetch(:tokens_out) { Current.task_event_tokens_out } || 0).to_i,
      cost:            (attrs.fetch(:cost)       { Current.task_event_cost }       || 0).to_d,
      stage:           attrs[:stage],
      actor:           attrs[:actor].presence || AGENT,
      feedback_anchor: attrs.fetch(:feedback_anchor, false) || false,
      occurred_at:     attrs[:occurred_at] || Time.current,
      duration_ms:     attrs[:duration_ms]
    )
  rescue StandardError => e
    # Telemetry is best-effort: log and move on, NEVER re-raise into the caller.
    # Double-guard the logger itself so a failing ErrorLog can't break the action.
    begin
      ErrorLog.capture!(e)
    rescue StandardError => log_error
      Rails.logger.error("[AtomicAction.capture] swallowed #{e.class}: #{e.message} " \
                         "(logging also failed: #{log_error.class})")
    end
    nil
  end

  # The next trajectory position for a session — max+1, 0-based, 0 for the first
  # action. Best-effort: a lookup hiccup falls back to 0 rather than sinking the
  # whole capture (the caller is inside capture's rescue regardless).
  def self.next_seq_for(session_id)
    return 0 if session_id.blank?

    (where(session_id: session_id).maximum(:seq) || -1) + 1
  rescue StandardError
    0
  end

  def ok?
    outcome == OK
  end

  def error?
    outcome == ERROR
  end

  def pending?
    outcome == PENDING
  end

  def anchor?
    feedback_anchor
  end

  # Combined token count for this action (mirrors TaskEvent#tokens_total).
  def tokens_total
    tokens_in.to_i + tokens_out.to_i
  end
end
