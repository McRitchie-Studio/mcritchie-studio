class Task < ApplicationRecord
  SIZES = %w[small medium large xl].freeze

  # Two-workflow status model. See docs/agents/system/devops-cycle-design.md.
  #
  #   Workflow 1 — Build:   designed → building → submitted → reviewed
  #   Workflow 2 — Deploy:  reviewed → assembled → shipped   (reviewed is the seam)
  #   blocked  — side state: agent hit a wall, QA bounced a PR, or a dep isn't ready.
  #   archived — terminal trash (abandoned, never shipping).
  STAGE_LABELS = {
    "designed"  => "Designed",
    "building"  => "Building",
    "submitted" => "Submitted",
    "reviewed"  => "Reviewed",
    "assembled" => "Assembled",
    "shipped"   => "Shipped",
    "blocked"   => "Blocked",
    "archived"  => "Archived"
  }.freeze
  STAGES = STAGE_LABELS.keys.freeze
  BOARD_STAGES = (STAGES - ["archived"]).freeze
  # The two workflows, for grouping/headers. `reviewed` is the shared seam.
  BUILD_STAGES  = %w[designed building submitted reviewed].freeze
  DEPLOY_STAGES = %w[reviewed assembled shipped].freeze
  # Board columns per page, split by owner with `submitted` as the shared seam.
  # /tasks is the feature-agent lane (build work, incl. the blocked side state);
  # /deployments is the DevOps lane (review → release), starting at the seam.
  TASKS_BOARD_STAGES       = %w[designed building blocked submitted].freeze
  DEPLOYMENTS_BOARD_STAGES = %w[submitted reviewed assembled shipped].freeze
  # Why a task sits in `blocked` — lets a heartbeat agent route it correctly.
  BLOCK_KINDS = %w[environment rework dependency].freeze
  MIGRATION_LANE = "backend_migration".freeze
  DEVOPS_SCALAR_KEYS = %w[
    kind shape worktree_slug branch pr_url local_url qa_url production_url release_train
    requires_release_conductor block_kind
  ].freeze
  DEVOPS_LIST_KEYS = %w[repositories risk_tags acceptance test_plan checks_run].freeze
  DEVOPS_KEYS = (DEVOPS_SCALAR_KEYS + DEVOPS_LIST_KEYS).freeze
  # The change shape selects its DoR test contract. Keep in sync with
  # config/feature_shapes.yml (the source of truth that bin/dor-check reads).
  SHAPES = %w[ui-only ui+db backend library onchain onchain-vertical].freeze

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, optional: true
  belongs_to :release, foreign_key: :release_slug, primary_key: :slug, optional: true, inverse_of: :tasks
  has_many :activities, foreign_key: :task_slug, primary_key: :slug, dependent: :nullify

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :stage, inclusion: { in: STAGES }
  validates :priority, inclusion: { in: [0, 1, 2] }
  validates :pm_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :po_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :dev_size,    inclusion: { in: SIZES }, allow_nil: true
  validates :actual_size, inclusion: { in: SIZES }, allow_nil: true

  before_validation :generate_slug, on: :create
  before_create :set_initial_position
  before_save :set_stage_timestamp, if: :stage_changed?

  def to_param
    slug
  end

  scope :by_stage, ->(stage) { where(stage: stage) }
  scope :blocked, -> { where(stage: "blocked") }
  scope :recent, -> { order(created_at: :desc) }
  scope :ordered, -> { order(Arel.sql("position ASC NULLS LAST, created_at DESC")) }
  scope :requires_migration, -> { where(requires_migration: true) }

  def devops
    metadata.fetch("devops", {}) || {}
  end

  def devops?
    devops.any?
  end

  def devops_kind
    devops.fetch("kind", "").presence || "feature"
  end

  def devops_shape
    devops.fetch("shape", "").presence
  end

  def devops_release_train
    devops.fetch("release_train", "").presence
  end

  def devops_worktree_slug
    devops.fetch("worktree_slug", "").presence
  end

  def devops_repositories
    devops_list("repositories")
  end

  def devops_risk_tags
    devops_list("risk_tags")
  end

  def devops_acceptance
    devops_list("acceptance")
  end

  def devops_test_plan
    devops_list("test_plan")
  end

  def devops_checks_run
    devops_list("checks_run")
  end

  def devops_url(name)
    devops.fetch("#{name}_url", "").presence
  end

  def devops_field(name)
    devops.fetch(name.to_s, "").presence
  end

  def requires_release_conductor?
    ActiveModel::Type::Boolean.new.cast(devops.fetch("requires_release_conductor", false))
  end

  def blocked?
    stage == "blocked"
  end

  # Why the task is blocked (environment / rework / dependency), carried in
  # devops so a heartbeat agent can route it without re-reading the thread.
  def block_kind
    devops.fetch("block_kind", "").presence
  end

  def stage_label
    STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  def self.normalize_devops_metadata(raw)
    return {} if raw.blank?

    raw.to_h.each_with_object({}) do |(key, value), normalized|
      key = key.to_s
      next unless DEVOPS_KEYS.include?(key)

      normalized_value = DEVOPS_LIST_KEYS.include?(key) ? normalize_devops_list(value) : value.to_s.strip
      next if normalized_value.blank?

      normalized[key] = normalized_value
    end
  end

  def self.normalize_devops_list(value)
    # Array input (the JSON API / bin/task) is already delimited — each element
    # is one item, so split ONLY on newlines. Commas are legitimate inside
    # acceptance/test_plan sentences and must be preserved. String input (UI
    # free-text fields) keeps the newline+comma split so a single field can
    # carry several comma-separated entries.
    parts =
      if value.is_a?(Array)
        value.flat_map { |item| item.to_s.split("\n") }
      else
        value.to_s.split(/[\n,]/)
      end
    parts.map(&:strip)
         .reject(&:blank?)
         .uniq
  end

  # Postgres advisory locks are session-scoped — try_acquire and release
  # must run on the same DB connection. Designed for long-lived agent
  # processes, not Rails request cycles. See exclusive-lanes.md.
  def self.try_acquire_migration_lane
    connection.select_value("SELECT pg_try_advisory_lock(hashtext('#{MIGRATION_LANE}'))")
  end

  def self.release_migration_lane
    connection.select_value("SELECT pg_advisory_unlock(hashtext('#{MIGRATION_LANE}'))")
  end

  # --- Workflow 1: Build ---------------------------------------------------
  def design!
    update!(stage: "designed")
  end

  def build!
    update!(stage: "building")
  end

  def submit!
    update!(stage: "submitted")
  end

  def review!
    update!(stage: "reviewed")
  end

  # --- Workflow 2: Deploy --------------------------------------------------
  def assemble!
    update!(stage: "assembled")
  end

  def ship!(result_data = {})
    update!(stage: "shipped", result: result_data)
  end

  # --- Side / terminal -----------------------------------------------------
  # block! moves the task off the autonomous pipeline. `kind` (environment /
  # rework / dependency) is stored in devops; `blocked_from` is captured
  # automatically from the stage it left. Feedback rides along as a
  # qa_feedback Activity, not on the task itself.
  def block!(kind: nil)
    merged = metadata.deep_dup
    if kind.present?
      merged["devops"] ||= {}
      merged["devops"]["block_kind"] = kind.to_s
    end
    update!(stage: "blocked", metadata: merged)
  end

  def archive!
    update!(stage: "archived")
  end

  private

  def devops_list(key)
    self.class.normalize_devops_list(devops.fetch(key.to_s, []))
  end

  def set_stage_timestamp
    case stage
    when "building"  then self.started_at   = Time.current
    when "submitted" then self.submitted_at = Time.current
    when "reviewed"  then self.reviewed_at  = Time.current
    when "assembled" then self.assembled_at = Time.current
    when "shipped"   then self.completed_at = Time.current
    when "blocked"
      self.blocked_at = Time.current
      self.blocked_from = stage_was.presence
    when "archived"  then self.archived_at = Time.current
    end
    self.position = (Task.where(stage: stage).maximum(:position) || -1) + 1 unless new_record?
  end

  def set_initial_position
    self.position ||= (Task.where(stage: stage).maximum(:position) || -1) + 1
  end

  def generate_slug
    self.slug ||= "task-#{SecureRandom.hex(6)}"
  end
end
