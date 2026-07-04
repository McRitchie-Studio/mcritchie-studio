class Activity < ApplicationRecord
  TASK_CONVERSATION_TYPES = %w[comment clarification qa_feedback handoff].freeze
  TASK_CONVERSATION_LABELS = {
    "comment" => "Comment",
    "clarification" => "Clarification",
    "qa_feedback" => "QA Feedback",
    "handoff" => "Handoff"
  }.freeze
  TASK_CONVERSATION_DESCRIPTIONS = {
    "comment" => "General coordination note",
    "clarification" => "Non-blocking question or answer",
    "qa_feedback" => "Blocking review feedback",
    "handoff" => "Response or ready-again handoff"
  }.freeze

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, optional: true
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true
  # The block-mined grade candidates whose provenance is THIS activity (a
  # qa_feedback block). Nullify on destroy so a mined candidate outlives the block
  # Activity it was seeded from, mirroring ActionGrade's other nullify FKs.
  has_many :seeded_grades, class_name: "ActionGrade", foreign_key: :source_activity_slug,
                           primary_key: :slug, inverse_of: :source_activity, dependent: :nullify

  validates :activity_type, presence: true
  validates :description, presence: true

  after_create :set_slug
  # When a handoff RESOLVES a QA block, that block is now a complete, pre-labeled
  # failure case — mine it into an ActionGrade candidate. after_create_COMMIT (not
  # after_create) so the row is durable before the async job reads it, and the
  # handoff's own slug (set_slug above) has landed. Scoped to this task, idempotent
  # (Insights::BlockMiner guards on source_activity_slug), best-effort per backend
  # discipline: a queue hiccup is logged to ErrorLog, never sinks the handoff write.
  after_create_commit :mine_block_insights, if: :resolves_feedback?

  scope :recent, -> { order(created_at: :desc) }
  scope :by_type, ->(type) { where(activity_type: type) }
  scope :for_task, ->(task_or_slug) { where(task_slug: task_or_slug.respond_to?(:slug) ? task_or_slug.slug : task_or_slug) }
  scope :conversation_order, -> { order(created_at: :asc, id: :asc) }

  def task_conversation?
    task_slug.present?
  end

  def activity_type_label
    TASK_CONVERSATION_LABELS.fetch(activity_type, activity_type.to_s.humanize)
  end

  def activity_type_description
    TASK_CONVERSATION_DESCRIPTIONS.fetch(activity_type, activity_type_label)
  end

  def clarification?
    activity_type == "clarification"
  end

  def blocking_feedback?
    activity_type == "qa_feedback"
  end

  def resolves_feedback?
    activity_type == "handoff" && truthy_metadata?("resolves_feedback")
  end

  private

  # Enqueue the block miner for this task the moment a block is resolved. Best-effort
  # (a broken queue must not fail the handoff): an enqueue error is captured to
  # ErrorLog and swallowed. The job re-scans and is idempotent, so a missed enqueue
  # is recoverable by any later mine (a new resolution, or a backfill run).
  def mine_block_insights
    BlockInsightMiningJob.perform_later(task_slug)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  def truthy_metadata?(key)
    value = metadata.to_h[key]
    value == true || value.to_s.match?(/\A(1|true|yes)\z/i)
  end

  def set_slug
    update_column(:slug, "activity-#{id}")
  end
end
