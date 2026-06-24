# Append-only record of a single task stage event — the source of truth for the
# task's change log / timeline. Two kinds share this one spine:
#
#   TRANSITION (default) — a COMPLETED stage change. Written by
#     Task#write_stage_event on every stage move (the deterministic spine:
#     from/to/occurred_at/seconds_in_from), optionally annotated with the
#     agent-reported model/tokens/cost for the work done in the stage being left.
#
#   INTENT — an agent STARTING the work that will produce a stage, recorded the
#     moment that work begins (review picked, QA started, ship e2e started) so the
#     UI can show WHO is on it with a live ticker BEFORE the transition lands.
#     Written by Task#record_intent_event. Carries NO seconds_in_from (duration is
#     a completion concept) and is NEVER part of the duration spine — the next
#     transition measures back to the prior TRANSITION, skipping intents.
#
# Never updated after creation. An intent is "open" until a transition into its
# target stage lands; thereafter it is superseded (the completed event wins).
class TaskEvent < ApplicationRecord
  # How the event arrived. Free-form (not validated) so a new caller can never
  # make a real stage change fail by recording an unrecognized source.
  SOURCES = %w[cli api web conductor system].freeze

  # The two kinds of row on the spine (see class doc). Existing rows are all
  # transitions (the column default backfills them).
  TRANSITION = "transition"
  INTENT     = "intent"
  KINDS      = [TRANSITION, INTENT].freeze

  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: :task_events

  validates :to_stage, presence: true
  validates :occurred_at, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :chronological, -> { order(occurred_at: :asc, id: :asc) }
  scope :transitions, -> { where(kind: TRANSITION) }
  scope :intents, -> { where(kind: INTENT) }

  # Live-update the /deployments board the moment an event commits — a transition
  # moves the card, an intent updates it in place. AFTER commit so subscribers only
  # ever see persisted state; best-effort inside the broadcaster so a transport
  # failure never breaks the move. Bulk historical backfill rows don't broadcast.
  after_create_commit :broadcast_to_deployments_board

  def transition?
    kind == TRANSITION
  end

  def intent?
    kind == INTENT
  end

  # The stage left, as a label. The genesis event has no prior stage.
  def from_label
    return "Created" if from_stage.blank?

    Task::STAGE_LABELS.fetch(from_stage, from_stage.humanize)
  end

  # The stage entered, as a label.
  def to_label
    Task::STAGE_LABELS.fetch(to_stage, to_stage.to_s.humanize)
  end

  # True when the agent reported any usage for this transition (the best-effort
  # layer); false for deterministic-only transitions (model methods, conductor).
  def usage?
    model.present? || tokens_in.present? || tokens_out.present? || cost.present?
  end

  # Combined token count, or nil when neither side was reported.
  def tokens_total
    return nil if tokens_in.nil? && tokens_out.nil?

    tokens_in.to_i + tokens_out.to_i
  end

  # True for rows synthesized from legacy stage-timestamp columns by the
  # task_events:backfill task (approximate history, flagged so the UI can say so).
  def backfilled?
    metadata["backfilled"] == true
  end

  private

  def broadcast_to_deployments_board
    return if backfilled? # a bulk historical backfill shouldn't spam the board

    DeploymentsBroadcaster.task_event(self)
  end
end
