class Task < ApplicationRecord
  SIZES = %w[small medium large xl].freeze

  # actual_size is the measured leg of the size trio (po_size estimate, dev_size
  # estimate, actual_size outcome), derived at ship from the task's priced cost.
  # Buckets are USD ceilings (exclusive): cost is priced through UsagePricing,
  # while raw token totals are dominated by cache reads. Tune here.
  ACTUAL_SIZE_COST_THRESHOLDS = {
    "small"  => 10.0,   # < $10  — a quick, contained change
    "medium" => 50.0,   # < $50  — a normal feature
    "large"  => 200.0,  # < $200 — a heavy, multi-stage build
    "xl"     => Float::INFINITY # ≥ $200 — an epic
  }.freeze

  # Two-workflow status model; see docs/agents/system/devops-cycle-design.md.
  #   Build:  designed → building → submitted
  #   Deploy: submitted → reviewed → assembled → shipped
  # `blocked` is an attribute of a `building` task (blocked_at, blocked_from,
  # blocked_by, block_kind), not a stage. `archived` is terminal.
  STAGE_LABELS = {
    "designed"  => "Designed",
    "building"  => "Building",
    "submitted" => "Submitted",
    "reviewed"  => "Reviewed",
    "assembled" => "Assembled",
    "shipped"   => "Shipped",
    "archived"  => "Archived"
  }.freeze
  # The active (gerund) form of each stage, for UI showing a stage still underway.
  # Use Task.active_stage_label for a safe fallback.
  STAGE_ACTIVE_LABELS = {
    "designed"  => "Designing",
    "building"  => "Building",
    "submitted" => "Submitting",
    "reviewed"  => "Reviewing",
    "assembled" => "Assembling",
    "shipped"   => "Shipping",
    "archived"  => "Archiving"
  }.freeze
  STAGES = STAGE_LABELS.keys.freeze
  # The two workflows split at `submitted`, which belongs to both.
  BUILD_STAGES  = %w[designed building submitted].freeze
  # The gates where a task's Pokémon evolves one step: the senior review and the
  # QA-green assemble. The value is the evolution stage the gate leaves the mascot
  # at (devops.mascot_stage), which makes a block-and-resubmit loop idempotent.
  # Every line spends its first step at review, so two-form lines reach their final
  # form there and coast through assemble. See #evolve_stage_mascot.
  MASCOT_EVOLUTION_GATES = { "reviewed" => 1, "assembled" => 2 }.freeze
  DEPLOY_STAGES = %w[submitted reviewed assembled shipped].freeze
  NEXT_INTENT_STAGE = { "designed" => "building", "building" => "submitted",
                        "submitted" => "reviewed", "reviewed" => "assembled",
                        "assembled" => "shipped" }.freeze
  # Where the task's code is, orthogonal to `stage`, so an interrupted heartbeat
  # reads durable state instead of guessing:
  #   nil        — not merged anywhere
  #   "accepted" — merged onto accepted by review; Release#add moves it to "release"
  #   "release"  — merged onto the release branch (in QA)
  #   "main"     — fast-forwarded into main
  MERGED_ACCEPTED = "accepted"
  MERGED_RELEASE  = "release"
  MERGED_MAIN     = "main"
  MERGED_STATES   = [MERGED_ACCEPTED, MERGED_RELEASE, MERGED_MAIN].freeze
  # Board columns per page. /tasks is the Build lane (blocked tasks ride Building);
  # /deployments shows the whole pipeline. The Deploy workflow itself stays
  # DEPLOY_STAGES.
  TASKS_BOARD_STAGES       = %w[designed building submitted].freeze
  DEPLOYMENTS_BOARD_STAGES = %w[designed building submitted reviewed assembled shipped].freeze
  # Why a task is blocked (the block_kind column), so a heartbeat routes it.
  BLOCK_KINDS = %w[environment rework dependency].freeze
  REVIEW_ROLES = %w[primary light].freeze
  REVIEW_ROLE_ALIASES = {
    "primary" => "primary",
    "heavy" => "primary",
    "deep" => "primary",
    "heavy_review" => "primary",
    "light" => "light",
    "light_review" => "light"
  }.freeze
  REVIEW_MOMENTS = {
    "primary" => %w[started context diff tests risk findings completed failed],
    "light" => %w[started context diff smoke handoff completed failed]
  }.freeze
  REVIEW_MOMENT_LABELS = {
    "primary" => {
      "started" => "Started deep review",
      "context" => "Loaded task and PR context",
      "diff" => "Audited code diff",
      "tests" => "Checked required test evidence",
      "risk" => "Scanned release and regression risk",
      "findings" => "Prepared findings",
      "completed" => "Completed deep review",
      "failed" => "Reported deep-review blocker"
    },
    "light" => {
      "started" => "Started light review",
      "context" => "Loaded task and PR context",
      "diff" => "Skimmed changed files",
      "smoke" => "Checked targeted smoke path",
      "handoff" => "Checked docs and handoff",
      "completed" => "Completed light review",
      "failed" => "Reported light-review blocker"
    }
  }.freeze
  REVIEW_STATUSES = %w[started completed failed info].freeze
  OPERATOR_APPROVAL_WAITING = "waiting".freeze
  # The stages where a waiting operator-approval request means something: the desk
  # serving its local demo still exists. A desk is reclaimed once merged, which is
  # `reviewed`, so the request settles there on every save
  # (#settle_operator_approval_past_request_window). An allow-list, so a new stage
  # settles by default. A rework block parks the task on `building`, so a request
  # survives a send-back.
  APPROVAL_REQUEST_STAGES = %w[designed building submitted].freeze
  OPERATOR_APPROVAL_APPROVED = "approved".freeze
  OPERATOR_APPROVAL_CHANGES_REQUESTED = "changes_requested".freeze
  # The settled resolution: a waiting request outside APPROVAL_REQUEST_STAGES
  # clears to "none", never "approved", because nobody granted it.
  OPERATOR_APPROVAL_NONE = "none".freeze
  # Every value approval_status may hold; anything else is a 422.
  OPERATOR_APPROVAL_STATUSES = [
    OPERATOR_APPROVAL_WAITING, OPERATOR_APPROVAL_APPROVED,
    OPERATOR_APPROVAL_CHANGES_REQUESTED, OPERATOR_APPROVAL_NONE
  ].freeze
  # Request sources that mean the operator lane. "web" is stamped only by the
  # admin-gated TasksController#update; Api::V1::TasksController clamps a
  # caller-supplied "web" to "api". Attribution only: it gates no approval value.
  OPERATOR_APPROVAL_GRANT_SOURCES = %w[web].freeze
  # Names that live in a top-level column, so a devops write to them raises with
  # the sentence below (both controllers rescue into a 422). Without this,
  # normalize_devops_metadata would skip the key in silence and the column and a
  # same-named key would diverge. A blank value is still skipped.
  DEVOPS_COLUMN_KEYS = {
    "release_slug" => "the tasks.release_slug column — release membership is recorded by the sweep " \
                      "(Release#record_members), never set by hand",
    "release_train" => "the tasks.release_slug column — release membership is recorded by the sweep " \
                       "(Release#record_members), never set by hand",
    "block_kind" => "the tasks.block_kind column — stamped server-side by Task#block! " \
                    "(POST /api/v1/tasks/:slug/block)",
    # `--depends-on` writes the column; #shed_column_shadow_keys drops a value an
    # older write parked under the devops key.
    "dependencies" => "the tasks.dependencies column — set it with " \
                      "`bin/task update <slug> --depends-on <task-slug>` (repeatable)",
    # The epic chip and the `?epic=` filter read the column, never a devops key.
    "epic_slug" => "the tasks.epic_slug column — set it with " \
                   "`bin/task update <slug> --epic <epic-slug>` (`--epic none` clears it)"
  }.freeze
  # Devops keys that also live in an indexed top-level column, because hot paths
  # query them: the board sorts on approval_status, the merged-PR webhook finds a
  # task by pr_url and branch, and the Pokédex finds one by session_id. The JSON
  # key stays the write surface every caller already uses, and
  # #mirror_devops_columns copies each key into its column on every save, so the
  # two never disagree once saved. Each reader takes the column and falls back to
  # the key for a row TaskDevopsColumnsBackfillJob has not reached. Retiring a key
  # means moving its name into DEVOPS_COLUMN_KEYS and dropping the fallback.
  DEVOPS_MIRRORED_KEYS = %w[pr_url branch approval_status session_id].freeze
  DEVOPS_SCALAR_KEYS = %w[
    kind shape worktree_slug branch pr_url local_url qa_url production_url
    requires_release_conductor included_in_release agent_context session_id session_provider mascot
    mascot_session claimed_session claim_nonce claim_expires_at post_deploy_cmd built_by gem_bump
    persona approval_status approval_requested_at approval_requested_by approval_approved_at
    approval_request_dropped_at
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
  # `abandoned_prs` records each PR still open when an operator archived the task
  # with `--force` (lib/open_pr_guard.rb). Never cleared: it separates a dropped
  # PR from a forgotten one.
  # The flag-written keys come from the key map (lib/devops_list_flags.rb).
  DEVOPS_LIST_KEYS = (DevopsListFlags::FLAGS.values + %w[abandoned_prs fix_forward]).freeze
  # List keys whose entries are identifiers, so a comma inside one is a joined list
  # and splits on write in array form too. The key map (lib/devops_list_flags.rb) is
  # the one copy; bin/task refuses the same keys' flags first. Prose keys keep their
  # commas. Normalization runs on write only; #devops_list does not split.
  DEVOPS_IDENTIFIER_LIST_KEYS = DevopsListFlags::IDENTIFIER_KEYS
  # Repo-keyed maps: { "<repo>" => "<value>" }. `pr_urls` holds each repo's PR for a
  # multi-repo task; `pr_url` stays the primary that every reader uses.
  DEVOPS_MAP_KEYS = %w[pr_urls].freeze
  DEVOPS_KEYS = (DEVOPS_SCALAR_KEYS + DEVOPS_LIST_KEYS + DEVOPS_MAP_KEYS).freeze
  # github.com/<owner>/<repo>/pull/<n> → the repo segment.
  PR_URL_REPO_PATTERN = %r{github\.com/[^/]+/([^/]+)/pull/}
  # The shape selects the DoR test contract; config/feature_shapes.yml is the source of truth.
  SHAPES = %w[ui-only ui+db backend library onchain onchain-vertical docs test-only].freeze
  # A task slug as #generate_slug mints one; validates `dependencies` entries
  # (#dependencies_name_real_tasks).
  DEPENDENCY_SLUG = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/
  # An epic slug uses the task-slug charset: the chip prints it and `?epic=` filters
  # on it. There is no Epic model (devops-v3-design.md §3).
  EPIC_SLUG = DEPENDENCY_SLUG
  # The API spelling that clears the epic, matching the CLI's `--epic none`.
  EPIC_CLEAR_VALUE = "none"

  # Board rank from the engine's board primitive: `reposition!`, `board_next_position`,
  # `board_ordered` and the `set_initial_position` seed, ranked per stage column.
  # The `ordered` scope and `set_stage_timestamp` add Task's own rules.
  include Studio::Board::Rankable
  include TaskDerivedFacts

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, optional: true
  belongs_to :release, foreign_key: :release_slug, primary_key: :slug, optional: true, inverse_of: :tasks
  has_many :activities, foreign_key: :task_slug, primary_key: :slug, dependent: :nullify
  # Xan's ship-time grade (Insights::TaskGrader); its lesson lives on as an ActionGrade.
  has_one :task_grade, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :destroy
  has_many :task_events, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :destroy
  has_many :task_transitions, foreign_key: :task_slug, primary_key: :slug,
                              inverse_of: :task, dependent: :destroy
  # Per-action trajectory (AgentAction.capture); nullified so it outlives the task.
  has_many :agent_actions, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :nullify
  has_many :atomic_actions, class_name: "AgentAction", foreign_key: :task_slug, primary_key: :slug
  # Narrated activities (AgentActivity); nullified so they outlive the task.
  has_many :agent_activities, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :nullify
  has_many :atomic_events, class_name: "AgentActivity", foreign_key: :task_slug, primary_key: :slug
  # Runs of the task-owned testing gates (DoR, G2a/G2b review lanes).
  has_many :gate_runs, -> { where(subject_type: "task") },
           foreign_key: :subject_slug, primary_key: :slug, dependent: :delete_all
  # The per-task review claim (TaskReviewClaim): at most one live pr-review session.
  has_one :review_claim, class_name: "TaskReviewClaim",
          foreign_key: :task_slug, primary_key: :slug, dependent: :destroy

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :stage, inclusion: { in: STAGES }
  # `merged` is nil or a known git location; heartbeats read it as ground truth.
  validates :merged, inclusion: { in: MERGED_STATES }, allow_nil: true
  # Naming discipline, gated on change so untouched old tasks still save.
  validate :title_within_word_range, if: :title_changed?
  validate :acceptance_bullets_within_word_range, if: :acceptance_changed?
  # Gated on change: a task must stay saveable after a dependency it named is
  # archived.
  validate :dependencies_name_real_tasks, if: :dependencies_changed?
  # Normalized in #normalize_epic_slug before this runs; a bad slug is a 422.
  validates :epic_slug, format: { with: EPIC_SLUG,
                                  message: "must be a slug — lowercase letters, digits and single " \
                                           "separators (e.g. devops-v3)" },
                        allow_nil: true
  validates :priority, inclusion: { in: [0, 1, 2] }
  validates :pm_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :po_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :dev_size,    inclusion: { in: SIZES }, allow_nil: true
  validates :actual_size, inclusion: { in: SIZES }, allow_nil: true
  # Gated on change, so a legacy row holding an odd value still saves untouched.
  validates :approval_status, inclusion: { in: OPERATOR_APPROVAL_STATUSES,
                                           message: "must be one of #{OPERATOR_APPROVAL_STATUSES.join(", ")}" },
                              allow_nil: true, if: :will_save_change_to_approval_status?
  # The one copy of the block kinds: bin/task sends --kind as typed and this answers
  # a kind it does not know with a 422 naming the list. Gated on change, like the
  # approval status above.
  validates :block_kind, inclusion: { in: BLOCK_KINDS, message: "must be one of #{BLOCK_KINDS.join(", ")}" },
                         allow_nil: true, if: :will_save_change_to_block_kind?
  # bin/release runs devops.post_deploy_cmd VERBATIM against production, and a bare
  # `db:seed` loads every db/seeds/*.rb. Refused on write (guard catalog row 2.8), so
  # bin/dor-check never meets one. Gated on change, so a legacy row still saves.
  validate :post_deploy_cmd_is_not_a_bare_seed, if: :post_deploy_cmd_changed?

  attr_readonly :slug # the readable handle is set once at creation, then immutable

  before_validation :generate_slug, on: :create
  # Every save: dependencies are edited later; normalized before validation reads them.
  before_validation :normalize_dependencies
  # Every save: the epic filter compares the stored column byte for byte.
  before_validation :normalize_epic_slug
  before_validation :default_devops_handles_from_slug, on: :create
  # Persona before the Pokémon draw: a session acting as a soul wears that soul as its mascot.
  before_validation :sync_persona_identity, on: :create
  before_validation :sync_session_mascot, on: :create
  # Derived mascot stamps (shiny, color, emoji) are server-owned. See #sync_mascot_display.
  before_validation :sync_mascot_display, on: :create
  # The app's status-line tint (App#color), from the first repository, for bin/statusline.
  before_validation :sync_app_identity, on: :create
  # Last before validation, so the approval_status inclusion check reads the
  # mirrored column. See #mirror_devops_columns.
  before_validation :mirror_devops_columns
  before_create :set_initial_position
  before_save :set_stage_timestamp, if: :stage_changed?
  # Leaving `building` forward resolves the block, so blocked_at always means
  # "currently blocked".
  before_save :clear_block_on_forward_move, if: -> { will_save_change_to_stage? && stage != "building" }
  # Entering `submitted` releases a previous review's claim, or the resubmission
  # waits out the stale lease. See TaskReviewClaim.release_for_new_submission!.
  after_commit :clear_stale_review_claim_on_submit,
               on: %i[create update],
               if: -> { previous_changes.key?("stage") && stage == "submitted" }
  # #shed_column_shadow_keys enforces DEVOPS_COLUMN_KEYS at the last gate.
  # #restore_mascot_identity runs first of the mascot callbacks: a PATCH that omits
  # the mascot must not trigger a redraw. Then the session mascot re-derives on each
  # build-stage move, so a new agent's session gets its own Pokémon.
  before_save :shed_column_shadow_keys
  before_save :restore_mascot_identity
  before_save :sync_persona_identity
  before_save :sync_session_mascot, if: -> { will_save_change_to_stage? && Task::BUILD_STAGES.include?(stage) }
  # #sync_mascot_display re-asserts the server-owned mascot keys before the
  # evolution gate reads them; a wiped mascot_stage would double-evolve. Evolution
  # runs after the session sync, so the gate evolves the mascot that owns the
  # transition, and before the TaskEvent, so its snapshot holds the evolved form.
  before_save :sync_mascot_display
  before_save :evolve_stage_mascot, if: -> { will_save_change_to_stage? && Task::MASCOT_EVOLUTION_GATES.key?(stage) }
  before_save :sync_app_identity
  # Unconditional: the settle is a stage invariant re-asserted on every save.
  # See #settle_operator_approval_past_request_window.
  before_save :settle_operator_approval_past_request_window
  before_save :stamp_operator_approval_request
  before_save :stamp_operator_approval_approved
  # Cert evidence in devops.checks_run is machine-owned and survives every writer.
  # See #preserve_cert_evidence.
  before_save :preserve_cert_evidence
  # devops.claimed_session: who claimed the build. Stamped on claim, defended,
  # cleared on leaving `building`. See #stamp_build_claim_session.
  before_save :stamp_build_claim_session
  # Who built this belongs to the build claim; registered after the claim stamp so
  # it reads the claimer. See #enforce_builder_stamp.
  before_save :enforce_builder_stamp
  # Last of the before_saves: the approval settles and stamps above rewrite devops
  # keys, and the columns must land on the same UPDATE as the keys they mirror.
  before_save :mirror_devops_columns
  # One TaskEvent per save that lands a stage: the genesis on create, one per transition.
  after_create :record_genesis_event
  after_update :record_transition_event, if: :saved_change_to_stage?
  # On `shipped`, fill a blank actual_size from measured cost. Registered after
  # the transition event so that event is counted; never unwinds the ship.
  after_update :autoderive_actual_size, if: :saved_change_to_stage?
  # After commit, enqueue the ship's grade (devops-v3 §9); grading never slows or
  # rolls back a ship. See #enqueue_task_grading.
  after_commit :enqueue_task_grading, on: :update, if: -> { saved_change_to_stage? && stage == "shipped" }
  after_commit :refresh_duration_metrics_for_release_changes, on: %i[create update destroy]
  after_commit :refresh_testing_phases_after_change, on: %i[create update]
  # Avi sizes a task that enters `designed` without a po_size, async (AviSizingJob)
  # so the build never waits. See #enqueue_avi_sizing_if_designed_unsized.
  after_commit :enqueue_avi_sizing_if_designed_unsized, on: %i[create update]
  # The /deployments app ladder counts tasks by `merged` rung, excluding archived,
  # so it is pushed only when one of those columns moves. Kept out of
  # DeploymentsBroadcaster.release_modules, which pushes only the release slots.
  after_commit :broadcast_app_ladder_if_rung_changed, on: %i[create update destroy]

  # Changing approval_status writes no stage and no TaskEvent, so push the card
  # when the value actually changes.
  after_update_commit :broadcast_operator_approval_change, if: :saved_change_to_approval_status?
  # The settle at `reviewed` leaves a note for whoever set the request. After
  # commit and rescued: surface it, never block the move.
  # See #record_unanswered_approval_request.
  after_commit :record_unanswered_approval_request, on: %i[create update], if: -> { @settled_approval_request }
  # Task#block! records no TaskEvent, so push the card on a block or unblock.
  # blocked_at moves in both directions, so one guard covers both.
  after_update_commit :broadcast_block_change, if: :saved_change_to_blocked_at?
  # A destroy fires no TaskEvent, so broadcast the card removal.
  after_destroy_commit :broadcast_removal_to_deployments_board

  def to_param
    slug
  end

  # `blocked` is an attribute, not a stage, so `--stage blocked` routes through the
  # `blocked` scope rather than returning nothing.
  scope :by_stage, ->(stage) { stage.to_s == "blocked" ? blocked : where(stage: stage) }
  # A live block: a `building` task with blocked_at set. blocked_at persists as
  # history, so the stage guard keeps this to current blocks.
  scope :blocked, -> { where(stage: "building").where.not(blocked_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
  # The epic filter for both boards and the API (`?epic=<slug>`), normalized by the
  # column's own rule. A blank or bad value yields an empty scope, never the board.
  scope :for_epic, ->(value) {
    normalized = Task.normalize_epic_slug(value)
    normalized ? where(epic_slug: normalized) : none
  }
  # Board order: waiting approvals first, then highest `position`. A create or a
  # stage move stamps position to column max + 100, floating the card to the top;
  # the gaps let a drag slot a card between two others.
  scope :ordered, -> {
    order(Arel.sql(
      "CASE WHEN tasks.approval_status = '#{OPERATOR_APPROVAL_WAITING}' THEN 1 ELSE 0 END DESC, " \
        "position DESC NULLS LAST, created_at DESC"
    ))
  }
  scope :requires_migration, -> { where(requires_migration: true) }
  # Everything but shipped and archived: a live task's mascot is taken, and this is
  # the WIP metric (.wip_count).
  scope :live, -> { where.not(stage: %w[shipped archived]) }
  # Submitted tasks not under a live review claim, as one server-side NOT EXISTS
  # query so parallel pr-review sessions pop in one round trip. A NULL or past
  # claim_expires_at is reviewable; only a future expiry excludes.
  scope :reviewable, ->(now: Time.current) {
    by_stage("submitted").where(
      "NOT EXISTS (SELECT 1 FROM task_review_claims trc " \
      "WHERE trc.task_slug = tasks.slug AND trc.claim_expires_at > ?)", now
    )
  }

  # The verdict of an atomic review pop. `task` is nil when nothing was claimed;
  # `reason` is "claimed", "none_reviewable" or "no_green_ci". Two reporting-only
  # fields: `blind_repos` names skipped repos with no ingested CI at all, and
  # `skipped_ci` gives each skipped candidate's board CI state and head SHA, since
  # the pop reads ingested runs (Ci::ReviewGate) while dor-check reads `gh` live.
  ClaimNextResult = Struct.new(:task, :outcome, :reason, :blind_repos, :skipped_ci, keyword_init: true) do
    def claimed?
      task.present?
    end

    # Always an Array: older callers pass no value.
    def blind_repo_list
      Array(blind_repos)
    end

    def skipped_ci_list
      Array(skipped_ci)
    end
  end

  # The atomic review pop (relocate-review-selection-to-server): claim the top
  # reviewable task with green CI. Per candidate, in its own short transaction:
  #   1. re-select `FOR UPDATE SKIP LOCKED`, so a racer skips to the next row;
  #   2. Ci::ReviewGate.green? over every repo with a PR; non-green is skipped;
  #   3. TaskReviewClaim.acquire, whose claim-row lock picks the final winner.
  # `ci_status` is the test seam (`{ slug => token }` or one token for all);
  # production passes nil.
  def self.claim_next_review(session:, nonce:, label: nil, reviewer: nil, now: Time.current, ci_status: nil)
    ordered_slugs = reviewable(now: now).ordered.pluck(:slug)
    return ClaimNextResult.new(task: nil, outcome: nil, reason: "none_reviewable") if ordered_slugs.empty?

    skipped_ungreen = false
    skipped_repos = []
    skipped_ci = []
    ordered_slugs.each do |slug|
      claimed = transaction do
        task = reviewable(now: now).where(slug: slug).lock("FOR UPDATE SKIP LOCKED").first
        next nil unless task # locked by a concurrent caller, or claimed since the pluck

        token = ci_status_token(ci_status, slug)
        unless Ci::ReviewGate.green?(task, injected: token)
          skipped_ungreen = true
          # Every repo the skipped task has a PR in, so an unwired second repo is reported.
          skipped_repos.concat(Ci::ReviewGate.repos_for(task))
          # The same token the gate judged on, so the report explains this skip.
          skipped_ci << ci_report_for(task, slug, token)
          next nil # red / pending / ci-less / none — never claim a non-green PR
        end

        outcome = TaskReviewClaim.acquire(task_slug: slug, session: session, nonce: nonce, label: label,
                                          reviewer: reviewer, now: now)
        next nil unless outcome.acquired # claim held by a racer — skip to the next

        ClaimNextResult.new(task: task, outcome: outcome, reason: "claimed")
      end
      return claimed if claimed
    end

    ClaimNextResult.new(task: nil, outcome: nil, reason: skipped_ungreen ? "no_green_ci" : "none_reviewable",
                        blind_repos: blind_repos_among(skipped_repos), skipped_ci: skipped_ci)
  end

  # What the board holds for one skipped candidate, for reporting only. It runs on
  # the refusal path inside the pop's transaction, so any error degrades to
  # "unreadable" rather than failing the pop.
  def self.ci_report_for(task, slug, injected = nil)
    verdict = Ci::ReviewGate.verdict(task, injected: injected)
    { "slug" => slug,
      "state" => verdict[:state].to_s,
      "sha" => verdict[:sha].to_s[0, 12],
      "repo" => verdict[:repo].to_s }
  rescue StandardError => e
    { "slug" => slug, "state" => "unreadable", "sha" => "", "repo" => e.class.name }
  end

  # The skipped repos that deliver no CI to the board at all; reporting only, so an
  # error degrades to none.
  def self.blind_repos_among(repos)
    return [] if repos.blank?

    Ci::Ingestion.unwired(repos)
  rescue StandardError => e
    ErrorLog.capture!(e)
    []
  end

  # The injected CI verdict for one slug: a Hash lookup, one token for all, or nil.
  def self.ci_status_token(injection, slug)
    return nil if injection.nil?
    return injection[slug] || injection[slug.to_sym] if injection.is_a?(Hash)

    injection
  end

  # The tasks in a board column; blocked tasks are building tasks.
  def self.board_column_tasks(tasks_by_stage, stage)
    Array((tasks_by_stage || {})[stage.to_s])
  end

  # How many `shipped` cards a board draws by default. The cap trims the render,
  # not the record: the column's "older" link pages through `?stage=shipped`.
  BOARD_SHIPPED_LIMIT = 12

  # Cards per page on an explicit `?stage=` view, the only path to the archive. No
  # parameter raises it: the board is public, and an uncapped archive read took
  # production down (archived-board-crashes-prod).
  BOARD_STAGE_LIMIT = 100

  # The default board set: live work, the freshest BOARD_SHIPPED_LIMIT shipped
  # cards, never archived. Capped in SQL so the trimmed rows' events and gate runs
  # are never instantiated. Callers pass an ordered, preloaded scope. Returns an
  # Array (two loads).
  def self.board_default_tasks(scope = all)
    scope.where.not(stage: %w[archived shipped]).to_a +
      scope.where(stage: "shipped").limit(BOARD_SHIPPED_LIMIT).to_a
  end

  # { stage => true total } for each column board_default_tasks trimmed, else {}.
  # Pass the same filtered scope the cards came from.
  def self.board_capped_stage_totals(scope = all)
    shipped = scope.where(stage: "shipped").count
    shipped > BOARD_SHIPPED_LIMIT ? { "shipped" => shipped } : {}
  end

  # One BOARD_STAGE_LIMIT page of an explicit `?stage=` view, newest first, capped
  # in SQL. `id` breaks ties so OFFSET paging never skips or repeats a task. Pass a
  # page already clamped by board_stage_page.
  def self.board_stage_tasks(scope, stage, page: 1)
    offset = ([page.to_i, 1].max - 1) * BOARD_STAGE_LIMIT
    scope.where(stage: stage).order(id: :desc).limit(BOARD_STAGE_LIMIT).offset(offset).to_a
  end

  # Pages a stage of `total` tasks spans; at least 1.
  def self.board_stage_page_count(total)
    [(total.to_i + BOARD_STAGE_LIMIT - 1) / BOARD_STAGE_LIMIT, 1].max
  end

  # A requested `?page=` clamped into the pages that exist; junk reads as page 1, so
  # SQL never gets an OFFSET past bigint.
  def self.board_stage_page(requested, total)
    requested = requested.is_a?(String) || requested.is_a?(Integer) ? requested.to_s.to_i : 1
    requested.clamp(1, board_stage_page_count(total))
  end

  # The explicit-stage twin of board_capped_stage_totals.
  def self.board_stage_capped_totals(scope, stage, total: nil)
    total ||= scope.where(stage: stage).count
    total > BOARD_STAGE_LIMIT ? { stage.to_s => total } : {}
  end

  # WIP for the DevOps card: the `live` scope's count, independent of any board
  # filter.
  def self.wip_count
    live.count
  end

  # WIP by stage in board order, zeros included; sums to #wip_count since both read
  # `live`.
  def self.wip_by_stage
    counts = live.group(:stage).count
    (STAGES - %w[shipped archived]).index_with { |stage| counts[stage].to_i }
  end

  # Avi's per-app release disposition over the `reviewed` queue (the board marker
  # and the qa-release step): an app is `included` only when every reviewed member
  # is included_in_release?, so one held member holds its app.
  def self.reviewed_release_inclusion(scope = where(stage: "reviewed"))
    scope.to_a.group_by(&:release_repo).transform_values do |members|
      { included: members.all?(&:included_in_release?), members: members }
    end
  end

  def self.unresolved_feedback_by_slug(task_slugs)
    slugs = Array(task_slugs).map(&:to_s).reject(&:blank?)
    return {} if slugs.empty?

    Activity.where(task_slug: slugs, activity_type: %w[qa_feedback handoff])
            .conversation_order
            .each_with_object({}) do |activity, unresolved|
      if activity.activity_type == "qa_feedback"
        unresolved[activity.task_slug] = activity
      elsif activity.resolves_feedback?
        unresolved.delete(activity.task_slug)
      end
    end
  end

  # Mascots held by live tasks: the draw skips them so live tasks never share one.
  def self.active_mascots
    live.pluck(:metadata).filter_map { |m| m&.dig("devops", "mascot").presence }
  end

  def self.shiny_value?(value)
    value == true || value.to_s.strip.downcase == "true" || value.to_s.strip == "1"
  end

  # Settles "waiting" requests on rows past the window that nobody saves again.
  # Idempotent; update_column so a historical row sees no callbacks. Records no
  # dropped-at receipt: no agent's move discarded these. Driver:
  # `rake tasks:settle_stale_operator_approvals`.
  def self.settle_stale_operator_approvals!
    settled = []
    where.not(stage: APPROVAL_REQUEST_STAGES).find_each do |task|
      next unless task.devops["approval_status"] == OPERATOR_APPROVAL_WAITING

      metadata = task.metadata.deep_dup
      metadata["devops"]["approval_status"] = OPERATOR_APPROVAL_NONE
      # The column rides along: update_columns skips #mirror_devops_columns.
      task.update_columns(metadata: metadata, approval_status: OPERATOR_APPROVAL_NONE) # rubocop:disable Rails/SkipsModelValidations
      settled << task.slug
    end
    settled
  end

  # Gives every live task without a mascot a unique fresh draw, through the normal
  # devops path. Idempotent; a failing row goes to ErrorLog and is skipped. Returns
  # the count assigned.
  def self.backfill_mascots!
    taken = active_mascots.to_set
    assigned = 0
    live.find_each do |task|
      next if task.devops["mascot"].present?

      pick = Pokemon.draw(exclude: taken.to_a)
      next unless pick

      merged = task.metadata.deep_dup
      backfilled = (merged["devops"] ||= {})
      backfilled["mascot"] = pick.slug
      # A fresh draw rolls its own shiny and gender.
      backfilled["mascot_shiny"] = Pokemon.roll_shiny?
      backfilled["mascot_gender"] = pick.roll_gender
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

  # Every live task with a session_id adopts its session's Pokémon (first seen
  # wins). Idempotent; a failing row goes to ErrorLog and is skipped. Returns the
  # count.
  def self.resync_session_mascots!
    by_session = {}
    shiny_by_session = {}
    gender_by_session = {}
    taken = active_mascots.to_set
    restamped = 0
    live.find_each do |task|
      sid = task.metadata&.dig("devops", "session_id").to_s
      next if sid.blank?

      slug = by_session[sid] ||= (task.metadata.dig("devops", "mascot").presence || Pokemon.draw(exclude: taken.to_a)&.slug)
      next unless slug
      taken << slug

      # Shiny and gender ride with the session's Pokémon: the SessionMascot row wins,
      # else the first task seen. key? so a `false` caches.
      unless shiny_by_session.key?(sid)
        session_mascot = SessionMascot.find_by(session_id: sid)
        shiny_by_session[sid] = session_mascot ? session_mascot.shiny? : shiny_value?(task.metadata.dig("devops", "mascot_shiny"))
        gender_by_session[sid] = Pokemon.normalize_gender(session_mascot ? session_mascot.gender : task.metadata.dig("devops", "mascot_gender"))
      end
      shiny = shiny_by_session[sid]
      gender = gender_by_session[sid]

      dev = task.metadata["devops"] || {}
      next if dev["mascot"] == slug && dev["mascot_session"] == sid && shiny_value?(dev["mascot_shiny"]) == shiny &&
              dev.key?("mascot_gender") && Pokemon.normalize_gender(dev["mascot_gender"]) == gender

      pokemon = Pokemon.find_by(slug: slug)
      # Locked and reloaded, so the restamp builds on the row as it stands and
      # cannot write back a key another writer changed since the batch loaded.
      # update_columns skips #mirror_devops_columns, so the mirrored columns ride
      # along from the same hash.
      task.with_lock do
        merged = task.metadata.deep_dup
        d = (merged["devops"] ||= {})
        d["mascot"] = slug
        d["mascot_session"] = sid
        d["mascot_shiny"] = shiny
        d["mascot_gender"] = gender
        d["mascot_color"] = pokemon&.signature_color
        d["mascot_emoji"] = pokemon&.status_emoji(shiny: shiny)
        columns = DEVOPS_MIRRORED_KEYS.select { |key| task.has_attribute?(key) }
                                      .index_with { |key| d[key].to_s.strip.presence }
        task.update_columns(metadata: merged, **columns.symbolize_keys) # rubocop:disable Rails/SkipsModelValidations
      end
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

  # Whether the mascot is shiny: the session's roll, stamped as devops.mascot_shiny.
  def mascot_shiny?
    self.class.shiny_value?(devops["mascot_shiny"])
  end

  # "female", "male" or nil (genderless or an old draw): the session's roll, stamped
  # as devops.mascot_gender. It picks a gendered form, the female sprite, and which
  # evolution branches the gates offer.
  def mascot_gender
    Pokemon.normalize_gender(devops["mascot_gender"])
  end

  def devops_kind
    devops.fetch("kind", "").presence || "feature"
  end

  def devops_shape
    devops.fetch("shape", "").presence
  end

  # There is no `devops_release_slug`: release membership is the `release_slug`
  # column (`task.release`). See DEVOPS_COLUMN_KEYS.

  def devops_worktree_slug
    devops.fetch("worktree_slug", "").presence
  end

  # Free-form detail agents write for each other; no length limit.
  def devops_agent_context
    devops.fetch("agent_context", "").presence
  end

  # The soul who built this task, stamped on any build claim (#enforce_builder_stamp)
  # so the reviewer pool can exclude it. Precedence: a soul `--actor`, the soul
  # persona, then agent_slug. nil means the record does not say, and
  # ReviewerSelector refuses to auto-select on it.
  def devops_built_by
    self.class.canonical_soul(devops.fetch("built_by", "")).presence
  end

  # Every soul that worked this task, in order: a task can have several authors.
  # Append-only and server-owned (not in DEVOPS_KEYS); #enforce_builder_stamp is the
  # only writer. ReviewerSelector excludes the whole set.
  def devops_builders
    Array(devops["builders"]).map { |s| self.class.canonical_soul(s) }.select(&:present?).uniq
  end

  # Who moved the PR head outside the build claim: a reviewer's fix-forward (a
  # "zap"), recorded by `bin/task fix-forward` from bin/pr-review. A zap author is
  # an author of the PR, so soul entries join `builders` (never `built_by`); other
  # entries add nobody. Without it the author set fails open.
  def devops_fix_forward
    Array(devops["fix_forward"]).map { |slug| self.class.canonical_soul(slug) }.reject(&:empty?)
  end

  # --- Session resume -------------------------------------------------------
  # The Claude or Codex session that worked this task, captured by bin/task on
  # create and on the claim, so the operator can see and reopen it.
  def devops_session_id
    session_id
  end

  # Which CLI the session belongs to; nil means "claude".
  def devops_session_provider
    devops.fetch("session_provider", "").presence
  end

  # The last four characters of the session id, or nil.
  def session_id_last4
    id = devops_session_id
    id && id[-4..]
  end

  # The full, copyable resume command, or nil.
  def resume_command
    id = devops_session_id
    return nil unless id

    provider = devops_session_provider || "claude"
    format(RESUME_COMMANDS.fetch(provider, RESUME_COMMANDS["claude"]), id)
  end

  # Display form, e.g. "claude --resume …12ab"; nil without a session.
  def resume_command_display
    id = devops_session_id
    return nil unless id

    provider = devops_session_provider || "claude"
    format(RESUME_COMMANDS.fetch(provider, RESUME_COMMANDS["claude"]), "…#{id[-4..]}")
  end

  # --- Build claim lease fields (legacy readers) ----------------------------
  # The build claim is the desk bound to the task (bin/lib/desk_claim.rb); nothing
  # renews these fields for a build. They remain for records that carry them. The
  # lease math lives in ClaimLease, shared with bin/task.
  def devops_claim
    ClaimLease.from_devops(devops)
  end

  def claimed_session_id
    devops.fetch("claimed_session", "").presence
  end

  def devops_claim_nonce
    devops.fetch("claim_nonce", "").presence
  end

  # True while a non-expired claim is held; the /tasks resume control reuses it.
  def claim_live?(now: Time.current)
    ClaimLease.live?(devops, now: now)
  end

  # Seconds since the holder's last heartbeat; nil without a lease.
  def claim_heartbeat_seconds_ago(now: Time.current)
    ClaimLease.heartbeat_age(devops, now: now)
  end

  # --- Review claim lease ---------------------------------------------------
  # Who is reviewing the submitted task, in its own row (TaskReviewClaim). The
  # liveness fact the `reviewable` scope filters on, per row for the API.
  def review_claim_live?(now: Time.current)
    review_claim&.live?(now: now) || false
  end

  # --- Progress (see ClaimLease) --------------------------------------------
  # What the task has produced, read from TaskEvents and GateRuns, which exist only
  # when work landed. nil means unknown, and unknown reads as healthy.
  PROGRESS_IN_FLIGHT_BUDGET = 6.hours # past the longest cert ever measured (321m)

  def last_progress_event
    @last_progress_event ||= progress_evidence.max_by(&:first)
  end

  def last_progress_at
    last_progress_event&.first
  end

  # What the last durable artifact was, e.g. "cert started".
  def last_progress_label
    last_progress_event&.at(1)
  end

  def progress_seconds_ago(now: Time.current)
    ClaimLease.progress_age(last_progress_at, now: now)
  end

  # --- Attribution: progress belongs to whoever produced it -----------------
  # The holder's liveness is asked of the holder's own artifacts, and the newest
  # artifact's owner is published beside it, so a challenger's work is never
  # quoted back as the holder's.

  # Who produced the newest artifact; nil is unknown, never "the holder".
  def last_progress_actor
    last_progress_event&.at(2)
  end

  def holder_progress_event
    @holder_progress_event ||= progress_evidence_by(claimed_session_id).max_by(&:first)
  end

  def holder_progress_at
    holder_progress_event&.first
  end

  def holder_progress_label
    holder_progress_event&.at(1)
  end

  # Seconds since the claim holder produced something durable; nil when nothing is
  # attributable to it.
  def holder_progress_seconds_ago(now: Time.current)
    ClaimLease.progress_age(holder_progress_at, now: now)
  end

  # A gate opened recently and not closed. Bounded, because a crashed run latches
  # open forever. Filters the loaded :gate_runs so the board issues no query.
  def gate_in_flight?(now: Time.current)
    window = (now - PROGRESS_IN_FLIGHT_BUDGET)..now

    gate_runs.any? { |gate| gate.finished_at.nil? && gate.started_at.present? && window.cover?(gate.started_at) }
  end

  # --- Reaping --------------------------------------------------------------
  # Never invent evidence, pointed the other way: the refusal message may not cite
  # an unsigned artifact as the holder's, and the reaper may not treat one as
  # someone else's. So for reaping, an artifact counts as the holder's unless
  # another session demonstrably signed it.

  # Seconds since the newest artifact not signed by someone else; nil when none exist.
  def holder_liveness_seconds_ago(now: Time.current)
    ClaimLease.progress_age(undisowned_progress_event&.first, now: now)
  end

  # gate_in_flight?, minus runs another session signed. A cert writes nothing to
  # the desk while it runs, so the holder's own gate keeps the lease alive.
  def holder_gate_in_flight?(now: Time.current)
    window = (now - PROGRESS_IN_FLIGHT_BUDGET)..now

    gate_runs.any? do |gate|
      gate.finished_at.nil? && gate.started_at.present? && window.cover?(gate.started_at) &&
        !disowned?(gate)
    end
  end

  # Held by a live session, yet nothing durable has landed in a while.
  # Informational only. Measured on the holder's own artifacts when it has any,
  # else the task-wide fact.
  def claim_progress_quiet?(now: Time.current)
    ClaimLease.quiet?(devops,
                      last_progress_at: holder_progress_at || last_progress_at,
                      in_flight: holder_gate_in_flight?(now: now),
                      now: now)
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

  # The archive override's receipt (lib/open_pr_guard.rb): each PR that
  # `bin/task move <slug> archived --force` dropped, so a reader can tell dropped
  # from forgotten.
  def devops_abandoned_prs
    devops_list("abandoned_prs")
  end

  # Readers and writers for DEVOPS_MIRRORED_KEYS. A reader takes the column and
  # falls back to the devops key for a row the backfill has not reached. A writer
  # sets both, so an attribute write and a devops write land the same value. The
  # writer also records the value for #mirror_devops_columns to replay, because
  # mass assignment applies a hash value such as `metadata:` after every scalar,
  # which would otherwise discard the key the writer just set. An in-place devops
  # mutation reaches the column at the next save. A record loaded through a
  # `select` that omits the column reads the key, never MissingAttributeError.
  DEVOPS_MIRRORED_KEYS.each do |key|
    define_method(key) do
      (has_attribute?(key) ? super() : nil).presence || devops[key].to_s.strip.presence
    end

    define_method("#{key}=") do |value|
      text = value.to_s.strip.presence
      (@devops_column_writes ||= {})[key] = text
      write_devops_key(key, text)
      super(text)
    end
  end

  def waiting_for_operator_approval?
    approval_status == OPERATOR_APPROVAL_WAITING
  end

  # The operator windows this task carries now (Devops::Windows), derived, never
  # stored: the approval clock while a request waits, and the escalation clock on a
  # live dependency block whose summary leads `Escalated:`. The card, the API and
  # `bin/task wait-window` all read this. Pass the preloaded `unresolved` block
  # Activity, or a live block looks it up.
  def operator_windows(unresolved: nil)
    unresolved = unresolved_feedback_activity if unresolved.nil? && blocked?
    Devops::Windows.for_task(self, unresolved: unresolved)
  end

  def unresolved_feedback_activity
    self.class.unresolved_feedback_by_slug([slug])[slug]
  end

  def unresolved_feedback?
    unresolved_feedback_activity.present?
  end

  # Fresh build or resubmission? A rework block leaves the task on `building`, so
  # the tree answers (has the PR head moved since the bounce?). See
  # Task::Resubmission; boards pass the batch from Task::Resubmission.for_tasks.
  # Not memoized: the card broadcasts on commit, before the qa_feedback row exists,
  # and a memo would freeze `:fresh`. Callers hold the value themselves.
  def resubmission
    Task::Resubmission.for(self)
  end

  # Has this task ever carried a qa_feedback block, resolved or not? Distinct from
  # #unresolved_feedback? (open) and #blocked? (live, from blocked_at).
  def ever_blocked?
    Activity.for_task(self).by_type("qa_feedback").exists?
  end

  # The card's block lifecycle:
  #   :blocked — a live block or an open qa_feedback (red card)
  #   :cleared — was blocked, resolved, and back in `submitted` for re-review
  #   :never   — anything else
  # Boards pass preloaded `unresolved:` and `ever_blocked:` to avoid N+1; omitted,
  # it queries.
  def block_state(unresolved: nil, ever_blocked: nil)
    unresolved = unresolved_feedback? if unresolved.nil?
    return :blocked if blocked? || unresolved

    ever_blocked = ever_blocked?() if ever_blocked.nil?
    return :cleared if stage == "submitted" && ever_blocked

    :never
  end

  # `events:` passes through to open_intents_for; boards call this once per card.
  def review_in_progress?(events: nil)
    stage == "submitted" && open_intent_for("reviewed", events: events).present? && review_claim_alive?
  end

  # Is the review lane's face still true? An open intent says a review started; the
  # review claim, a heartbeated TTL lease, says the reviewer is alive. With a claim
  # row, defer to it; claim-less intents read live (`bin/reviewer-select` records
  # the pair before anyone claims). The one rule for both readers:
  # #review_in_progress? and StageAgentsHelper#in_progress_work. Reads the
  # preloadable association, not a find_by.
  def review_claim_alive?
    claim = review_claim
    claim.nil? || claim.live?
  end

  # The soul holding a live review claim, or nil, served from the index so
  # `bin/reviewer-select --busy-auto` can exclude mid-review souls in one request.
  # nil covers both "nobody is reviewing" and a live claim naming no soul
  # (claim_next_review may take one without a reviewer); read #review_claim_live?
  # to tell them apart. Reads the preloadable association.
  def review_holder(now: Time.current)
    claim = review_claim
    return nil unless claim&.live?(now: now)

    claim.holder_agent.to_s.strip.presence
  end

  # The review pair stored on the task itself, each `{ "slug", "weight" }` (legacy
  # "heavy" reads as "primary"). The avatars UI reads the submitted→reviewed
  # TaskEvent instead (#stage_event_metadata). Empty for old-flow tasks.
  def reviewers
    self.class.normalize_reviewers(metadata["reviewers"])
  end

  # Record an intent: an agent starting the work that produces `to_stage`, so the
  # board shows who is on it before the transition lands. Only the current stage's
  # next target is recordable; an identical open intent is returned rather than
  # stacked; a no-op once `to_stage` landed this cycle. Intents carry no usage: the
  # transition records the delta from the baseline the intent seeds.
  # `qa: true` marks Avi's assembled-QA intent (Release::Conductor#record_qa_intent),
  # which shares Steffon's ship target, so idempotency matches the full identity
  # (target, actor, reviewers, qa).
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

  def record_checkpoint_event(name:, status:, actor: nil, source: nil, metadata: {})
    task_events.create!(
      kind: TaskEvent::CHECKPOINT,
      from_stage: stage,
      to_stage: name.to_s,
      occurred_at: Time.current,
      seconds_in_from: nil,
      source: (source.presence || Current.task_event_source).presence,
      actor: actor.to_s.strip.presence || Current.task_event_actor.presence,
      **task_event_usage_attrs,
      metadata: metadata.to_h.merge("status" => status.to_s)
    )
  end

  def record_review_check_in(role:, moment:, status: nil, actor: nil, source: nil, message: nil, idempotency_key: nil, metadata: {})
    role = self.class.normalize_review_role(role)
    raise ArgumentError, "review role must be primary or light" unless REVIEW_ROLES.include?(role)

    moment = self.class.normalize_review_moment(moment)
    raise ArgumentError, "review moment is required" if moment.blank?
    unless REVIEW_MOMENTS.fetch(role).include?(moment)
      raise ArgumentError, "review moment must be one of: #{REVIEW_MOMENTS.fetch(role).join(', ')}"
    end

    status = self.class.normalize_review_status(status.presence || default_review_status_for(moment))
    unless REVIEW_STATUSES.include?(status)
      raise ArgumentError, "review status must be one of: #{REVIEW_STATUSES.join(', ')}"
    end

    key = idempotency_key.to_s.strip.presence
    if key
      existing = task_events.checkpoints.where("metadata ->> 'idempotency_key' = ?", key).first
      return existing if existing
    end

    review_metadata = metadata.to_h.merge(
      "stage" => "reviewed",
      "event" => "review_check_in",
      "review_role" => role,
      "review_moment" => moment,
      "moment_label" => self.class.review_moment_label(role, moment)
    )
    review_metadata["message"] = message.to_s.strip if message.present?
    review_metadata["idempotency_key"] = key if key

    record_checkpoint_event(
      name: "review_#{role}_#{moment}",
      status: status,
      actor: actor,
      source: source,
      metadata: review_metadata
    )
  end

  def review_check_in_events
    task_events.checkpoints.chronological.to_a.select(&:review_check_in?)
  end

  # The open intent for `to_stage` (work started, not yet landed), or nil. Cycle
  # aware: a re-entry into `submitted` closes the prior cycle's review intents.
  def open_intent_for(to_stage, events: nil)
    open_intents_for(to_stage, events: events).last
  end

  # Avi's crew-seat duration, measured from his pickup (the QA intent from
  # Release::Conductor#record_qa_intent) rather than from review's hand-off, which
  # is mostly queue time. Every member of one sweep reports the same number. nil
  # without a pickup row; the caller falls back to the transition figure.
  # `events:` is an explicit parameter, never a `task_events.loaded?` sniff: a
  # loaded association can be stale, so only a caller holding a fresh array (the
  # board's per-request preload) opts in.
  def assembled_seconds_from_pickup(events: nil)
    # The assemble moment comes from the transition event so the card and the model
    # agree; filtered in Ruby over loaded events (#board_read_events).
    landed_at = assembled_landing_at(events)
    return nil unless landed_at

    pickup = latest_assembled_pickup(events, landed_at)
    return nil unless pickup

    (landed_at - pickup.occurred_at).round
  end

  # When the assemble LANDED. Prefers the transition event over the assembled_at
  # column so the card and the model cannot disagree.
  def assembled_landing_at(events)
    landed =
      if events
        latest_event(events) { |e| e.transition? && e.to_stage == "assembled" }
      else
        task_events.transitions.where(to_stage: "assembled").chronological.last
      end
    landed&.occurred_at || assembled_at
  end

  # Avi's pickup intent for that landing — the latest one at or before it.
  def latest_assembled_pickup(events, landed_at)
    if events
      latest_event(events) { |e| e.intent? && e.to_stage == "assembled" && e.occurred_at <= landed_at }
    else
      task_events.intents.where(to_stage: "assembled")
                 .where(occurred_at: ..landed_at).chronological.last
    end
  end

  # `chronological.last` in Ruby: newest by (occurred_at, id), both NOT NULL.
  def latest_event(events)
    events.select { |event| yield(event) }.max_by { |event| [event.occurred_at, event.id.to_i] }
  end

  # ONE implementation, over an event array. The board passes its preload as
  # `events:`; every other caller (record_intent_event's idempotency check among
  # them) passes nothing and gets a fresh read of this task's intents and
  # transitions, never a `loaded?` sniff, so a write path always reads the database.
  def open_intents_for(to_stage, events: nil)
    to_stage = to_stage.to_s
    return [] unless NEXT_INTENT_STAGE[stage] == to_stage

    events ||= task_events.where(kind: [ TaskEvent::INTENT, TaskEvent::TRANSITION ]).to_a
    # Resolved once per call and passed down, never memoized on the instance.
    entry = current_stage_entry_event(events: events)

    open_intent_candidates(to_stage, events).reject do |intent|
      !intent_started_in_current_stage?(intent, entry: entry) || superseded_by?(events, intent)
    end
  end

  # The →to_stage intents, oldest first.
  def open_intent_candidates(to_stage, events)
    events.select { |event| event.intent? && event.to_stage == to_stage }
          .sort_by { |event| [event.occurred_at, event.id.to_i] }
  end

  # The normalized pair on the latest review intent, or nil.
  def latest_intent_reviewers(to_stage = "reviewed")
    intent = task_events.intents.where(to_stage: to_stage).chronological.last
    intent && self.class.normalize_reviewers(intent.metadata["reviewers"]).presence
  end

  # Has the target landed in the current stage cycle? Keeps retries idempotent while
  # a reworked task can open a fresh `→reviewed` intent.
  def target_landed_in_current_stage?(to_stage)
    entry = current_stage_entry_event
    landed = task_events.transitions.where(to_stage: to_stage)
    return landed.exists? if entry.nil?

    landed.where(
      "occurred_at > ? OR (occurred_at = ? AND id >= ?)",
      entry.occurred_at, entry.occurred_at, entry.id
    ).exists?
  end

  def current_stage_entry_event(events: nil)
    return latest_event(events) { |e| e.transition? && e.to_stage == stage } if events

    task_events.transitions.where(to_stage: stage).chronological.last
  end

  # `entry:` is required: the caller resolves the stage-entry event once.
  def intent_started_in_current_stage?(intent, entry:)
    return false unless intent.from_stage == stage
    return true if entry.nil?

    intent.occurred_at > entry.occurred_at ||
      (intent.occurred_at == entry.occurred_at && intent.id.to_i >= entry.id.to_i)
  end

  # An intent closes when its target lands or any later transition leaves its
  # source stage.
  def superseded_by?(events, intent)
    events.any? do |event|
      next false unless event.transition?
      next false unless event.to_stage == intent.to_stage || event.from_stage == intent.from_stage

      event.occurred_at > intent.occurred_at ||
        (event.occurred_at == intent.occurred_at && event.id.to_i > intent.id.to_i)
    end
  end

  def devops_url(name)
    return pr_url if name.to_s == "pr"

    devops.fetch("#{name}_url", "").presence
  end

  def devops_field(name)
    devops.fetch(name.to_s, "").presence
  end

  def requires_release_conductor?
    ActiveModel::Type::Boolean.new.cast(devops.fetch("requires_release_conductor", false))
  end

  # Avi's per-app release inclusion in qa-release. Unset reads true, so every
  # reviewed task rides the next candidate; `included_in_release: false` holds a
  # member (and its app) out, shown on the card and enforced through
  # `bin/release prepare --task` and `bin/release eject`.
  def included_in_release?
    ActiveModel::Type::Boolean.new.cast(devops.fetch("included_in_release", true))
  end

  # Every repo this task ships through, the set the Deploy workflow promotes, QAs
  # and ships: the primary (#release_repo), then repos with a recorded PR, then the
  # rest of `repositories`. Callers that plan release work use this, never
  # #release_repo.
  def release_repos
    ([ release_repo ] + release_pr_urls.keys + devops_repositories).compact_blank.uniq
  end

  # The primary repo, the unit classified as gem or app: parsed from the PR url,
  # else the gem repo named (for `library`), else the first repository. Not the
  # release identity of a multi-repo task; see #release_repos.
  def release_repo
    repo_from_pr_url.presence ||
      if devops_shape == "library"
        devops_repositories.find { |repo| Release::Repos.gem?(repo) } || devops_repositories.first
      else
        devops_repositories.first
      end
  end

  # { "<repo>" => "<pr url>" } for every PR this task landed. The singular `pr_url`
  # merges last and wins for its own repo, because the whole pipeline acts on it;
  # the map holds the repos `pr_url` cannot reach.
  def release_pr_urls
    map = devops.fetch("pr_urls", {})
    map = map.is_a?(Hash) ? map.to_h { |repo, url| [repo.to_s.strip, url.to_s.strip] } : {}
    primary = devops_url("pr").to_s
    primary_repo = self.class.repo_from_pr_url(primary)
    map = map.merge(primary_repo => primary) if primary_repo.present? && primary.present?
    map.reject { |repo, url| repo.blank? || url.blank? }
  end

  # The repos expected to carry their own PR. An app task: every repo it names. A
  # gem task is one PR in the gem repo, its consumers reached by a published
  # version, so it is measured against the gem repos it names, else the gem repos
  # it recorded a PR for, else the literal list.
  def pr_bearing_repositories
    return devops_repositories unless gem_release?

    named_gems = devops_repositories.select { |repo| Release::Repos.gem?(repo) }
    return named_gems if named_gems.any?

    recorded_gems = release_pr_urls.keys.select { |repo| Release::Repos.gem?(repo) }
    recorded_gems.presence || devops_repositories
  end

  # Repos expected to carry a PR that recorded none. Enforced by
  # Release::Conductor.validate_member_pr_coverage! inside every sweep write, and
  # delegated to Release::SweepPlan.repo_coverage_gap so the CLI screen and the
  # backstop share one rule. A single-repo task is never an offender; a gem
  # release measures against #pr_bearing_repositories.
  def repos_missing_pr_url
    Release::SweepPlan.repo_coverage_gap(repos: release_repos, pr_repos: release_pr_urls.keys,
                                         expected: pr_bearing_repositories)
  end

  # Ships as a published gem: a `library` shape or a registered gem release_repo.
  # Drives producer-first ordering and the board's gem badge.
  def gem_release?
    devops_shape == "library" || Release::Repos.gem?(release_repo)
  end

  # :gem, :app or :unknown: the member kind the conductor orders and plans by.
  def release_kind
    return :gem if gem_release?

    Release::Repos.kind(release_repo)
  end

  # A live block: blocked_at set while in `building`. blocked_at persists as history
  # (release notes read it). #block! sets it; #unblock! clears it.
  def blocked?
    blocked_at.present? && stage == "building"
  end

  # `block_kind` (environment, rework, dependency) is a column stamped by #block!.
  def stage_label
    STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  # The gerund label for a stage in progress, e.g. "Assembling"; falls back to the
  # noun label, then the humanized key.
  def self.active_stage_label(stage)
    STAGE_ACTIVE_LABELS[stage] || STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  # Measured tokens across every TaskEvent, for the /intelligence charts (sizing
  # uses cost). SQL off a fresh relation, so no stale association cache.
  def measured_tokens_total
    TaskEvent.where(task_slug: slug)
             .sum(Arel.sql("COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)"))
  end

  # Measured USD across every TaskEvent (NULL counts as 0); a BigDecimal. SQL off a
  # fresh relation. Powers the release-notes card.
  def total_cost
    TaskEvent.where(task_slug: slug).sum(:cost)
  end

  # The actual_size the measured cost maps to, or nil when there is no cost (never
  # a misleading "small"). Pure: callers decide whether to persist.
  def derive_actual_size
    cost = total_cost
    return nil if cost.nil? || cost.zero?

    ACTUAL_SIZE_COST_THRESHOLDS.find { |_size, ceiling| cost < ceiling }&.first
  end

  # Apply a partial devops write over what the task carries, keyed on the names the
  # caller posted:
  #   * a name not posted → unchanged
  #   * a name posted     → authoritative, blank included, so a field can be cleared
  # The posted-name set separates "absent" from "present and blank", which the
  # normalized hash cannot. `& DEVOPS_KEYS` keeps a refused column name from also
  # deleting. Pure; raises what normalize_devops_metadata raises (a 422 upstream).
  def self.merge_devops_metadata(existing, raw)
    normalized = normalize_devops_metadata(raw)
    posted = raw.to_h.keys.map(&:to_s) & DEVOPS_KEYS

    (existing || {}).to_h.deep_dup.except(*posted).merge(normalized)
  end

  # Fold a partial devops post into the full metadata hash: the one implementation
  # both write paths share, so the board form and the JSON API cannot diverge.
  # Names outside "devops" ride through; names inside follow merge_devops_metadata.
  # An emptied "devops" is dropped (Task#devops? keys off presence). Pure.
  # `stage` is the stage after this save, for .guard_approval_request_stage!; nil
  # skips the guard. It must stay a trailing positional: callers pass a brace-less
  # hash, which Ruby 3 would bind to any keyword.
  def self.merge_devops_into_metadata(metadata, raw_devops, stage = nil)
    guard_approval_request_stage!(raw_devops, stage)
    base = (metadata || {}).to_h.deep_dup
    merged = merge_devops_metadata(base["devops"], raw_devops)
    if merged.any?
      base["devops"] = merged
    else
      base.delete("devops")
    end
    base
  end

  # Refuse an explicit "waiting" post that this save would settle to "none", so the
  # write fails loudly instead of returning 200 and reaching nobody. Only explicit
  # posts raise; stage moves and stale echoes still settle silently in the callback,
  # the same front-door/back-door pair as DEVOPS_COLUMN_KEYS. Both controllers turn
  # the raise into a 422.
  def self.guard_approval_request_stage!(raw_devops, stage)
    stage = stage.to_s.strip
    return if stage.empty? || APPROVAL_REQUEST_STAGES.include?(stage)

    posted = (raw_devops || {}).to_h.find { |key, _| key.to_s == "approval_status" }
    return if posted.nil?
    return unless posted.last.to_s.strip.downcase == OPERATOR_APPROVAL_WAITING

    # The remedy is a write the caller can make now, never a backward move: from
    # `reviewed` on, the code is already on accepted. One sentence on three surfaces:
    # this message, bin/task's #warn_dropped_approval_request!, and the board doc's
    # Operator Validation Gate item 8. Pinned by
    # test/models/task_approval_request_guard_test.rb.
    raise ArgumentError,
          "devops.approval_status cannot be set to #{OPERATOR_APPROVAL_WAITING.inspect} at stage " \
          "#{stage} — an approval request is only actionable in " \
          "#{APPROVAL_REQUEST_STAGES.join(" or ")}, so this save would settle it to " \
          "#{OPERATOR_APPROVAL_NONE.inspect} and the board would never pulse. Record the " \
          "operator's answer where you stand: bin/task update <task-slug> --approval " \
          "#{OPERATOR_APPROVAL_APPROVED}, or bin/task update <task-slug> --approval " \
          "#{OPERATOR_APPROVAL_CHANGES_REQUESTED} — both are legal at every stage. If you still " \
          "need his eyes on merged work, point him at the QA candidate once the qa-release sweep " \
          "deploys it. Do not move the task back to re-open the request: a backward move " \
          "un-merges nothing — from reviewed on, the code is already on accepted. Next time, ask " \
          "BEFORE the work merges — a request now survives the handoff to submitted and pulses " \
          "through review."
  end

  # The one canonical epic handle, shared by the write and the `for_epic` read:
  # strip, downcase, blank or "none" → nil. Validation decides legality, so a
  # refusal can quote what was sent.
  def self.normalize_epic_slug(value)
    text = value.to_s.strip.downcase
    return nil if text.empty? || text == EPIC_CLEAR_VALUE

    text
  end

  def self.normalize_devops_metadata(raw)
    return {} if raw.blank?

    raw.to_h.each_with_object({}) do |(key, value), normalized|
      key = key.to_s
      normalized_value =
        if DEVOPS_MAP_KEYS.include?(key)
          normalize_devops_map(value)
        elsif DEVOPS_LIST_KEYS.include?(key)
          # Key-scoped comma rule; see DEVOPS_IDENTIFIER_LIST_KEYS.
          normalize_devops_list(value, split_commas: DEVOPS_IDENTIFIER_LIST_KEYS.include?(key))
        else
          value.to_s.strip
        end
      next if normalized_value.blank?

      # A column-backed name raises and names its home. After the blank guard, before
      # the whitelist, so it never decays into a silent skip.
      if (home = DEVOPS_COLUMN_KEYS[key])
        raise ArgumentError, "devops.#{key} is not writable — it lives in #{home}"
      end
      next unless DEVOPS_KEYS.include?(key)

      normalized[key] = normalized_value
    end
  end

  # Normalize a repo-keyed map (DEVOPS_MAP_KEYS) into { "<repo>" => "<value>" } from
  # a Hash (the API and `bin/task --pr-url-for`) or a list or string of bare urls.
  # Both shapes validate alike: each value must parse as a PR url and is keyed by
  # the repo it names. A bad pair raises (a 422 upstream), since a skipped PR url is
  # the failure this key exists to close.
  def self.normalize_devops_map(value)
    pairs =
      if value.is_a?(Hash)
        value.to_h.map { |repo, url| normalize_devops_map_pair(repo, url) }
      else
        # A PR url is an identifier, so the list branch splits commas; a joined entry
        # would drop the second PR. The Hash branch needs no rule: a key must match its
        # url's repo.
        normalize_devops_list(value, split_commas: true).map { |url| normalize_devops_map_pair(nil, url) }
      end

    pairs.compact.to_h
  end

  # One validated `<repo> => <pr url>` pair, or nil for a blank value. A blank is
  # the unset: writers send the whole map, so blanking a value removes it.
  def self.normalize_devops_map_pair(repo, url)
    repo = repo.to_s.strip
    url = url.to_s.strip
    return nil if url.blank?

    named = repo_from_pr_url(url)
    if named.blank?
      raise ArgumentError,
            "devops.pr_urls entry #{url.inspect} names no repo — expected a " \
            "github.com/<owner>/<repo>/pull/<n> url"
    end
    if repo.present? && repo != named
      raise ArgumentError,
            "devops.pr_urls entry #{repo.inspect} => #{url.inspect} is filed under the " \
            "wrong repo — that url names #{named.inspect}"
    end

    [named, url]
  end

  # The repo segment of a GitHub PR url, or nil; Task#repo_from_pr_url delegates here.
  def self.repo_from_pr_url(url)
    url.to_s[PR_URL_REPO_PATTERN, 1]
  end

  def self.normalize_devops_list(value, split_commas: false)
    # The comma rule belongs to the key, not the payload: `split_commas` says the
    # key's entries are identifiers (DEVOPS_IDENTIFIER_LIST_KEYS). Prose keys split on
    # newlines only; the board form posts them as one-per-line textareas, and posts
    # `repositories` and `risk_tags` joined with ", ". Both input shapes read the
    # same flag, so `"a,b"` and `["a,b"]` agree.
    delimiter = split_commas ? /[\n,]/ : "\n"
    parts =
      if value.is_a?(Array)
        value.flat_map { |item| item.to_s.split(delimiter) }
      else
        value.to_s.split(delimiter)
      end
    parts.map(&:strip)
         .reject(&:blank?)
         .uniq
  end

  # Normalize a reviewers payload (a TaskEvent's or a Task's metadata["reviewers"])
  # into `{ "slug", "weight" }` entries. Takes slug strings or hashes with the
  # agent_slug, review_weight and depth aliases; the weight passes through verbatim
  # (StageAgent#role_label maps legacy "heavy"). Blank slugs drop.
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

  def self.normalize_review_role(raw)
    REVIEW_ROLE_ALIASES[raw.to_s.strip.downcase]
  end

  def self.normalize_review_moment(raw)
    raw.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  end

  def self.normalize_review_status(raw)
    raw.to_s.strip.downcase
  end

  def self.review_moment_label(role, moment)
    role = normalize_review_role(role)
    moment = normalize_review_moment(moment)
    REVIEW_MOMENT_LABELS.dig(role, moment).presence || moment.to_s.tr("_", " ").presence&.humanize || "Review update"
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
    # Shipping fast-forwards release into main, so stamp the git location too (MERGED_STATES).
    update!(stage: "shipped", merged: MERGED_MAIN, result: result_data)
  end

  # --- Block: an attribute of `building` -----------------------------------
  # block! lands the task on `building` and stamps blocked_at, blocked_from,
  # blocked_by and block_kind. There is no →blocked transition: those columns and
  # the caller's qa_feedback Activity are the durable markers. The block's
  # `→ building` move is not a build claim (#set_stage_timestamp).
  def block!(by: nil, kind: nil)
    update!(
      stage: "building",
      blocked_from: stage.presence, # evaluated BEFORE the stage assignment: where it stalled
      blocked_at: Time.current,
      blocked_by: by.to_s.strip.presence,
      block_kind: kind.to_s.strip.presence
    )
  end

  # Clear a live block, leaving the task on `building` (the "Resume" action). The
  # qa_feedback ledger is untouched.
  def unblock!
    update!(blocked_at: nil, blocked_by: nil, block_kind: nil, blocked_from: nil)
  end

  # THE BUILDER'S UNBLOCK (guard catalog row 4.2, scoped by decision 6). `bin/task begin`
  # on a blocked task answers a REWORK block, and only that: an environment or
  # dependency block waits on something outside the desk, and an `Escalated:` block
  # waits on Alex, whose answer a fresh begin must never forge (wait-window would read
  # the cleared block as answered). Raised with the reason; the API answers it 409.
  class UnblockRefused < StandardError; end

  BUILDER_CLEARABLE_BLOCK_KINDS = %w[rework].freeze

  # Why the builder may not clear this block, or nil when it may (or there is none).
  def builder_unblock_refusal
    return nil unless blocked?

    unless BUILDER_CLEARABLE_BLOCK_KINDS.include?(block_kind.to_s)
      return "#{slug} carries a #{block_kind.presence || "kindless"} block, which waits on something outside " \
             "the desk; only a rework block is cleared by its builder's begin. Clear it from the task page's " \
             "Resume control once its cause is resolved."
    end

    summary = unresolved_feedback_activity&.block_summary.to_s
    return nil unless summary.lstrip.start_with?(Devops::Windows::ESCALATION_PREFIX)

    "#{slug} carries an escalation (#{summary.strip.truncate(80)}), which only Alex answers; a builder's " \
      "begin never clears it."
  end

  # Clear a rework block as its builder's answer, and record who cleared what. Returns
  # false when there is no live block; raises UnblockRefused for any other block.
  def builder_unblock!(by:)
    return false unless blocked?

    refusal = builder_unblock_refusal
    raise UnblockRefused, refusal if refusal

    cleared = { "kind" => "block_cleared", "cleared_by" => by.to_s, "block_kind" => block_kind,
                "blocked_by" => blocked_by, "blocked_from" => blocked_from,
                "blocked_at" => blocked_at&.iso8601, "summary" => unresolved_feedback_activity&.block_summary }
    transaction do
      unblock!
      Activity.create!(task_slug: slug, activity_type: "comment",
                       agent_slug: (by.to_s if self.class.soul?(by.to_s)),
                       description: "#{by} cleared the #{cleared["block_kind"]} block#{" from #{cleared["blocked_by"]}" if cleared["blocked_by"].present?} " \
                                    "by resuming the build (bin/task begin).",
                       metadata: cleared.compact)
    end
    true
  end

  def archive!
    update!(stage: "archived")
  end

  # Recompute the testing-phase projection (Task::TestingPhases). Public so the
  # TaskEvent commit hook can call it; refresh! uses update_columns, so no re-entry.
  def refresh_testing_phases!
    Task::TestingPhases.refresh!(self)
  end

  def refresh_testing_phases_safely
    refresh_testing_phases!
  rescue StandardError => e
    Rails.logger.warn("[task-testing-phases] refresh failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  # Recompute the latest-attempt-per-gate projection (Task::GatesProjection). Public
  # for the GateRun commit hooks; no re-entry.
  def refresh_gates!
    Task::GatesProjection.refresh!(self)
  end

  def refresh_gates_safely
    refresh_gates!
  rescue StandardError => e
    Rails.logger.warn("[task-gates] refresh failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  private

  # [[time, label, actor], ...]: the durable artifacts this task has produced, read
  # from the loaded associations so a preloaded board card queries nothing.
  def progress_evidence
    evidence = []

    event = task_events.max_by(&:occurred_at)
    evidence << [event.occurred_at, progress_event_label(event), progress_actor(event)] if event&.occurred_at

    gate = gate_runs.max_by(&:updated_at)
    evidence << [gate.updated_at, progress_gate_label(gate), progress_actor(gate)] if gate&.updated_at

    evidence
  end

  # Who produced an artifact, as the row names it: metadata["session"] first, then
  # `actor`. nil stays nil; never guess an owner.
  def progress_actor(row)
    row.metadata.to_h["session"].presence || TaskEvent.named_actor(row.actor)
  end

  # The newest artifact produced by one session, over the same loaded associations.
  def progress_evidence_by(session)
    return [] if session.blank?

    evidence = []

    event = task_events.select { |row| row.occurred_at && progress_actor(row) == session }.max_by(&:occurred_at)
    evidence << [event.occurred_at, progress_event_label(event), session] if event

    gate = gate_runs.select { |row| row.updated_at && progress_actor(row) == session }.max_by(&:updated_at)
    evidence << [gate.updated_at, progress_gate_label(gate), session] if gate

    evidence
  end

  # True only when the row names a different session; anything unknown protects the
  # holder. A soul slug is not a session id, so a soul-attributed row is unknown,
  # not a stranger's.
  def disowned?(row)
    actor = progress_actor(row)
    return false if actor.blank? || claimed_session_id.blank?
    return false if actor.match?(SOUL_SLUG)

    actor != claimed_session_id
  end

  # The newest artifact not signed by another session, over the loaded associations.
  def undisowned_progress_event
    @undisowned_progress_event ||= begin
      evidence = []

      event = task_events.select { |row| row.occurred_at && !disowned?(row) }.max_by(&:occurred_at)
      evidence << [event.occurred_at, progress_event_label(event), progress_actor(event)] if event

      gate = gate_runs.select { |row| row.updated_at && !disowned?(row) }.max_by(&:updated_at)
      evidence << [gate.updated_at, progress_gate_label(gate), progress_actor(gate)] if gate

      evidence.max_by(&:first)
    end
  end

  def progress_event_label(event)
    case event.kind
    when TaskEvent::CHECKPOINT then checkpoint_label(event)
    when TaskEvent::INTENT     then "intent recorded"
    # The event's own destination, not where the task is now.
    else "moved to #{event.to_stage.presence || stage}"
    end
  end

  # A checkpoint's name is its `to_stage`, and checkpoints are not cert-only (review
  # check-ins, `bin/task checkpoint <slug> <name>`), so read the name off the event.
  def checkpoint_label(event)
    name = event.to_stage.to_s.strip.presence || "checkpoint"
    status = event.metadata.to_h["status"].presence

    status ? "#{name} #{status}" : name
  end

  def progress_gate_label(gate)
    return "#{gate.key} running" if gate.finished_at.nil?

    "#{gate.key} #{gate.success ? 'passed' : 'failed'}"
  end

  # Push the app-ladder row when rung membership changed; a destroy always counts.
  # The broadcaster's safe_broadcast keeps a cable failure from breaking the write.
  def broadcast_app_ladder_if_rung_changed
    return unless destroyed? || saved_change_to_merged? || saved_change_to_stage?

    DeploymentsBroadcaster.app_ladder
  end

  # Only a stage transition moves a task-owned phase window; TaskEvent and GateRun
  # refresh their own. Metadata churn does not rebuild.
  def refresh_testing_phases_after_change
    return unless saved_change_to_stage?

    refresh_testing_phases_safely
  end

  def refresh_duration_metrics_for_release_changes
    release_slugs = [release_slug]
    if previous_changes.key?("release_slug")
      release_slugs.concat(previous_changes["release_slug"])
    elsif previous_changes.key?("stage")
      release_slugs << release_slug
    end

    release_slugs.compact_blank.uniq.each do |slug|
      Release.find_by(slug: slug)&.refresh_duration_metrics_safely
    end
  rescue StandardError => e
    Rails.logger.warn("[release-duration-cache] task #{slug} refresh failed: #{e.class}: #{e.message}")
  end

  def default_review_status_for(moment)
    case moment
    when "started" then "started"
    when "completed" then "completed"
    when "failed" then "failed"
    else "info"
    end
  end

  # The repo the singular `pr_url` names, through the one class-level parser.
  def repo_from_pr_url
    self.class.repo_from_pr_url(devops_url("pr"))
  end

  # Reads without split_commas: the write already split identifier keys on commas,
  # so a comma left in a stored entry is prose and stays in it.
  def devops_list(key)
    self.class.normalize_devops_list(devops.fetch(key.to_s, []))
  end

  # The append-only stage spine: one TaskEvent per stage that lands, written inside
  # the save transaction so a stage change never lands without its event. The
  # deterministic fields are server-owned; attribution and usage ride in on Current
  # for the move just made. actor is never backfilled from the build session. The
  # genesis event carries no usage by design.
  def record_genesis_event
    write_stage_event(from: nil)
  end

  # Drop this task's card from the live /deployments board.
  def broadcast_removal_to_deployments_board
    DeploymentsBroadcaster.task_removed(slug)
  end

  def record_transition_event
    write_stage_event(from: stage_before_last_save)
  end

  # At ship, fill a blank actual_size from measured cost; a manual size is never
  # overwritten and nil stays blank. update_column skips the callback chain, and the
  # rescue logs rather than raising, so a derivation bug never rolls back the ship.
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

  # Enqueue the ship's grade (TaskGradingJob → Insights::TaskGrader). An enqueue
  # failure is logged, never raised; `learning_loop:backfill` catches drops.
  def enqueue_task_grading
    TaskGradingJob.perform_later(slug)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  # Enqueue Avi's sizer when the task just entered `designed` (created or moved)
  # with a blank po_size; a plain edit never re-fires. A failed enqueue is logged,
  # never raised; AviSizingJob re-checks po_size, so duplicates are harmless.
  def enqueue_avi_sizing_if_designed_unsized
    return unless stage == "designed"
    return if po_size.present?
    return unless previously_new_record? || saved_change_to_stage?

    AviSizingJob.perform_later(slug)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  # TaskEvent usage with cost derived here, so an operator's saved rate override
  # (invisible to the ActiveRecord-free CLI) prices the event. The CLI's cost is
  # the fallback for an unpriced model or an older CLI.
  def task_event_usage_attrs
    model      = Current.task_event_model.presence
    tokens_in  = Current.task_event_tokens_in
    tokens_out = Current.task_event_tokens_out
    cache_creation_tokens = Current.task_event_cache_creation_tokens
    cache_read_tokens     = Current.task_event_cache_read_tokens

    derived = UsagePricing.cost_from_capture(
      model: model, tokens_in: tokens_in, tokens_out: tokens_out,
      cache_creation_tokens: cache_creation_tokens, cache_read_tokens: cache_read_tokens
    )

    {
      model: model,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cache_creation_tokens: cache_creation_tokens,
      cache_read_tokens: cache_read_tokens,
      cost: derived || Current.task_event_cost
    }
  end

  def write_stage_event(from:)
    occurred = Time.current
    # Stage duration spans transitions only; an intent is not a stage boundary.
    previous = task_events.transitions.chronological.last
    task_events.create!(
      from_stage: from,
      to_stage: stage,
      occurred_at: occurred,
      seconds_in_from: previous && (occurred - previous.occurred_at).round,
      source: Current.task_event_source,
      # Never blank: an unattributed move records TaskEvent::SYSTEM_ACTOR, which
      # authorship readers skip (TaskEvent.named_actor).
      actor: Current.task_event_actor.to_s.strip.presence || TaskEvent::SYSTEM_ACTOR,
      **task_event_usage_attrs,
      # The review-bypass marker (`bin/release merge --override`) rides this
      # transition; absent on every normal move.
      metadata: stage_event_metadata(from: from)
        .merge(Current.task_event_review_bypass ? { "review_bypassed" => true } : {})
        # The block marker: a rework block's `→ building` move carries the blocker as
        # actor, and this says why, so readers never count the blocker as an author. See
        # TaskEvent#block_transition?.
        .merge(block_transition_metadata)
    )
  end

  # The `blocked` marker for a #block! transition; empty on every ordinary move.
  # Keyed on blocked_at landing in this save, like #build_claim_save?.
  def block_transition_metadata
    return {} unless saved_change_to_blocked_at? && blocked_at.present?

    { "blocked" => true }.merge(block_kind.present? ? { "block_kind" => block_kind } : {})
  end

  # Non-spine event metadata. Every transition snapshots the mascot that owned it,
  # so a handoff or evolution repaints the task without rewriting history. The
  # submitted→reviewed event also carries the reviewer pair for the avatars UI:
  # Current.task_event_reviewers, else the open intent's pair, else
  # ReviewerSelector. Never blocks the move: an error is logged.
  def stage_event_metadata(from:)
    metadata = stage_mascot_event_metadata
    return metadata unless from == "submitted" && stage == "reviewed"

    # The pair that started the review wins over a fresh selection; an explicit override wins over both.
    reviewers = Current.task_event_reviewers.presence ||
                latest_intent_reviewers("reviewed") ||
                ReviewerSelector.select(self)
    reviewers.present? ? metadata.merge("reviewers" => reviewers) : metadata
  rescue StandardError => e
    Rails.logger.warn("[reviewer-selector] recording failed (non-fatal): #{e.class}: #{e.message}")
    metadata || {}
  end

  def stage_mascot_event_metadata
    slug = devops["mascot"].presence
    return {} unless slug

    pokemon = Pokemon.find_by(slug: slug) if Pokemon.table_exists?
    # The snapshot bakes the shiny avatar and the gendered name and art, so history
    # keeps its face after the mascot recycles.
    snapshot = {
      "slug" => slug,
      "name" => pokemon&.display_name(gender: mascot_gender).presence || slug,
      "avatar" => pokemon&.display_avatar(shiny: mascot_shiny?, gender: mascot_gender).presence,
      "color" => devops["mascot_color"].presence || pokemon&.signature_color.presence,
      "emoji" => devops["mascot_emoji"].presence,
      "shiny" => (true if mascot_shiny?),
      "gender" => mascot_gender
    }.compact

    { "mascot" => snapshot }
  rescue StandardError => e
    Rails.logger.warn("[task-event-mascot] recording failed (non-fatal): #{e.class}: #{e.message}")
    {}
  end

  def set_stage_timestamp
    case stage
    when "building"
      # A block! lands on `building` but is not a fresh claim, so started_at stays
      # (detected by blocked_at landing in this save).
      self.started_at = Time.current unless will_save_change_to_blocked_at? && blocked_at.present?
    when "submitted" then self.submitted_at = Time.current
    when "reviewed"  then self.reviewed_at  = Time.current
    when "assembled" then self.assembled_at = Time.current
    when "shipped"   then self.completed_at = Time.current
    when "archived"  then self.archived_at = Time.current
    end
    # Re-rank to the top of the new column on every stage move (max + 100);
    # set_initial_position seeds the rank on create.
    self.position = (Task.where(stage: stage).maximum(:position) || 0) + 100 unless new_record?
  end

  # Clear the live-block columns when the task advances out of `building`; the
  # qa_feedback ledger keeps the history.
  def clear_block_on_forward_move
    self.blocked_at = nil
    self.blocked_by = nil
    self.block_kind = nil
    self.blocked_from = nil
  end

  # Drop a review claim left from a previous review. After commit, so the claim
  # row's lock stays out of the task's save; best-effort, since raising would fail
  # the stage move.
  def clear_stale_review_claim_on_submit
    TaskReviewClaim.release_for_new_submission!(slug)
  rescue StandardError => e
    Rails.logger.warn("[review-claim] stale-claim clear failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  # A soul slug: lowercase letters with optional internal hyphens, no digits. That
  # shape tells it from a session id with no Agent lookup.
  SOUL_SLUG = /\A[a-z]+(?:-[a-z]+)*\z/

  # The roster of souls that exist. SOUL_SLUG asks "does it look like a handle";
  # this asks "is it somebody", so a typo such as `--actor stefon` cannot stamp a
  # builder who excludes nobody. It registers identities, not review seats
  # (ReviewerSelector::POOL decides those), so `pokemon`, the general builder, is
  # here. The static list is the floor: .soul_roster unions seeded Agent slugs,
  # and the floor survives a DB outage. It is read from config/souls.yml, the file
  # db/seeds/02_agents.rb seeds from, so a seeded soul is always on the floor.
  SOUL_ROSTER = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls")
                    .map { |soul| soul.fetch("slug") }.freeze

  # Retired slugs that still resolve on read: `alex` became `xan` (the human owner
  # is Alex). Nothing writes the legacy slug; every stamp goes through
  # .canonical_soul. Retire the alias one release after the rename.
  SOUL_ALIASES = { "alex" => "xan" }.freeze

  # The slug a soul is recorded under: an alias resolves to its successor, anything
  # else passes through stripped. Every soul stamp calls this.
  def self.canonical_soul(slug)
    value = slug.to_s.strip
    SOUL_ALIASES.fetch(value, value)
  end

  # Every soul slug this deployment recognises: the floor plus seeded agents. A
  # lookup error degrades to the floor, which names every soul in config/souls.yml.
  # Memoized per request
  # (Current.soul_roster).
  def self.soul_roster
    Current.soul_roster ||= begin
      (SOUL_ROSTER + Agent.pluck(:slug).map(&:to_s).select { |s| s.match?(SOUL_SLUG) }).uniq
    rescue StandardError
      SOUL_ROSTER.dup
    end
  end

  # A soul that exists: the right shape and on the roster, an alias counting as its
  # successor. The authorship guards ask this; #disowned? asks SOUL_SLUG alone.
  def self.soul?(slug)
    value = canonical_soul(slug)
    value.match?(SOUL_SLUG) && soul_roster.include?(value)
  end

  # Stamp devops.built_by, the soul slug the reviewer pool excludes. An invariant
  # of the build claim, not of the stage change, so a re-claim at `building`
  # stamps too. Two halves:
  #   STAMP  — on a build claim (#build_claim_save?), record #builder_to_stamp.
  #            Other saves carrying a soul actor do not make a builder.
  #   DEFEND — on any save, carry the stored builder forward, so a client cannot
  #            erase it by posting it blank (test/integration/builder_stamp_api_test.rb).
  def enforce_builder_stamp
    # An explicit devops teardown is left alone; this defends the key, not the hash.
    # Same posture as #stamp_build_claim_session.
    return unless metadata.is_a?(Hash) && metadata["devops"].is_a?(Hash)

    claim = build_claim_save?
    named = (builder_to_stamp if claim)
    # A reviewer who takes the build joins the author set but never becomes built_by:
    # over-excluding refuses, while a reviewer recorded as builder seats wrongly.
    soul = (named unless reviewer_taking_the_build?(named)) ||
           self.class.canonical_soul(prior_devops["built_by"]).presence
    authors = builder_roll_call(claim, named, soul)

    return if soul.nil? && authors.empty?
    return if metadata["devops"]["built_by"].to_s == soul.to_s &&
              Array(metadata["devops"]["builders"]) == authors

    merged = metadata.deep_dup
    merged["devops"]["built_by"] = soul if soul
    if authors.any?
      merged["devops"]["builders"] = authors
    else
      merged["devops"].delete("builders")
    end
    self.metadata = merged
  end

  # The author set. `built_by` holds the current builder; `builders` accumulates
  # every author, append-only and deduped, seeded from the stored built_by. It is
  # server-owned (not in DEVOPS_KEYS) and rebuilt from the prior record on every
  # save, so a client cannot shrink or forge it. A claim or submit naming no soul
  # adds nobody; git-derived authors cover that (Task#derived_authors). Authorship
  # moments: the claim, the submit, and a fix-forward.
  def builder_roll_call(claim, named, soul)
    # The stored built_by joins too, read apart from `soul`, which on a re-pointing
    # claim is already the new soul. Read through canonical_soul so aliases dedupe.
    authors = (Array(prior_devops["builders"]) + [prior_devops["built_by"]])
              .map { |s| self.class.canonical_soul(s) }.select { |s| self.class.soul?(s) }.uniq
    soul = self.class.canonical_soul(soul) if soul
    authors |= [soul] if soul && self.class.soul?(soul)

    if claim
      authors |= [named] if named
    elsif submit_save?
      # The author is not always the claimer: after a session-limit handover, a soul
      # that never claimed writes the diff. `--actor <soul>` on the submit adds that
      # soul; a bare submit adds nobody.
      actor = Current.task_event_actor.to_s.strip
      authors |= [actor] if self.class.soul?(actor)
    end

    # The third moment: a reviewer's fix-forward. Folded here for the same
    # append-only, server-owned guarantees, and kept out of `built_by`. Unconditional:
    # it reads a recorded list, so re-folding is idempotent. Non-soul entries are
    # read by ReviewerSelector instead (#devops_fix_forward).
    authors | fix_forward_authors
  end

  # Souls named by `devops.fix_forward`, this save and the prior record unioned, so
  # the recording write stamps and a later write cannot drop one.
  def fix_forward_authors
    current = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
    (Array(current["fix_forward"]) + Array(prior_devops["fix_forward"]))
      .map { |slug| slug.to_s.strip }.select { |slug| self.class.soul?(slug) }.uniq
  end

  # True when this save lands the task on `submitted`. Keyed on the transition:
  # later writes to a submitted task are not authorship moments.
  def submit_save?
    stage == "submitted" && will_save_change_to_stage?
  end

  # True when this save is a build claim: the task lands or sits on `building` and
  # the save moves it there or names `stage: building` (Current.task_build_claim),
  # the two shapes of `bin/task move <slug> building`. The desk is the build claim
  # (bin/lib/desk_claim.rb). Not a claim: a block! (blocked_at landing in this
  # save) or the reviewing session's unnamed write (#reviewing_party_renewal?).
  def build_claim_save?
    return false unless stage == "building"
    return false if will_save_change_to_blocked_at? && blocked_at.present?
    return false if reviewing_party_renewal?
    return true if will_save_change_to_stage?

    Current.task_build_claim ? true : false
  end

  # The reviewing session's write that names no soul: a liveness ping, swallowed.
  # A write naming a soul is an assertion of authorship and is recorded, which
  # keeps the documented `bin/task move <slug> building --actor <soul>` repair
  # working for a reviewer holding the claim. A reviewer naming himself is
  # recorded as an author only (#reviewer_taking_the_build?).
  def reviewing_party_renewal?
    return false if self.class.soul?(Current.task_event_actor.to_s.strip)

    reviewing_party_claim?
  end

  # True when the session in the incoming claim holds this task's live review
  # claim (TaskReviewClaim). A build claim and a lease renewal arrive in one shape,
  # so this is the seam between them; it keeps a bounced task's reviewer from
  # becoming a recorded worker. Safe to ask: .acquire refuses a review claim by
  # any author (.self_review?). bin/task's #heartbeat_may_claim? stops the renewal
  # client-side; this makes it a property of the board. A lookup failure answers
  # false. Not memoized: claims come and go between saves of one instance.
  def reviewing_party_claim?
    live_reviewing_party_claim.present?
  end

  # The live TaskReviewClaim when the incoming claim's session holds it, else nil
  # (nil on lookup failure too). The row, because #reviewer_taking_the_build? reads
  # its holder. Not memoized, for the reason above; at most two indexed reads per
  # save of a `building` task.
  def live_reviewing_party_claim
    session = claiming_session.to_s.strip
    return nil if session.empty?

    review = TaskReviewClaim.find_by(task_slug: slug)
    return nil unless review.present? && review.live? &&
                      review.claimed_session.to_s.strip == session

    review
  rescue StandardError => e
    Rails.logger.warn("[builder-stamp] review-claim lookup failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  # True when the live review claim cannot clear the soul this save names as
  # builder, so built_by must not move to it:
  #   no live claim from this session      → false (an ordinary handoff)
  #   the holder is this soul              → true  (a reviewer taking the build)
  #   nameless or off-roster claim holder  → true  (it cannot rule him out)
  # `--agent` is optional on every acquire, so the nameless claim is a designed
  # state. `named` still joins devops.builders. Never widen this to any named
  # claim during a review; that blocks ordinary handoffs.
  def reviewer_taking_the_build?(named)
    return false unless self.class.soul?(named)

    claim = live_reviewing_party_claim
    return false if claim.nil?

    holder = claim.holder_agent.to_s.strip
    unless self.class.soul?(holder)
      Rails.logger.warn(
        "[builder-stamp] #{slug}: this task's live REVIEW claim names no reviewer, so it " \
        "cannot clear #{named}, who claimed the build from the session holding it. " \
        "Recorded as an AUTHOR (devops.builders); devops.built_by left alone. Name the " \
        "reviewer (bin/task review-claim acquire #{slug} --agent <soul>) or release the " \
        "review first (bin/task review-claim release #{slug})."
      )
      return true
    end
    return false unless holder.casecmp?(named.to_s.strip)

    Rails.logger.warn(
      "[builder-stamp] #{slug}: #{holder} holds this task's live REVIEW claim and claimed " \
      "the build. Recorded as an AUTHOR (devops.builders); devops.built_by left alone. " \
      "Release the review first: bin/task review-claim release #{slug}"
    )
    true
  end

  # The session making this build claim: the PATCH's event session, else an actor
  # that is a session id (not a soul or an email). nil when none is named.
  def claiming_session
    session = Current.task_event_session.to_s.strip
    return session if session.present?

    actor = Current.task_event_actor.to_s.strip
    return nil if actor.empty? || actor.include?("@") || self.class.soul?(actor)

    actor
  end

  # The soul to record as builder, or nil to leave built_by as is:
  #   1. a soul actor (`--actor <soul>`): always wins, so a re-claim re-points;
  #   2. else keep an existing built_by;
  #   3. else a soul persona (devops.persona; #sync_persona_identity);
  #   4. else a soul agent_slug, so a bare `move building` still records one
  #      (reviewer-select-exclude).
  # Every rule asks .soul?, the roster, so a typo resolves to nothing; nil means
  # unknown and ReviewerSelector fails closed. The result is canonical.
  def builder_to_stamp
    actor = Current.task_event_actor.presence
    return self.class.canonical_soul(actor) if actor && self.class.soul?(actor)
    # Rule 2 reads the stored builder too: a blank post or a raw whole-column write
    # must not let rules 3 and 4 re-point a recorded builder.
    return nil if devops["built_by"].presence || prior_devops["built_by"].presence

    [devops["persona"].to_s, agent_slug.to_s].find { |slug| self.class.soul?(slug) }
                                            &.then { |slug| self.class.canonical_soul(slug) }
  end

  # `set_initial_position` (the before_create seed) comes from
  # Studio::Board::Rankable: a new task lands at the top of its column.

  # Settle a waiting operator-approval request once the task is outside
  # APPROVAL_REQUEST_STAGES: at `reviewed` the desk serving the demo is
  # reclaimable, so the card's WAITING APPROVAL treatment must drop. An invariant
  # re-asserted on every save, not a transition event, so a later devops echo or a
  # late request cannot ride to `shipped`. Only "waiting" settles, and to "none",
  # never "approved": a settle must not invent an outcome nobody chose. In
  # before_save, so it rides the same UPDATE. Idempotent.
  def settle_operator_approval_past_request_window
    return if APPROVAL_REQUEST_STAGES.include?(stage)
    return unless approval_status == OPERATOR_APPROVAL_WAITING

    merged = metadata.deep_dup
    settled = (merged["devops"] ||= {})
    # Capture the request before it settles, for #record_unanswered_approval_request.
    @settled_approval_request = {
      "requested_by" => settled["approval_requested_by"].to_s.strip.presence || approval_requester_fallback,
      "requested_at" => settled["approval_requested_at"].to_s.strip.presence,
      "local_url" => settled["local_url"].to_s.strip.presence,
      "stage" => stage
    }
    settled["approval_status"] = OPERATOR_APPROVAL_NONE
    # Leave a receipt, so a dropped request is never silent. bin/task's move warning
    # compares it across the stage PATCH to tell a drop this move caused; `bin/task
    # show --verbose` prints it. Overwritten on each drop: the last one matters.
    settled["approval_request_dropped_at"] = Time.current.iso8601
    self.metadata = merged
  end

  def stamp_operator_approval_request
    return unless will_save_change_to_metadata?
    return unless devops["approval_status"] == OPERATOR_APPROVAL_WAITING
    return if (metadata_was || {}).dig("devops", "approval_status") == OPERATOR_APPROVAL_WAITING

    merged = metadata.deep_dup
    approval = (merged["devops"] ||= {})
    approval["approval_requested_at"] ||= Time.current.iso8601
    # Who asked, so the settle's note has someone to address; a caller-supplied value
    # wins.
    approval["approval_requested_by"] = approval["approval_requested_by"].to_s.strip.presence ||
                                        approval_requester_to_stamp
    self.metadata = merged
  end

  # The soul who opened a request: a soul actor, else the recorded builder, else
  # the persona or assignee. nil when none is a known soul.
  def approval_requester_to_stamp
    actor = Current.task_event_actor.presence
    return actor if actor && self.class.soul?(actor)

    approval_requester_fallback
  end

  # Without the actor: at the settle, the actor is whoever merged, not whoever asked.
  def approval_requester_fallback
    [devops["built_by"].to_s, devops["persona"].to_s, agent_slug.to_s].find { |slug| self.class.soul?(slug) }
  end

  # The settle leaves one note addressed to the soul that asked, saying the work
  # merged unanswered and how the operator can still answer
  # (surface-waiting-request-at-merge). Review may merge over a waiting request;
  # it must not swallow it. After commit and rescued to ErrorLog; the ivar clears
  # first so one object cannot post twice.
  def record_unanswered_approval_request
    request = @settled_approval_request
    @settled_approval_request = nil
    Activity.create!(task_slug: slug, activity_type: "comment",
                     description: self.class.unanswered_approval_note(slug, request),
                     metadata: { "kind" => "approval_request_unanswered",
                                 "addressed_to" => request["requested_by"] }.merge(request))
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  def self.unanswered_approval_note(slug, request)
    setter = request["requested_by"] || "the soul who asked (no setter on record)"
    # Archiving settles a request too, and nothing merged.
    how = request["stage"] == "archived" ? "It was archived" : "Review merged it without waiting (merging never blocks on a request)"
    "To #{setter}: this work reached `#{request["stage"]}` with your operator-approval " \
      "request UNANSWERED. #{how}, so the request settled to none. Requested at " \
      "#{request["requested_at"] || "an unrecorded time"} for " \
      "#{request["local_url"] || "no local URL"}. Mr. McRitchie can still answer: " \
      "bin/task update #{slug} --approval approved, or --approval changes_requested."
  end

  # Stamp approval_approved_at when approval flips to "approved", the close of the
  # window stamp_operator_approval_request opens (the /deployments chip reads it).
  # before_save, so it lands on the already-folded metadata.
  def stamp_operator_approval_approved
    return unless will_save_change_to_metadata?
    return unless devops["approval_status"] == OPERATOR_APPROVAL_APPROVED
    return if (metadata_was || {}).dig("devops", "approval_status") == OPERATOR_APPROVAL_APPROVED

    merged = metadata.deep_dup
    approval = (merged["devops"] ||= {})
    approval["approval_approved_at"] ||= Time.current.iso8601
    self.metadata = merged
  end

  # True when this save changed approval_status. The devops key is the write
  # surface and the column mirrors it, so this compares the key before the save
  # with the value after it, not the column: the save that first fills an
  # unbackfilled column moves the column but not the status.
  def saved_change_to_approval_status?
    return false unless saved_change_to_metadata?

    approval_status_before_last_save != approval_status
  end

  def approval_status_before_last_save
    before, = saved_change_to_metadata
    (before || {}).dig("devops", "approval_status").to_s.presence
  end

  def broadcast_operator_approval_change
    DeploymentsBroadcaster.approval_change(self)
  end

  def broadcast_block_change
    DeploymentsBroadcaster.block_change(self)
  end

  # devops.checks_run carries two namespaces. The author owns the tier tags
  # ("[unit] ..."), which a checks update replaces; bin/control-check owns the
  # "[control@<tree-hash>]" stamp that bin/dor-check grades for test-only. A write
  # supersedes an evidence lane only by supplying evidence for it, and a
  # pure-evidence write cannot supersede the author lines
  # (fast-check-preserves-checks). The rule lives in lib/cert_evidence.rb, shared
  # with the CLI.
  def preserve_cert_evidence
    return unless will_save_change_to_metadata?

    prior = Array((metadata_was || {}).dig("devops", "checks_run"))
    return if prior.empty?
    # An explicit devops teardown is left alone; this defends the namespace.
    return unless metadata["devops"].is_a?(Hash)

    incoming = Array(metadata.dig("devops", "checks_run"))
    preserved = CertEvidence.preserve(prior: prior, incoming: incoming)
    return if preserved == incoming

    merged = metadata.deep_dup
    merged["devops"]["checks_run"] = preserved
    self.metadata = merged
  end

  # The build claim is the desk (devops-v3 4b-i; bin/lib/desk_claim.rb).
  # devops.claimed_session survives as attribution, read by
  # #live_reviewing_party_claim; nothing expires or renews it:
  #   - a build-claim save stamps it from #claiming_session;
  #   - any other save on a `building` task keeps the stored value;
  #   - leaving `building` clears it.
  # RETIRED_LEASE_KEYS are dropped on every save.
  RETIRED_LEASE_KEYS = %w[claim_nonce claim_expires_at].freeze

  def stamp_build_claim_session
    devops = metadata.is_a?(Hash) ? metadata["devops"] : nil
    # An explicit devops teardown is left alone.
    return unless devops.is_a?(Hash)

    updated = devops.except(*RETIRED_LEASE_KEYS)
    claimer = claiming_session if stage == "building" && build_claim_save?
    kept = stage == "building" ? (claimer || prior_devops["claimed_session"].presence) : nil
    if kept
      updated["claimed_session"] = kept
    else
      updated.delete("claimed_session")
    end
    return if updated == devops

    self.metadata = metadata.merge("devops" => updated)
  end

  # The slug is the readable, immutable handle: it drives /tasks/<slug> and seeds
  # the worktree and branch. An explicit --slug, else the title (auto-suffixed),
  # else task-<hex>. `@custom_slug` marks a readable slug for the trickle-down.
  def generate_slug
    explicit = slug.present?
    base = (explicit ? slug : title).to_s.parameterize
    if base.present?
      # An explicit --slug stays as is (uniqueness reports a collision); a
      # title-derived one auto-suffixes.
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

  # A readable slug seeds worktree_slug and branch (feat/<slug>) when not given; a
  # hex slug does not.
  def default_devops_handles_from_slug
    return unless @custom_slug

    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    devops["worktree_slug"] = slug if devops["worktree_slug"].blank?
    devops["branch"] = "feat/#{slug}" if devops["branch"].blank?
  end

  # Give the task its session's Pokémon mascot, unique among live tasks. An
  # explicit --mascot is kept. No-ops when the deck is not seeded.
  def sync_session_mascot
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # A persona owns the mascot fields (sync_persona_identity stamped them).
    return if devops["persona"].to_s.strip.present?
    sid = devops["session_id"].to_s
    # Redraw only with no mascot yet or on a handoff to a different session; a
    # session-less task keeps its mascot.
    needs = devops["mascot"].blank? || (sid.present? && devops["mascot_session"].to_s != sid)
    return unless needs

    slug, shiny, gender = session_mascot_draw(sid)
    return unless slug
    devops["mascot"] = slug
    devops["mascot_session"] = sid
    # Stamp the signature color, type emoji and shiny flag so bin/statusline and the
    # context JSON can render the mascot without DB access.
    pokemon = Pokemon.find_by(slug: slug)
    devops["mascot_shiny"] = shiny
    devops["mascot_gender"] = gender
    devops["mascot_color"] = pokemon&.signature_color
    devops["mascot_emoji"] = pokemon&.status_emoji(shiny: shiny)
    # A fresh draw starts a fresh evolution line.
    devops.delete("mascot_stage")
  end

  # Copy each DEVOPS_MIRRORED_KEYS key into its column, on every validation and
  # save. The key is the source while both exist: every writer, old code included,
  # writes it, so a cleared key clears the column too.
  def mirror_devops_columns
    pending = @devops_column_writes
    @devops_column_writes = nil
    pending&.each { |key, text| write_devops_key(key, text) unless devops[key].to_s.strip.presence == text }
    source = metadata.is_a?(Hash) && metadata["devops"].is_a?(Hash) ? metadata["devops"] : {}
    DEVOPS_MIRRORED_KEYS.each do |key|
      next unless has_attribute?(key)

      value = source[key].to_s.strip.presence
      write_attribute(key, value) unless read_attribute(key) == value
    end
  end

  # Set or (blank) remove one devops key, as a fresh metadata hash so dirty
  # tracking sees the change.
  def write_devops_key(key, text)
    merged = (metadata || {}).deep_dup
    merged["devops"] = {} unless merged["devops"].is_a?(Hash)
    text ? merged["devops"][key] = text : merged["devops"].delete(key)
    self.metadata = merged
  end

  # Strip any devops key that shadows a column, on every save. Two layers on
  # purpose: normalize_devops_metadata raises at the front door, and this sheds in
  # silence for paths around it (a raw `metadata:` PATCH, legacy rows), where
  # raising would brick saves that never named the key. Keep both.
  def shed_column_shadow_keys
    return if metadata.blank?

    devops = metadata["devops"]
    return unless devops.is_a?(Hash)

    DEVOPS_COLUMN_KEYS.each_key { |key| devops.delete(key) }
  end

  # Carry the mascot handle across a write that blanked it (a blank post or a raw
  # `metadata:` write), so the next build-stage save does not redraw mid-task. A
  # real slug (--mascot) still wins.
  def restore_mascot_identity
    return if new_record?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})

    %w[mascot mascot_session].each do |key|
      next if devops[key].present? || prior_devops[key].blank?

      devops[key] = prior_devops[key]
    end
  end

  # Re-assert the server-owned mascot stamps (shiny, gender, color, emoji) and the
  # consumed evolution gate on every save: a whitelist echo or a raw `metadata:`
  # write drops them, and sync_session_mascot runs only on a build-stage change.
  # Shiny comes from SessionMascot (find_by, never .for, which would roll a new
  # one), else the prior record. Non-fatal: a mascot never fails a save.
  def sync_mascot_display
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # A persona owns the mascot fields; sync_persona_identity is authoritative.
    return if devops["persona"].to_s.strip.present?
    return if devops["mascot"].blank?

    # The consumed gate lives only on the prior record; losing it double-evolves.
    # Restored only for the same Pokémon: a redraw starts a fresh line.
    if devops["mascot_stage"].nil? && same_mascot_as_prior?(devops) && prior_devops["mascot_stage"]
      devops["mascot_stage"] = prior_devops["mascot_stage"]
    end
    shiny = mascot_shiny_source(devops)
    devops["mascot_shiny"] = shiny
    devops["mascot_gender"] = mascot_gender_source(devops)
    pokemon = Pokemon.find_by(slug: devops["mascot"])
    return unless pokemon # unseeded deck: keep the color/emoji we already carry

    devops["mascot_color"] = pokemon.signature_color
    devops["mascot_emoji"] = pokemon.status_emoji(shiny: shiny)
  rescue StandardError => e
    Rails.logger.warn("[mascot-display] stamp skipped (non-fatal): #{e.class}: #{e.message}")
  end

  # Shiny, cheapest source first: the stamp on the record, else SessionMascot, else
  # the prior record.
  def mascot_shiny_source(devops)
    return self.class.shiny_value?(devops["mascot_shiny"]) unless devops["mascot_shiny"].nil?

    sid = devops["mascot_session"].to_s.strip
    if sid.present? && SessionMascot.table_exists? &&
       (session_mascot = SessionMascot.find_by(session_id: sid))
      return session_mascot.shiny?
    end

    same_mascot_as_prior?(devops) && self.class.shiny_value?(prior_devops["mascot_shiny"])
  end

  # Gender, in #mascot_shiny_source's order. Key presence decides "stamped", since
  # nil (genderless) is a real answer.
  def mascot_gender_source(devops)
    return Pokemon.normalize_gender(devops["mascot_gender"]) if devops.key?("mascot_gender")

    sid = devops["mascot_session"].to_s.strip
    if sid.present? && SessionMascot.table_exists? &&
       (session_mascot = SessionMascot.find_by(session_id: sid))
      return Pokemon.normalize_gender(session_mascot.gender)
    end

    same_mascot_as_prior?(devops) ? Pokemon.normalize_gender(prior_devops["mascot_gender"]) : nil
  end

  # The devops hash as stored, untouched by an in-memory replace. Empty on create.
  def prior_devops
    (metadata_was || {})["devops"] || {}
  end

  # Whether this save keeps the stored mascot. False on create and on a redraw,
  # where the prior record describes a different Pokémon.
  def same_mascot_as_prior?(devops)
    prior = prior_devops["mascot"]
    prior.present? && prior == devops["mascot"]
  end

  # Evolve the task's copy of its mascot one step at a gate (reviewed, assembled),
  # if it still can; a gate with nowhere to go is still consumed. The session's
  # mascot is untouched. devops.mascot_stage records the consumed gate, so a
  # block-and-resubmit loop never double-evolves; it is not a client key.
  def evolve_stage_mascot
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # A persona never evolves.
    return if devops["persona"].to_s.strip.present?

    gate = Task::MASCOT_EVOLUTION_GATES[stage]
    return if gate.nil? || devops["mascot_stage"].to_i >= gate

    pokemon = Pokemon.find_by(slug: devops["mascot"].presence)
    return unless pokemon

    devops["mascot_stage"] = gate

    # Only the branches the mascot's gender allows (Pokemon#evolution_genders).
    evolved = pokemon.evolutions_for(mascot_gender).order(Arel.sql("RANDOM()")).first
    return unless evolved # nowhere to go — the gate is still consumed

    devops["mascot"] = evolved.slug
    devops["mascot_color"] = evolved.signature_color
    devops["mascot_emoji"] = evolved.status_emoji(shiny: mascot_shiny?)
  rescue StandardError => e
    Rails.logger.warn("[mascot-evolution] skipped (non-fatal): #{e.class}: #{e.message}")
  end

  # devops.persona (an agent slug, "act as Jasper") makes the mascot that soul
  # instead of the session's Pokémon, re-stamped on every save. These sentinels
  # (case-insensitive) clear it: `bin/task update <slug> --persona none`.
  PERSONA_CLEAR = %w[none clear off -].freeze

  def sync_persona_identity
    return unless Agent.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    raw = devops["persona"].to_s.strip
    return if raw.empty?

    agent = Agent.find_by(slug: raw.downcase)
    # A clear or an unknown soul drops the persona and redraws the session's Pokémon
    # inline, since sync_session_mascot's callback fires only on a stage change.
    if PERSONA_CLEAR.include?(raw.downcase) || agent.nil?
      devops.delete("persona")
      devops["mascot"] = nil
      devops["mascot_session"] = nil
      devops["mascot_shiny"] = nil
      devops["mascot_gender"] = nil
      devops["mascot_color"] = nil
      devops["mascot_emoji"] = nil
      devops.delete("mascot_stage")
      sync_session_mascot
      return
    end

    devops["mascot"] = agent.name
    devops["mascot_color"] = agent.status_color
    devops["mascot_emoji"] = agent.emoji
  end

  # Stamp devops.app_color from the first repository's App, so bin/statusline can
  # tint the app slug without DB access. Server-owned and re-derived each save.
  def sync_app_identity
    return unless App.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # The first repo on purpose: a tint is singular. Every gate and coverage check
    # reads the whole list.
    app_slug = self.class.normalize_devops_list(devops["repositories"]).first
    return if app_slug.blank?

    app = App.find_by(slug: app_slug)
    devops["app_color"] = app&.color
  end

  # [slug, shiny, gender] for this task's mascot: the session's stable draw
  # (SessionMascot), else a fresh task-local draw. [nil, false, nil] when nothing
  # can be drawn.
  def session_mascot_draw(sid)
    if sid.present? && (session_mascot = SessionMascot.for(sid))
      return [session_mascot.mascot_slug, session_mascot.shiny?, session_mascot.gender]
    end

    pick = Pokemon.draw(exclude: Task.active_mascots)
    pick ? [pick.slug, Pokemon.roll_shiny?, pick.roll_gender] : [nil, false, nil]
  end

  def word_count(text)
    text.to_s.split(/\s+/).reject(&:blank?).size
  end

  # True when the normalized acceptance list differs from the stored one, so
  # untouched tasks and other devops updates are not re-validated.
  # The rake TASK token `db:seed` (and `db:seed:replant` / any `db:seed:*`) as a
  # standalone word: the COLON is the tell. The scoped `db/seeds/NN.rb` (slash) and a
  # dedicated task like `pokemon:seed` do not match.
  BARE_SEED_TASK = %r{(?<![\w:/])db:seed(?::\w+)?(?![\w:/])}i

  def post_deploy_cmd_changed?
    (metadata_was || {}).dig("devops", "post_deploy_cmd") != devops["post_deploy_cmd"]
  end

  def post_deploy_cmd_is_not_a_bare_seed
    cmd = devops["post_deploy_cmd"].to_s
    return unless BARE_SEED_TASK.match?(cmd)

    errors.add(:base, "post_deploy_cmd #{cmd.inspect} is a bare full-suite seed — bin/release runs it " \
                      "VERBATIM against PRODUCTION, and db:seed loads EVERY db/seeds/*.rb. Declare a narrow " \
                      "command: a scoped single-file runner (rails runner 'load Rails.root.join(" \
                      "\"db/seeds/NN_x.rb\").to_s') or a dedicated idempotent rake task (bin/rails pokemon:seed)")
  end

  def acceptance_changed?
    previous = self.class.normalize_devops_list((metadata_was || {}).dig("devops", "acceptance"))
    previous != devops_acceptance
  end

  # Titles stay 3-5 words; detail belongs in agent_context.
  def title_within_word_range
    count = word_count(title)
    return if TITLE_WORD_RANGE.cover?(count)

    errors.add(:title, "must be #{TITLE_WORD_RANGE.first}-#{TITLE_WORD_RANGE.last} words " \
                       "(was #{count}) — name it tightly; put detail in agent_context")
  end

  # Coerce `dependencies` into the flat list of slug strings Release::Ordering
  # reads; `Array()` would turn a Hash into pairs that never match. Order is kept
  # (the operator's sequence); duplicates and blanks drop.
  def normalize_dependencies
    raw = dependencies
    list =
      case raw
      when nil then []
      when String then [raw]
      when Hash then raw.values
      else Array(raw)
      end
    self.dependencies = list.flatten.map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
  end

  # Canonicalize the epic handle on every save (Task.normalize_epic_slug).
  def normalize_epic_slug
    self.epic_slug = self.class.normalize_epic_slug(epic_slug)
  end

  # Every dependency must name a real, different task. Release::Ordering skips an
  # unknown slug and breaks a self-reference as a cycle, both silently, so the
  # write is refused instead.
  def dependencies_name_real_tasks
    entries = Array(dependencies)
    return if entries.empty?

    if entries.include?(slug.to_s)
      errors.add(:dependencies, "cannot include the task's own slug (#{slug}) — " \
                                "a self-dependency can never be satisfied, so the ordering pass discards it")
    end

    malformed = entries.reject { |entry| entry.match?(DEPENDENCY_SLUG) }
    if malformed.any?
      errors.add(:dependencies, "must be task slugs; #{malformed.map(&:inspect).join(", ")} " \
                                "#{malformed.one? ? "is not one" : "are not"}")
      return
    end

    known = Task.where(slug: entries).pluck(:slug)
    unknown = entries - known - [slug.to_s]
    return if unknown.empty?

    errors.add(:dependencies, "name no task on this board: #{unknown.map(&:inspect).join(", ")} — " \
                              "Release::Ordering silently ignores a dependency it cannot resolve, " \
                              "so the sequencing you declared would never happen")
  end

  # Each acceptance bullet stays 5-12 words.
  def acceptance_bullets_within_word_range
    devops_acceptance.each_with_index do |bullet, i|
      count = word_count(bullet)
      next if ACCEPTANCE_WORD_RANGE.cover?(count)

      errors.add(:base, "acceptance ##{i + 1} must be #{ACCEPTANCE_WORD_RANGE.first}-" \
                        "#{ACCEPTANCE_WORD_RANGE.last} words (was #{count}): #{bullet.to_s.truncate(48)}")
    end
  end
end
