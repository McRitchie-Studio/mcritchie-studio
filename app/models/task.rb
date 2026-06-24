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
  # side state). /deployments shows the full pipeline as swim lanes — the Deploy
  # workflow plus the upstream designed/building lanes (drag-and-drop; more later).
  # The Deploy *workflow* itself (the /stages guide + per-stage kickoffs) stays
  # DEPLOY_STAGES — the board carrying extra lanes doesn't widen the workflow.
  TASKS_BOARD_STAGES       = %w[designed building blocked submitted].freeze
  DEPLOYMENTS_BOARD_STAGES = %w[designed building submitted reviewed assembled shipped].freeze
  # Why a task sits in `blocked` — lets a heartbeat agent route it correctly.
  BLOCK_KINDS = %w[environment rework dependency].freeze
  MIGRATION_LANE = "backend_migration".freeze
  DEVOPS_SCALAR_KEYS = %w[
    kind shape worktree_slug branch pr_url local_url qa_url production_url release_train
    requires_release_conductor block_kind agent_context session_id session_provider mascot
    mascot_session claimed_session claim_nonce claim_expires_at post_deploy_cmd built_by
  ].freeze
  # Provider → resume-command template (one %s, the session id).
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
  has_many :task_events, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :destroy

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
  before_validation :sync_session_mascot, on: :create
  before_create :set_initial_position
  before_save :set_stage_timestamp, if: :stage_changed?
  # Per-session mascot: re-derive on each build-phase transition (designed/building/
  # submitted) so a task picked up by a DIFFERENT agent swaps to that session's Pokémon.
  before_save :sync_session_mascot, if: -> { will_save_change_to_stage? && Task::BUILD_STAGES.include?(stage) }
  # One TaskEvent per save that lands a stage: the genesis on create (the default
  # "designed" stage isn't a dirty change, so this is guard-free) and one per real
  # transition on update.
  after_create :record_genesis_event
  after_update :record_transition_event, if: :saved_change_to_stage?

  def to_param
    slug
  end

  scope :by_stage, ->(stage) { where(stage: stage) }
  scope :blocked, -> { where(stage: "blocked") }
  scope :recent, -> { order(created_at: :desc) }
  scope :ordered, -> { order(Arel.sql("position ASC NULLS LAST, created_at DESC")) }
  scope :requires_migration, -> { where(requires_migration: true) }
  # Tasks still in play — everything except the two terminal stages. A live task's
  # mascot is "taken"; shipping or archiving returns its Pokémon to the deck.
  scope :live, -> { where.not(stage: %w[shipped archived]) }

  # The mascot slugs currently held by live tasks — the exclusion set the draw
  # skips so two in-flight tasks never share a Pokémon.
  def self.active_mascots
    live.pluck(:metadata).filter_map { |m| m&.dig("devops", "mascot").presence }
  end

  # Backfill: give a mascot to every LIVE task that lacks one — for tasks created
  # before the mascot feature (assign_mascot is create-only) so the existing board
  # lights up. Idempotent (skips tasks that already have one), unique among live
  # tasks, written through the normal devops path (not update_column) so it stays a
  # real, normalized scalar. The exclusion set is hoisted once and grown in memory
  # (no per-row table re-scan), terminal stages are skipped, and a row that fails to
  # save is captured to ErrorLog (durable — rolling logs roll off) and skipped so
  # one bad task can't abort a prod run. Returns the count newly assigned.
  def self.backfill_mascots!
    taken = active_mascots.to_set
    assigned = 0
    live.find_each do |task|
      next if task.devops["mascot"].present?

      pick = Pokemon.draw(exclude: taken.to_a)
      next unless pick

      merged = task.metadata.deep_dup
      (merged["devops"] ||= {})["mascot"] = pick.slug
      task.update!(metadata: merged)
      taken << pick.slug
      assigned += 1
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = task
      log.target_name = task.slug
      log.save!
    end
    assigned
  end

  # Migrate a board from the old per-TASK mascots to the per-SESSION rule: every live
  # task carrying a session_id adopts its session's Pokémon (the first one seen for that
  # session wins; sessions stay unique among themselves). Session-less tasks keep theirs.
  # Idempotent; a failed row is captured to ErrorLog and skipped. Returns the count.
  def self.resync_session_mascots!
    by_session = {}
    taken = active_mascots.to_set
    restamped = 0
    live.find_each do |task|
      sid = task.metadata&.dig("devops", "session_id").to_s
      next if sid.blank?

      slug = by_session[sid] ||= (task.metadata.dig("devops", "mascot").presence || Pokemon.draw(exclude: taken.to_a)&.slug)
      next unless slug
      taken << slug

      dev = task.metadata["devops"] || {}
      next if dev["mascot"] == slug && dev["mascot_session"] == sid

      merged = task.metadata.deep_dup
      d = (merged["devops"] ||= {})
      d["mascot"] = slug
      d["mascot_session"] = sid
      d["mascot_color"] = Pokemon.find_by(slug: slug)&.signature_color
      task.update_columns(metadata: merged)
      restamped += 1
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = task
      log.target_name = task.slug
      log.save!
    end
    restamped
  end

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

  # The soul who BUILT this task — stamped from the build-claim actor on the move
  # to `building` WHEN that actor resolves to a soul slug (see #stamp_builder), so
  # the reviewer pool can exclude the builder (a soul shouldn't review their own
  # work). nil when the build lane recorded no actor (a model-method / conductor
  # move) or only a session id (a bare CLI move with no --actor <soul>).
  # ReviewerSelector also falls back to the `→ building` TaskEvent actor when this
  # scalar is blank.
  def devops_built_by
    devops.fetch("built_by", "").presence
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

  # --- Build claim lease (V2: the enforcement gate) -------------------------
  # The LIVE INSTANCE that owns this task while it's building — the session id
  # PLUS a per-process nonce, under a TTL lease (claim_expires_at) renewed by the
  # heartbeat (bin/statusline). `bin/task move <task> building` refuses to claim a
  # task already held by a different, non-expired instance. The lease math lives
  # in ClaimLease (shared verbatim with the standalone bin/task CLI).
  def devops_claim
    ClaimLease.from_devops(devops)
  end

  def claimed_session_id
    devops.fetch("claimed_session", "").presence
  end

  def devops_claim_nonce
    devops.fetch("claim_nonce", "").presence
  end

  # True while a non-expired claim is held — the liveness check the /tasks resume
  # control reuses ("session looks active in another terminal — resume anyway?").
  def claim_live?(now: Time.current)
    ClaimLease.live?(devops, now: now)
  end

  # Seconds since the holder's last heartbeat (nil when unclaimed / no lease).
  def claim_heartbeat_seconds_ago(now: Time.current)
    ClaimLease.heartbeat_age(devops, now: now)
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

  # The two senior reviewers Avi assigned for the `submitted` review (the Deploy
  # half's review step), each `{ "slug" => ..., "weight" => "heavy"|"light" }`,
  # read off THIS task's own `metadata["reviewers"]`. NOTE: the canonical write
  # target for the avatars UI is the submitted→reviewed TaskEvent's metadata (see
  # #stage_event_metadata) — StageAgentsHelper#stage_agent_groups reads the event,
  # not this. This stays for callers that store the pair on the task itself.
  # Old-flow tasks that predate the two-senior model have none → empty list.
  def reviewers
    self.class.normalize_reviewers(metadata["reviewers"])
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

  # Normalize a raw reviewers payload — from EITHER the submitted→reviewed
  # TaskEvent's metadata["reviewers"] (the canonical write target, see
  # #stage_event_metadata) OR a Task's own metadata["reviewers"] — into uniform
  # `{ "slug" =>, "weight" => "heavy"|"light"|nil }` entries. Accepts a list of
  # slug strings or of hashes, and tolerates the agent_slug/review_weight/depth
  # aliases (review_weight is the per-agent key the souls seed + ReviewerSelector
  # use), so the writer's exact shape isn't load-bearing. Blank-slug entries drop.
  def self.normalize_reviewers(raw)
    Array(raw).filter_map do |entry|
      if entry.is_a?(Hash)
        slug = (entry["slug"] || entry["agent_slug"]).to_s.strip
        next if slug.blank?

        { "slug" => slug, "weight" => (entry["weight"] || entry["review_weight"] || entry["depth"]).to_s.strip.presence }
      else
        slug = entry.to_s.strip
        next if slug.blank?

        { "slug" => slug, "weight" => nil }
      end
    end
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

  # Append-only audit spine: one TaskEvent per stage that lands. The deterministic
  # fields (from/to/occurred_at/seconds_in_from) are computed here from the same
  # chokepoint that stamps the stage timestamps, so they're server-owned and
  # exact. The optional attribution (actor/model/tokens/cost) rides in on Current —
  # set per-transition by the request layer (web) or the CLI's --actor (defaulted
  # to the mover's own session in bin/task) for the move it just performed — and is
  # null for model-method and conductor transitions. actor is intentionally NOT
  # backfilled from devops_session_id: that's the session that CLAIMED the task at
  # `building`, so inheriting it would mis-attribute later reviewed/assembled/
  # shipped moves to the build agent. Runs inside the save transaction so a stage
  # change can never land without its event.
  def record_genesis_event
    write_stage_event(from: nil)
  end

  def record_transition_event
    write_stage_event(from: stage_before_last_save)
  end

  def write_stage_event(from:)
    occurred = Time.current
    previous = task_events.chronological.last
    task_events.create!(
      from_stage: from,
      to_stage: stage,
      occurred_at: occurred,
      seconds_in_from: previous && (occurred - previous.occurred_at).round,
      source: Current.task_event_source,
      actor: Current.task_event_actor.presence,
      model: Current.task_event_model.presence,
      tokens_in: Current.task_event_tokens_in,
      tokens_out: Current.task_event_tokens_out,
      cost: Current.task_event_cost,
      metadata: stage_event_metadata(from: from)
    )
  end

  # Extra, non-spine event metadata. On the submitted→reviewed transition this
  # carries the TWO reviewers (+ heavy/light) so the avatars UI can render WHO
  # reviewed — the single `actor` stays the primary mover. Every other transition
  # records the column default ({}). An explicit Current.task_event_reviewers
  # (set when Avi curated the pair) wins; otherwise the pair is selected here via
  # ReviewerSelector, so the avatars populate no matter who drove the move. It
  # NEVER blocks the stage change: a selection error is logged and the event
  # records no reviewers (graceful degradation).
  def stage_event_metadata(from:)
    return {} unless from == "submitted" && stage == "reviewed"

    reviewers = Current.task_event_reviewers.presence || ReviewerSelector.select(self)
    reviewers.present? ? { "reviewers" => reviewers } : {}
  rescue StandardError => e
    Rails.logger.warn("[reviewer-selector] recording failed (non-fatal): #{e.class}: #{e.message}")
    {}
  end

  def set_stage_timestamp
    case stage
    when "building"
      self.started_at = Time.current
      stamp_builder
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

  # A soul SLUG is a short human handle (carl, alex-docs) — lowercase letters with
  # optional internal hyphens, NO digits. That format distinguishes it from a
  # session id (the UUID `bin/task move <slug> building` defaults the actor to,
  # which always carries digits), so the check needs no Agent-table lookup and
  # works before the reviewer souls are seeded.
  SOUL_SLUG = /\A[a-z]+(?:-[a-z]+)*\z/

  # Stamp WHO built this task onto devops.built_by — the soul the reviewer pool
  # later excludes (ReviewerSelector) so a soul never reviews their own work. The
  # value MUST be a soul SLUG to match the soul-keyed pool. The build-claim actor
  # (Current.task_event_actor) is a soul slug ONLY when the move passed
  # --actor <soul> (the real build path); a bare `bin/task move <slug> building`
  # DEFAULTS the actor to the session id (a UUID), which is NOT a soul and would
  # never match the pool — stamping it would make the audit name a builder that
  # can't be excluded (the feature no-ops while the log lies). So stamp the actor
  # only when it's a soul slug; a session id / non-soul actor stamps NOTHING and
  # exclusion degrades to domain-only (truthful). A no-actor move (model method /
  # conductor) and an unresolvable actor both leave any existing built_by
  # untouched — never clobbered to nil. A rework re-claim by a different soul
  # re-points it. Runs inside set_stage_timestamp (a before-save), so the new
  # metadata persists in the same UPDATE as the stage change.
  def stamp_builder
    soul = Current.task_event_actor.presence
    return unless soul&.match?(SOUL_SLUG)

    merged = metadata.deep_dup
    (merged["devops"] ||= {})["built_by"] = soul.to_s
    self.metadata = merged
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

  # Give every new task a Pokémon mascot — a fun, unique, traitless handle for the
  # session working it ("Snorlax is building <task>"). Idempotent: an explicit
  # mascot (the --mascot override) is left alone. Unique among live tasks; the draw
  # recycles a Pokémon once its task ships or is archived. No-ops gracefully when
  # the deck isn't seeded (or the table doesn't exist yet) so task creation never
  # depends on Pokémon being present.
  def sync_session_mascot
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    sid = devops["session_id"].to_s
    # Reassign only when there's no mascot yet, or this session differs from the one
    # the current mascot belongs to (an agent handoff). A session-less task keeps it.
    needs = devops["mascot"].blank? || (sid.present? && devops["mascot_session"].to_s != sid)
    return unless needs

    slug = session_mascot_slug(sid)
    return unless slug
    devops["mascot"] = slug
    devops["mascot_session"] = sid
    # Stamp the mascot's signature type color (its least-common type) so the
    # status line / context JSON can tint the ⊙<mascot> handle without DB access
    # (bin/task and bin/agent-worktree are API clients). nil when the type colors
    # aren't seeded — the status line then falls back to its default tint.
    devops["mascot_color"] = Pokemon.find_by(slug: slug)&.signature_color
  end

  # The Pokémon for a session: reuse the one its other LIVE tasks already carry (so
  # every task an agent builds shares its handle), else draw a fresh one — unique
  # among live sessions. With no session, draw a one-off so the task isn't mascot-less.
  def session_mascot_slug(sid)
    if sid.present?
      peer = Task.live.detect do |t|
        t.id != id && t.metadata&.dig("devops", "session_id").to_s == sid &&
          t.metadata&.dig("devops", "mascot").present?
      end
      return peer.metadata.dig("devops", "mascot") if peer
    end
    Pokemon.draw(exclude: Task.active_mascots)&.slug
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
