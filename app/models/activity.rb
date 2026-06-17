class Activity < ApplicationRecord
  TASK_CONVERSATION_TYPES = %w[comment qa_feedback handoff].freeze
  TASK_CONVERSATION_LABELS = {
    "comment" => "Comment",
    "qa_feedback" => "QA Feedback",
    "handoff" => "Handoff"
  }.freeze

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, optional: true
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true

  validates :activity_type, presence: true
  validates :description, presence: true

  after_create :set_slug

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

  private

  def set_slug
    update_column(:slug, "activity-#{id}")
  end
end
