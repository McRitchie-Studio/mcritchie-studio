class Task < ApplicationRecord
  SIZES = %w[small medium large xl].freeze

  # --- Auto-derived actual_size (the "what it really cost" leg of the trio) ---
  # The size trio is: po_size (Avi's estimate at creation), dev_size (the builder
  # Pokémon's estimate at claim), and actual_size — the MEASURED outcome, derived
  # at ship from the task's real usage. po/dev are forecasts; actual is the ground
  # truth that scores them on the intelligence dashboard.
  #
  # SIGNAL: total tokens. We sum tokens_total across the task's TaskEvents — the
  # measured spine of work the agents actually burned across every stage. Tokens
  # (not cost, not wall-clock duration) is the cleanest size proxy: cost is just
  # tokens × a model's per-token price (so it tracks model choice, not work
  # volume), and duration is dominated by handoff/idle gaps between stages
  # (wall-clock, not effort). Tokens measure the work itself. Cost and
  # created_at→completed_at duration are both available on the record if a future
  # calibration wants to factor them; tokens stay the single, tunable signal here.
  #
  # THRESHOLDS: size → the EXCLUSIVE upper bound (in total tokens) of that bucket;
  # a task lands in the first bucket whose ceiling its token total falls under.
  # These are deliberately ROUND starting points — the seed board carries no
  # measured token usage yet, so they can't be fit to data; they're meant to be
  # re-tuned once real shipped tasks accumulate a token distribution. Kept in one
  # constant map so that re-tuning is a one-line edit.
  ACTUAL_SIZE_THRESHOLDS = {
    "small"  => 1_000_000,   # < 1M tokens  — a quick, contained change
    "medium" => 5_000_000,   # < 5M tokens  — a normal feature
    "large"  => 15_000_000,  # < 15M tokens — a heavy, multi-stage build
    "xl"     => Float::INFINITY # ≥ 15M tokens — an epic
  }.freeze

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
  # The ACTIVE (gerund) form of each stage — "what's happening right now" — for UI
  # that shows a stage still UNDERWAY, where the past-tense noun reads wrong: a card
  # for the assembled stage in progress says "Assembling", not "Assembled". First
  # use is the /tasks/:id live timeline card; kept beside STAGE_LABELS so other
  # surfaces can share it. Use Task.active_stage_label for a safe fallback.
  STAGE_ACTIVE_LABELS = {
    "designed"  => "Designing",
    "building"  => "Building",
    "submitted" => "Submitting",
    "reviewed"  => "Reviewing",
    "assembled" => "Assembling",
    "shipped"   => "Shipping",
    "blocked"   => "Blocking",
    "archived"  => "Archiving"
  }.freeze
  STAGES = STAGE_LABELS.keys.freeze
  # The two workflows, split at the `submitted` seam (which belongs to both):
  # Build is the feature agent's, Deploy is DevOps's.
  BUILD_STAGES  = %w[designed building submitted].freeze
  DEPLOY_STAGES = %w[submitted reviewed assembled shipped].freeze
  NEXT_INTENT_STAGE = { "designed" => "building", "building" => "submitted",
                        "submitted" => "reviewed", "reviewed" => "assembled",
                        "assembled" => "shipped" }.freeze
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
    persona
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
  # Persona BEFORE the Pokémon draw: when a session "acts as" a soul (devops.persona),
  # stamp the agent's name/color/emoji as the mascot and skip the Pokémon entirely.
  before_validation :sync_persona_identity, on: :create
  before_validation :sync_session_mascot, on: :create
  # Stamp the app's status-line tint (App#color) from the first repository, so
  # bin/statusline can color the app slug without DB access. Cheap, idempotent.
  before_validation :sync_app_identity, on: :create
  before_create :set_initial_position
  before_save :set_stage_timestamp, if: :stage_changed?
  # Per-session mascot: re-derive on each build-phase transition (designed/building/
  # submitted) so a task picked up by a DIFFERENT agent swaps to that session's Pokémon.
  before_save :sync_persona_identity
  before_save :sync_session_mascot, if: -> { will_save_change_to_stage? && Task::BUILD_STAGES.include?(stage) }
  before_save :sync_app_identity
  # One TaskEvent per save that lands a stage: the genesis on create (the default
  # "designed" stage isn't a dirty change, so this is guard-free) and one per real
  # transition on update.
  after_create :record_genesis_event
  after_update :record_transition_event, if: :saved_change_to_stage?
  # When a task lands in `shipped`, stamp actual_size from its MEASURED usage.
  # Registered AFTER record_transition_event so the shipping transition's own
  # TaskEvent is already on the spine and counted in the token total. See
  # #autoderive_actual_size — it only fills a BLANK actual_size (never clobbers a
  # manual size) and never unwinds the ship if derivation fails.
  after_update :autoderive_actual_size, if: :saved_change_to_stage?
  # A destroy fires no TaskEvent, so the live /deployments board never hears about
  # it — broadcast the card removal explicitly so every viewer's board drops it.
  after_destroy_commit :broadcast_removal_to_deployments_board

  def to_param
    slug
  end

  scope :by_stage, ->(stage) { where(stage: stage) }
  scope :blocked, -> { where(stage: "blocked") }
  scope :recent, -> { order(created_at: :desc) }
  # Board order: highest `position` first, so the freshest task in a column sits
  # on top. `position` is an event-driven RANK — a create or a stage move stamps
  # it to (column max + 100), floating that task to the top (see
  # set_initial_position / set_stage_timestamp). The 100-gaps leave room for a
  # drag-drop reorder to slot a card between two others without renumbering. This
  # mirrors the News/Content rank scheme (which Task previously inverted).
  scope :ordered, -> { order(Arel.sql("position DESC NULLS LAST, created_at DESC")) }
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
      pokemon = Pokemon.find_by(slug: slug)
      d["mascot_color"] = pokemon&.signature_color
      d["mascot_emoji"] = pokemon&.type_emoji.presence
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

  # The soul who BUILT this task — stamped on the move to `building` (see
  # #stamp_builder) so the reviewer pool can exclude the builder (a soul shouldn't
  # review their own work). Source precedence: an explicit soul-slug build-claim
  # actor (`--actor <soul>`), else the task's assigned agent_slug — so a bare
  # `bin/task move <slug> building` records the assigned builder WITHOUT a manual
  # flag. nil only when neither resolves to a soul (no soul actor AND a blank /
  # non-soul agent_slug). ReviewerSelector also falls back to the `→ building`
  # TaskEvent actor when this scalar is blank.
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
  # half's review step), each `{ "slug" => ..., "weight" => "primary"|"light" }`
  # (legacy intents recorded before the rename still read "heavy" — treated as
  # "primary"),
  # read off THIS task's own `metadata["reviewers"]`. NOTE: the canonical write
  # target for the avatars UI is the submitted→reviewed TaskEvent's metadata (see
  # #stage_event_metadata) — StageAgentsHelper#stage_agent_groups reads the event,
  # not this. This stays for callers that store the pair on the task itself.
  # Old-flow tasks that predate the two-senior model have none → empty list.
  def reviewers
    self.class.normalize_reviewers(metadata["reviewers"])
  end

  # Record an INTENT: an agent (or the two-senior review pair) STARTING the work
  # that will produce `to_stage`, the moment that work begins — so the board and
  # the task timeline can show WHO is on it with a live ticker before the
  # transition lands. Appends a TaskEvent(kind: intent) FROM the current stage TO
  # to_stage, carrying `actor` (a single owner — Steffon at QA, Avi at ship)
  # and/or `reviewers` metadata (the primary/light pair at review). Append-only +
  # current-cycle scoped: only the current stage's immediate next target is
  # recordable; an identical open intent (same target + same crew) is returned
  # as-is rather than stacked; and it is a no-op once to_stage has landed in the
  # current stage cycle. If rework sends a task back to `submitted`, a fresh
  # `→reviewed` intent can open for that new cycle.
  #
  # An intent row is intentionally USAGELESS — it marks work STARTING, not a
  # completed transition, so it carries no model/tokens/cost. The work the agent
  # burns between an intent and its transition is captured on the TRANSITION
  # event instead: the intent SEEDS the per-session usage baseline (bin/task
  # intent / bin/reviewer-select), and the later move/flip records the delta.
  #
  # `qa: true` marks the Steffon assembled-QA intent (see
  # Release::Conductor#record_qa_intent): in the standard flow the merge already
  # flipped the member to `assembled`, so the QA intent rides toward `shipped`
  # (superseded by the SHIP, not the merge) and is distinguished from Avi's ship
  # intent — same target — by this marker. Idempotency therefore matches on the
  # FULL identity (target + actor + reviewers + qa), not merely the last intent for
  # the target, so two distinct open intents toward the same stage never collide.
  def record_intent_event(to_stage:, actor: nil, reviewers: nil, source: nil, qa: false)
    to_stage = to_stage.to_s
    return nil unless NEXT_INTENT_STAGE[stage] == to_stage
    return nil if target_landed_in_current_stage?(to_stage)

    pair  = reviewers.present? ? self.class.normalize_reviewers(reviewers).presence : nil
    actor = actor.to_s.strip.presence
    qa    = !!qa

    existing = open_intents_for(to_stage).reverse.find do |e|
      e.actor == actor &&
        self.class.normalize_reviewers(e.metadata["reviewers"]).presence == pair &&
        !!e.metadata["qa"] == qa
    end
    return existing if existing

    metadata = {}
    metadata["reviewers"] = pair if pair
    metadata["qa"] = true if qa

    task_events.create!(
      kind: TaskEvent::INTENT,
      from_stage: stage,
      to_stage: to_stage,
      occurred_at: Time.current,
      seconds_in_from: nil,
      source: (source.presence || Current.task_event_source).presence,
      actor: actor,
      metadata: metadata
    )
  end

  # The OPEN intent event for `to_stage` (work has STARTED toward that stage but no
  # later transition into it has landed yet), or nil once it's resolved by a
  # transition — so a non-nil result means "work is in progress on this stage right
  # now". Scope is cycle-aware: if QA blocks a task and it re-enters `submitted`,
  # old review intents from the prior submitted cycle are closed even if no
  # `→reviewed` transition ever landed, and a fresh review intent can open.
  def open_intent_for(to_stage)
    open_intents_for(to_stage).last
  end

  def open_intents_for(to_stage)
    to_stage = to_stage.to_s
    return [] unless NEXT_INTENT_STAGE[stage] == to_stage

    task_events.intents.where(to_stage: to_stage).chronological.to_a.reject do |intent|
      !intent_started_in_current_stage?(intent) || intent_superseded?(intent)
    end
  end

  # The reviewer pair (normalized) recorded on the latest review intent, or nil —
  # ties the completed →reviewed event back to the pair that actually started.
  def latest_intent_reviewers(to_stage = "reviewed")
    intent = task_events.intents.where(to_stage: to_stage).chronological.last
    intent && self.class.normalize_reviewers(intent.metadata["reviewers"]).presence
  end

  # Has the target transition already landed in the task's CURRENT stage cycle?
  # This keeps retries idempotent after the target lands, while still allowing a
  # reworked task to re-enter `submitted` and open a second `→reviewed` intent.
  def target_landed_in_current_stage?(to_stage)
    entry = current_stage_entry_event
    landed = task_events.transitions.where(to_stage: to_stage)
    return landed.exists? if entry.nil?

    landed.where(
      "occurred_at > ? OR (occurred_at = ? AND id >= ?)",
      entry.occurred_at, entry.occurred_at, entry.id
    ).exists?
  end

  def current_stage_entry_event
    task_events.transitions.where(to_stage: stage).chronological.last
  end

  def intent_started_in_current_stage?(intent)
    return false unless intent.from_stage == stage

    entry = current_stage_entry_event
    return true if entry.nil?

    intent.occurred_at > entry.occurred_at ||
      (intent.occurred_at == entry.occurred_at && intent.id.to_i >= entry.id.to_i)
  end

  def intent_superseded?(intent)
    # An intent is live only while the task remains in its source-stage cycle.
    # It closes when the target lands OR when any later transition leaves the
    # source stage (direct QA block, archive, etc.).
    task_events.transitions.where(
      "(to_stage = :target OR from_stage = :source) AND " \
        "(occurred_at > :occurred_at OR (occurred_at = :occurred_at AND id > :id))",
      target: intent.to_stage,
      source: intent.from_stage,
      occurred_at: intent.occurred_at,
      id: intent.id
    ).exists?
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

  # The active (gerund) label for a stage — e.g. "Assembling" for `assembled` —
  # for UI showing that stage still in progress. Falls back to the noun label,
  # then a humanized key, so an unknown stage never blanks out.
  def self.active_stage_label(stage)
    STAGE_ACTIVE_LABELS[stage] || STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  # The MEASURED total tokens for this task — the sum of tokens_total across every
  # TaskEvent on its spine (a missing token field counts as 0). The size signal
  # behind #derive_actual_size. Computed in SQL off a fresh relation so it never
  # reads a stale loaded-association cache mid-transaction.
  def measured_tokens_total
    TaskEvent.where(task_slug: slug)
             .sum(Arel.sql("COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)"))
  end

  # The MEASURED total cost for this task — the sum of `cost` (USD) across every
  # TaskEvent on its spine. SQL SUM ignores NULL costs, so an unpriced event
  # counts as 0; returns a BigDecimal, and 0 when the task has no events. Computed
  # in SQL off a fresh relation (like #measured_tokens_total) so it never reads a
  # stale loaded-association cache mid-transaction. Powers the release-notes card.
  def total_cost
    TaskEvent.where(task_slug: slug).sum(:cost)
  end

  # The actual_size this task's measured usage maps to via ACTUAL_SIZE_THRESHOLDS,
  # or nil when there's NO measured usage (zero tokens) — an honest "can't size it"
  # rather than a misleading "small" for a task whose usage was simply never
  # captured. Pure (no writes): callers decide whether to persist it.
  def derive_actual_size
    tokens = measured_tokens_total
    return nil if tokens.zero?

    ACTUAL_SIZE_THRESHOLDS.find { |_size, ceiling| tokens < ceiling }&.first
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
  # `{ "slug" =>, "weight" => "primary"|"light"|nil }` entries. The weight is
  # passed through verbatim (role-agnostic), so a legacy "heavy" record still
  # normalizes — the UI maps it back to "primary" at render (StageAgent#role_label).
  # Accepts a list of slug strings or of hashes, and tolerates the
  # agent_slug/review_weight/depth aliases (review_weight is the per-agent key the
  # souls seed + ReviewerSelector use), so the writer's exact shape isn't
  # load-bearing. Blank-slug entries drop.
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
  # The genesis (Created→Designed) event is intentionally USAGELESS: it fires
  # inside Task.create — before any session/usage context exists (no build claim,
  # no transcript, no Current.task_event_*) — so it can only ever carry the
  # deterministic spine. This is correct by design, NOT a capture gap: the
  # timeline renders genesis without model/token/cost chips, and the usage
  # backfill (lib/tasks/task_events.rake) leaves it alone.
  def record_genesis_event
    write_stage_event(from: nil)
  end

  # Drop this task's card from the live /deployments board for every viewer.
  def broadcast_removal_to_deployments_board
    DeploymentsBroadcaster.task_removed(slug)
  end

  def record_transition_event
    write_stage_event(from: stage_before_last_save)
  end

  # Stamp actual_size from the task's measured usage the moment it ships — closing
  # the size trio (po/dev forecasts vs. the measured actual). Only fills a BLANK
  # actual_size, so a manually set size (the /sizing editor) is never clobbered;
  # only persists a real derivation (a no-usage task derives nil → left blank).
  # Writes via update_column to skip the callback chain (no re-entrancy). The
  # rescue is INTENTIONALLY swallow-and-log, not re-raise: this runs inside the
  # ship transition, so a derivation bug must degrade to "no auto-size" rather
  # than roll the ship back (mirrors stage_event_metadata + backfill_mascots!).
  def autoderive_actual_size
    return unless stage == "shipped"
    return if actual_size.present?

    size = derive_actual_size
    return if size.blank?

    update_column(:actual_size, size) # rubocop:disable Rails/SkipsModelValidations
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  def write_stage_event(from:)
    occurred = Time.current
    # Measure the stage duration between TRANSITIONS only — an intent row recorded
    # mid-stage (review picked, QA started) is the live "who's on it" signal, not a
    # stage boundary, so it must never shorten seconds_in_from.
    previous = task_events.transitions.chronological.last
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
      # Merge the review-bypass marker (set only by Conductor.adopt!(override:true)
      # for `bin/release merge --override`) onto THIS transition, so the review-gate
      # skip is recorded on the same spine the move writes — not as a second, orphan
      # event. Absent on every normal move (Current flag nil), so it never widens the
      # default metadata.
      metadata: stage_event_metadata(from: from).merge(
        Current.task_event_review_bypass ? { "review_bypassed" => true } : {}
      )
    )
  end

  # Extra, non-spine event metadata. Build-lane transitions snapshot the mascot
  # that owned THAT event, so a later rework handoff can repaint the current task
  # mascot without rewriting history. On the submitted→reviewed transition this
  # also carries the TWO reviewers (+ primary/light) so the avatars UI can render
  # WHO reviewed — the single `actor` stays the primary mover. An explicit
  # Current.task_event_reviewers (set when Avi curated the pair) wins; otherwise
  # the pair is selected here via ReviewerSelector, so the avatars populate no
  # matter who drove the move. It NEVER blocks the stage change: a selection error
  # is logged and the event records the metadata gathered so far.
  def stage_event_metadata(from:)
    metadata = stage_mascot_event_metadata
    return metadata unless from == "submitted" && stage == "reviewed"

    # Prefer the pair that actually STARTED the review (stamped on the open review
    # intent) so the completed event shows the same two seniors the board showed
    # ticking; an explicit Current override (Avi curated on the move) still wins,
    # and an old-flow move with neither falls back to a fresh selection.
    reviewers = Current.task_event_reviewers.presence ||
                latest_intent_reviewers("reviewed") ||
                ReviewerSelector.select(self)
    reviewers.present? ? metadata.merge("reviewers" => reviewers) : metadata
  rescue StandardError => e
    Rails.logger.warn("[reviewer-selector] recording failed (non-fatal): #{e.class}: #{e.message}")
    metadata || {}
  end

  def stage_mascot_event_metadata
    return {} unless Task::BUILD_STAGES.include?(stage)

    slug = devops["mascot"].presence
    return {} unless slug

    pokemon = Pokemon.find_by(slug: slug) if Pokemon.table_exists?
    snapshot = {
      "slug" => slug,
      "name" => pokemon&.name.presence || slug,
      "avatar" => pokemon&.display_avatar.presence,
      "color" => devops["mascot_color"].presence || pokemon&.signature_color.presence,
      "emoji" => devops["mascot_emoji"].presence
    }.compact

    { "mascot" => snapshot }
  rescue StandardError => e
    Rails.logger.warn("[task-event-mascot] recording failed (non-fatal): #{e.class}: #{e.message}")
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
    # Re-rank to the TOP of the new column on every stage move: max + 100 wins the
    # `position DESC` sort. The 100-gap keeps room for later drag inserts. (Skip on
    # create — set_initial_position seeds the genesis rank.)
    self.position = (Task.where(stage: stage).maximum(:position) || 0) + 100 unless new_record?
  end

  # A soul SLUG is a short human handle (carl, shannon) — lowercase letters with
  # optional internal hyphens, NO digits. That format distinguishes it from a
  # session id (the UUID `bin/task move <slug> building` defaults the actor to,
  # which always carries digits), so the check needs no Agent-table lookup and
  # works before the reviewer souls are seeded.
  SOUL_SLUG = /\A[a-z]+(?:-[a-z]+)*\z/

  # Stamp WHO built this task onto devops.built_by — the soul the reviewer pool
  # later excludes (ReviewerSelector) so a soul never reviews their own work. The
  # value MUST be a soul SLUG to match the soul-keyed pool. Resolved by
  # #builder_to_stamp (precedence below); nil leaves any existing built_by
  # untouched — never clobbered. Runs inside set_stage_timestamp (a before-save),
  # so the new metadata persists in the same UPDATE as the stage change.
  def stamp_builder
    soul = builder_to_stamp
    return if soul.nil?

    merged = metadata.deep_dup
    (merged["devops"] ||= {})["built_by"] = soul
    self.metadata = merged
  end

  # The soul to record as the builder, or nil to leave built_by as-is. Precedence:
  #   1. The build-claim actor (Current.task_event_actor) when it's a soul SLUG —
  #      an explicit `--actor <soul>` move (or a web action by a soul). This always
  #      wins, so a rework re-claim by a different soul RE-POINTS built_by.
  #   2. else KEEP an existing built_by — a no-actor / non-soul re-claim never
  #      clobbers a recorded builder (only an explicit --actor re-points it).
  #   3. else the task's assigned agent_slug when it's a soul SLUG — the automatic,
  #      no-flag default. A bare `bin/task move <slug> building` defaults the actor
  #      to the session id (a UUID, not a soul), so rule 1 can't fire; backing the
  #      stamp with the assigned agent records the builder WITHOUT the operator
  #      passing a flag every time (the FIX behind reviewer-select-exclude). The
  #      assignee fills only a BLANK built_by (rule 2 guards re-claims).
  # nil when none apply (non-soul actor, no existing builder, non-soul/blank
  # agent_slug) — exclusion then degrades to domain-only (truthful).
  def builder_to_stamp
    actor = Current.task_event_actor.presence
    return actor if actor&.match?(SOUL_SLUG)
    return nil if devops["built_by"].present?

    assigned = agent_slug.to_s
    assigned.match?(SOUL_SLUG) ? assigned : nil
  end

  def set_initial_position
    # A new task lands at the TOP of its (designed) column: max + 100 under the
    # `position DESC` sort. 100-spacing mirrors News/Content and leaves drag gaps.
    self.position ||= (Task.where(stage: stage).maximum(:position) || 0) + 100
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
    # A persona (acting as a soul) owns the mascot fields — never overwrite it with
    # a Pokémon. sync_persona_identity has already stamped the agent's identity.
    return if devops["persona"].to_s.strip.present?
    sid = devops["session_id"].to_s
    # Reassign only when there's no mascot yet, or this session differs from the one
    # the current mascot belongs to (an agent handoff). A session-less task keeps it.
    needs = devops["mascot"].blank? || (sid.present? && devops["mascot_session"].to_s != sid)
    return unless needs

    slug = session_mascot_slug(sid)
    return unless slug
    devops["mascot"] = slug
    devops["mascot_session"] = sid
    # Stamp the mascot's signature type color (its least-common type) AND its type
    # emoji(s) so the status line / context JSON can tint and glyph the ⊙<mascot>
    # handle without DB access (bin/task and bin/agent-worktree are API clients).
    # nil/blank when the type colors aren't seeded — the status line then falls
    # back to its default tint and the 🛠 ⊙ glyphs.
    pokemon = Pokemon.find_by(slug: slug)
    devops["mascot_color"] = pokemon&.signature_color
    devops["mascot_emoji"] = pokemon&.type_emoji.presence
  end

  # Persona override: when a task carries devops.persona (an agent slug — "act as
  # Jasper"), the status-line mascot becomes that SOUL (name + glyph + tint) instead
  # of the session's Pokémon. Idempotent and re-stamped on every save so it survives
  # the client's read-modify-write (mascot_color/emoji aren't client keys). An
  # unknown/blank persona is a no-op, leaving the Pokémon path to run.
  # Explicit "revert to the session Pokémon" sentinels for devops.persona, so a
  # mid-task `bin/task update <slug> --persona none` drops the soul. Case-insensitive.
  PERSONA_CLEAR = %w[none clear off -].freeze

  def sync_persona_identity
    return unless Agent.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    raw = devops["persona"].to_s.strip
    return if raw.empty?

    agent = Agent.find_by(slug: raw.downcase)
    # Clear (--persona none) OR an unknown soul (a typo): drop the persona AND reset
    # the mascot so the session's Pokémon is (re)drawn. Niling the mascot first is
    # required — on a plain update (no stage change) sync_session_mascot's own
    # before_save guard wouldn't fire, so call it inline to repaint the Pokémon now.
    # (An unknown soul reverting is the right "your persona didn't take" feedback.)
    if PERSONA_CLEAR.include?(raw.downcase) || agent.nil?
      devops.delete("persona")
      devops["mascot"] = nil
      devops["mascot_session"] = nil
      devops["mascot_color"] = nil
      devops["mascot_emoji"] = nil
      sync_session_mascot
      return
    end

    devops["mascot"] = agent.name
    devops["mascot_color"] = agent.status_color
    devops["mascot_emoji"] = agent.emoji
  end

  # Stamp the app's status-line tint from its first repository, so bin/statusline
  # can color the app slug without DB access (it and bin/agent-worktree are API
  # clients). app_color is server-owned (not a DEVOPS_KEY), so it's re-derived each
  # save — never lost to the client's read-modify-write. No-ops when the apps table
  # isn't present or the repo has no App row (the slug then renders in the default tint).
  def sync_app_identity
    return unless App.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    app_slug = self.class.normalize_devops_list(devops["repositories"]).first
    return if app_slug.blank?

    app = App.find_by(slug: app_slug)
    devops["app_color"] = app&.color
  end

  # The Pokémon for a session: ADOPT the session's stable mascot (SessionMascot —
  # drawn eagerly at session start so the status line shows it in seconds, OR
  # drawn here on first task when the hook hasn't run). SessionMascot itself reuses
  # a live peer task's mascot, so every task an agent builds shares its handle.
  # With no session, draw a one-off so the task isn't mascot-less.
  def session_mascot_slug(sid)
    if sid.present?
      mascot = SessionMascot.for(sid)&.mascot_slug
      return mascot if mascot
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
