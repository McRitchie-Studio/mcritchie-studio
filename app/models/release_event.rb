class ReleaseEvent < ApplicationRecord
  STEPS = %w[
    review_tests
    assemble_release
    deploy_qa
    qa_smoke
    ship_gate
    ship_authorized
    deploy_prod
    prod_smoke
    release_notes
    archive_tasks
  ].freeze
  STATUSES = %w[started completed failed].freeze
  USAGE_REQUIRED_SOURCES = %w[api agent cli].freeze

  belongs_to :release, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release_events

  validates :release_slug, :step, :status, :occurred_at, presence: true
  validates :step, inclusion: { in: STEPS }
  validates :status, inclusion: { in: STATUSES }
  validates :tokens_in, :tokens_out, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :required_usage_for_agent_completion

  before_validation :default_occurred_at, on: :create
  before_validation :normalize_blank_scalars
  after_create_commit :broadcast_release_modules
  after_create_commit :refresh_release_duration_metrics

  scope :chronological, -> { order(occurred_at: :asc, id: :asc) }
  scope :for_step, ->(step) { where(step: step.to_s) }
  scope :completed, -> { where(status: "completed") }
  scope :started, -> { where(status: "started") }
  scope :failed, -> { where(status: "failed") }

  def self.record!(release:, step:, status:, **attrs)
    key = attrs[:idempotency_key].presence || attrs["idempotency_key"].presence
    if key
      existing = where(release_slug: release.slug, idempotency_key: key).first
      return existing if existing
    end

    create!(attrs.merge(release: release, step: step, status: status))
  end

  def completed?
    status == "completed"
  end

  def started?
    status == "started"
  end

  def failed?
    status == "failed"
  end

  def usage?
    model.present? || tokens_in.present? || tokens_out.present? || cost.present?
  end

  def tokens_total
    return nil if tokens_in.nil? && tokens_out.nil?

    tokens_in.to_i + tokens_out.to_i
  end

  private

  def default_occurred_at
    self.occurred_at ||= Time.current
  end

  def normalize_blank_scalars
    %w[source actor model repo app sha url command message idempotency_key].each do |field|
      self[field] = self[field].to_s.strip.presence
    end
    self.source ||= "api"
  end

  def required_usage_for_agent_completion
    return if status == "started"
    return unless USAGE_REQUIRED_SOURCES.include?(source.to_s)

    errors.add(:model, "is required for #{source} #{status} events") if model.blank?
    errors.add(:tokens_in, "is required for #{source} #{status} events") if tokens_in.nil?
    errors.add(:tokens_out, "is required for #{source} #{status} events") if tokens_out.nil?
    errors.add(:cost, "is required for #{source} #{status} events") if cost.nil?
  end

  # The declared kind for the client's ReleaseFx router — the step/status pair this
  # spine already carries, spelled as an fx event (`release_event.deploy_prod.completed`).
  # No handler claims one today (the Last Release card's only animation is the deploy
  # glow); they are declared now so the follow-up animation vocabulary has real events
  # to bind to instead of re-deriving them from the DOM.
  def broadcast_release_modules
    DeploymentsBroadcaster.release_modules(fx: "release_event.#{step}.#{status}")
    DeploymentsBroadcaster.app_ladder
  end

  def refresh_release_duration_metrics
    release&.refresh_duration_metrics_safely
  end
end
