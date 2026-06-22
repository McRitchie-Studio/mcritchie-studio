class Task < ApplicationRecord
  SIZES = %w[small medium large xl].freeze

  # Two-workflow status model. See docs/agents/system/devops-cycle-design.md.
  #
  #   Workflow 1 — Build (feature agent):  designed → building → submitted
  #   Workflow 2 — Deploy (DevOps):        submitted → reviewed → assembled → shipped
  #   `submitted` is the shared seam — the feature agent hands off to DevOps there.
  #   blocked  — side state: agent hit a wall, QA bounced a PR, or a dep isn't ready.
  #   archived — terminal resting state: abandoned tickets AND shipped/completed
  #              work filed away (Archive completed tasks) to close the loop.
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
  # The two workflows, split at the `submitted` seam (which belongs to both):
  # Build is the feature agent's, Deploy is DevOps's.
  BUILD_STAGES  = %w[designed building submitted].freeze
  DEPLOY_STAGES = %w[submitted reviewed assembled shipped].freeze
  # Board columns per page. /tasks is the feature-agent lane (Build + the blocked
  # side state); /deployments is the DevOps lane (= the Deploy workflow).
  TASKS_BOARD_STAGES       = %w[designed building blocked submitted].freeze
  DEPLOYMENTS_BOARD_STAGES = DEPLOY_STAGES
  # Why a task sits in `blocked` — lets a heartbeat agent route it correctly.
  BLOCK_KINDS = %w[environment rework dependency].freeze
  MIGRATION_LANE = "backend_migration".freeze
  DEVOPS_SCALAR_KEYS = %w[
    kind shape worktree_slug branch pr_url local_url qa_url production_url release_train
    requires_release_conductor block_kind agent_context session_id session_provider
  ].freeze
  # Provider → resume-command template (one %s, the session id). Codex is a
  # one-line addition once its real resume syntax is confirmed.
  # TODO: confirm codex resume syntax + env var.
  RESUME_COMMANDS = {
    "claude" => "claude --resume %s",
    "codex"  => "codex resume %s"
  }.freeze
  # Human-facing fields are kept terse (so the operator can read the board at a
  # glance); agents put their verbose detail in `agent_context`.
  TITLE_WORD_RANGE = (3..5).freeze
  ACCEPTANCE_WORD_RANGE = (5..12).freeze
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
  # Naming discipline — enforced wherever the title/acceptance is set or changed
  # (every create + any update that touches them, all paths). Gated on change, so
  # existing tasks that don't touch these fields stay grandfathered.
  validate :title_within_word_range, if: :title_changed?
  validate :acceptance_bullets_within_word_range, if: :acceptance_changed?
  validates :priority, inclusion: { in: [0, 1, 2] }
  validates :pm_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :po_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :dev_size,    inclusion: { in: SIZES }, allow_nil: true
  validates :actual_size, inclusion: { in: SIZES }, allow_nil: true

  attr_readonly :slug # the readable handle is set once at creation, then immutable

  before_validation :generate_slug, on: :create
  before_validation :default_devops_handles_from_slug, on: :create
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

  # Free-form verbose detail agents write for each other — no length constraint
  # (the readability constraints are on title + acceptance).
  def devops_agent_context
    devops.fetch("agent_context", "").presence
  end

  # --- Session resume (V1: store + display + copy; no enforcement gate) -------
  # The Claude/Codex session that worked this task, captured by bin/task on
  # create + on the move to `building` (the claim moment). Lets the operator see
  # which terminal owns a task (the last-4 on the board + status line) and copy a
  # command to reopen it.
  def devops_session_id
    devops.fetch("session_id", "").presence
  end

  # Which CLI the session belongs to; nil is treated as "claude" (the default).
  def devops_session_provider
    devops.fetch("session_provider", "").presence
  end

  # Last 4 chars of the session id — the at-a-glance handle. nil when unset.
  def session_id_last4
    id = devops_session_id
    id && id[-4..]
  end

  # The FULL, copyable resume command (provider-aware). nil when no session id.
  def resume_command
    id = devops_session_id
    return nil unless id

    provider = devops_session_provider || "claude"
    format(RESUME_COMMANDS.fetch(provider, RESUME_COMMANDS["claude"]), id)
  end

  # Truncated display form, e.g. "claude --resume …12ab" (verb + …<last4>).
  # nil when no session id.
  def resume_command_display
    id = devops_session_id
    return nil unless id

    provider = devops_session_provider || "claude"
    format(RESUME_COMMANDS.fetch(provider, RESUME_COMMANDS["claude"]), "…#{id[-4..]}")
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

  # The ecosystem repo this task's PR/branch lives in — the unit the Deploy
  # workflow classifies as a gem (producer) or an app (consumer). Prefer the
  # repo parsed from the PR url (github.com/<owner>/<repo>/pull/N), since that's
  # where the branch actually is; fall back to the declared repositories — for a
  # `library` shape the gem repo named there, otherwise the first entry.
  def release_repo
    repo_from_pr_url.presence ||
      if devops_shape == "library"
        devops_repositories.find { |repo| Release::Repos.gem?(repo) } || devops_repositories.first
      else
        devops_repositories.first
      end
  end

  # True when this task ships as a published gem rather than a deployed app — a
  # `library` shape always is, and so is anything whose release_repo is a
  # registered gem. Drives producer-first ordering and the board 💎 gem badge.
  def gem_release?
    devops_shape == "library" || Release::Repos.gem?(release_repo)
  end

  # :gem / :app / :unknown — the member kind the conductor orders + plans by.
  def release_kind
    return :gem if gem_release?

    Release::Repos.kind(release_repo)
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

  # Extract the repo from a GitHub PR url: github.com/<owner>/<repo>/pull/<n>.
  def repo_from_pr_url
    devops_url("pr").to_s[%r{github\.com/[^/]+/([^/]+)/pull/}, 1]
  end

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

  # The slug is the readable, immutable handle set at creation — it drives the
  # URL (/tasks/<slug>) and seeds the worktree + branch. Precedence: an explicit
  # --slug (parameterized), else the (now-terse) title (parameterized +
  # auto-suffixed), else an opaque task-<hex> last resort. `@custom_slug` records
  # whether the slug is readable, so the trickle-down only fires for a real handle.
  def generate_slug
    explicit = slug.present?
    base = (explicit ? slug : title).to_s.parameterize
    if base.present?
      # Explicit --slug is left as-is (uniqueness validation surfaces a collision
      # to the chooser); a title-derived slug auto-suffixes, since short titles repeat.
      self.slug = explicit ? base : unique_slug(base)
      @custom_slug = true
    else
      self.slug = "task-#{SecureRandom.hex(6)}"
      @custom_slug = false
    end
  end

  # Append -2, -3, … until the title-derived slug is unique.
  def unique_slug(base)
    candidate = base
    n = 1
    while Task.where(slug: candidate).where.not(id: id).exists?
      n += 1
      candidate = "#{base}-#{n}"
    end
    candidate
  end

  # Trickle-down: a custom slug seeds worktree_slug + branch (feat/<slug>) when
  # they aren't given explicitly, so one slug drives the rest. Opaque hex slugs
  # don't trickle (nothing readable to propagate).
  def default_devops_handles_from_slug
    return unless @custom_slug

    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    devops["worktree_slug"] = slug if devops["worktree_slug"].blank?
    devops["branch"] = "feat/#{slug}" if devops["branch"].blank?
  end

  def word_count(text)
    text.to_s.split(/\s+/).reject(&:blank?).size
  end

  # True on create (acceptance newly set) and on any update that actually changes
  # the acceptance list — so untouched existing tasks (and updates to other devops
  # fields) stay grandfathered. Both sides are normalized before comparing, so a
  # task whose stored acceptance isn't already in normalized form (e.g. a direct
  # Task.create! with dupes/embedded newlines) isn't falsely re-validated on an
  # unrelated devops update.
  def acceptance_changed?
    previous = self.class.normalize_devops_list((metadata_was || {}).dig("devops", "acceptance"))
    previous != devops_acceptance
  end

  # Keep titles tight (3-5 words) so they read at a glance and slugify cleanly —
  # detail belongs in agent_context, not the title.
  def title_within_word_range
    count = word_count(title)
    return if TITLE_WORD_RANGE.cover?(count)

    errors.add(:title, "must be #{TITLE_WORD_RANGE.first}-#{TITLE_WORD_RANGE.last} words " \
                       "(was #{count}) — name it tightly; put detail in agent_context")
  end

  # Each acceptance bullet stays a readable 5-12 words so the human can follow the story.
  def acceptance_bullets_within_word_range
    devops_acceptance.each_with_index do |bullet, i|
      count = word_count(bullet)
      next if ACCEPTANCE_WORD_RANGE.cover?(count)

      errors.add(:base, "acceptance ##{i + 1} must be #{ACCEPTANCE_WORD_RANGE.first}-" \
                        "#{ACCEPTANCE_WORD_RANGE.last} words (was #{count}): #{bullet.to_s.truncate(48)}")
    end
  end
end
