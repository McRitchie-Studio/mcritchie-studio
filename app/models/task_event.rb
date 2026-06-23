# Append-only record of a single task stage transition — the source of truth for
# the task's change log / timeline. Written by Task#record_stage_event on every
# stage change (the deterministic spine: from/to/occurred_at/seconds_in_from),
# optionally annotated with the agent-reported model/tokens/cost for the work
# done in the stage being left. Never updated after creation.
class TaskEvent < ApplicationRecord
  # How the transition arrived. Free-form (not validated) so a new caller can
  # never make a real stage change fail by recording an unrecognized source.
  SOURCES = %w[cli api web conductor system].freeze

  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: :task_events

  validates :to_stage, presence: true
  validates :occurred_at, presence: true

  scope :chronological, -> { order(occurred_at: :asc, id: :asc) }

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
end
