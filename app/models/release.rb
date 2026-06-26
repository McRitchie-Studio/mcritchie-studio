class Release < ApplicationRecord
  # Workflow 2 — Deploy. A Release is a singleton: at most one is active
  # (assembling/assembled) at a time. It carries `reviewed` tasks onto a
  # disposable release branch, through QA, and to production.
  #   assembling → assembled → shipped   (+ abandoned)
  # The git/merge-queue mechanics live in the conductor tooling (a later task);
  # this model owns the state + the task membership.
  STATES = %w[assembling assembled shipped abandoned].freeze
  ACTIVE_STATES = %w[assembling assembled].freeze
  TERMINAL_STATES = %w[shipped abandoned].freeze

  # The per-repo integration branch. It is now PERSISTENT: every repo keeps a
  # single `release` branch that feature PRs merge INTO (membership flips at
  # merge), QA deploys from, and `ship` fast-forwards into `main`. main is always
  # an ancestor of `release`; on ship it collapses to main and re-accumulates.
  # (Was the disposable `release/<slug>` cut per candidate — see the cutover.)
  BRANCH = "release"

  # Per-step test-tier ownership for the Deploy workflow (devops-cycle-design
  # §1.2, "Test-tier → step map"). Each tier runs ONCE, at the step that OWNS it —
  # no step re-runs a lower tier a previous step already proved green:
  #   review  → base (unit/component), by the two senior reviewers
  #   prepare → integration + e2e-smoke, by Steffon on origin/release at QA
  #   ship    → full e2e (highest tier), by Avi on the FROZEN ship SHA
  # The ownership is disjoint by construction (a tier maps to exactly one step),
  # which is what makes "runs once" enforceable — see step_owning_tier.
  STEP_TEST_TIERS = {
    "review"  => %w[base],
    "prepare" => %w[integration e2e-smoke],
    "ship"    => %w[e2e-full]
  }.freeze

  has_many :tasks, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release

  validates :slug, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validate :at_most_one_active_release, if: :active?

  before_validation :generate_slug, on: :create
  before_save :set_state_timestamp, if: :state_changed?
  # Live /deployments: re-render the Next + Last release modules to every viewer
  # after ANY release commit (open / assemble / ship / abandon / mascot stamp), so
  # the board's release cards stay current with no reload. after_*_commit (not
  # after_save) so the new singleton state is fully committed before we read
  # Release.current / .last_shipped in the broadcast — and so a rolled-back
  # transaction never broadcasts a state that didn't land.
  after_commit :broadcast_release_modules, on: %i[create update]

  scope :active, -> { where(state: ACTIVE_STATES) }

  def to_param
    slug
  end

  # The test tiers a Deploy step OWNS (runs). Unknown step → []. The single
  # source of truth bin/release's per-step gates (prepare's e2e-smoke /up wait,
  # ship's full-e2e gate) are documented against.
  def self.test_tiers_for(step)
    STEP_TEST_TIERS.fetch(step.to_s, [])
  end

  # The one step that OWNS a tier (runs it), or nil. Enforces "each tier runs once
  # at the step that owns it" — a tier maps to exactly one step.
  def self.step_owning_tier(tier)
    STEP_TEST_TIERS.find { |_step, tiers| tiers.include?(tier.to_s) }&.first
  end

  # The current (singleton) active release, if any.
  def self.current
    active.order(created_at: :desc).first
  end

  # The most recently shipped release (for the board's "Last Release" section).
  def self.last_shipped
    where(state: "shipped").order(Arel.sql("COALESCE(shipped_at, created_at) DESC")).first
  end

  # Open a new release candidate. Raises (singleton validation) if one is active.
  # Defaults the integration branch to the persistent `release` (overridable).
  def self.open!(attrs = {})
    create!({ branch: BRANCH }.merge(attrs).merge(state: "assembling"))
  end

  # The active release if one exists, else open a fresh one. The find-or-create
  # the merge-time membership path (Conductor#adopt!) leans on so a PR merging
  # into `release` always lands on an active candidate.
  def self.current_or_open!
    current || open!
  end

  def active?
    ACTIVE_STATES.include?(state)
  end

  # --- conductor mascot (the agent working this deployment) -------------------
  # A release wears the Pokémon mascot of the SESSION that ran `bin/release` on
  # it (mirrors Task's per-session mascot). Stored loosely in metadata.devops —
  # `mascot` (slug) + `mascot_session` (the owning session id) — so the board can
  # show who's on the deployment and the same session keeps its face across
  # merge/prepare/ship while a handoff swaps it.

  # The metadata.devops sub-hash, always a Hash (never nil) for safe reads.
  def devops
    raw = metadata.is_a?(Hash) ? metadata["devops"] : nil
    raw.is_a?(Hash) ? raw : {}
  end

  # One devops scalar, or nil when blank/absent.
  def devops_field(key)
    devops[key.to_s].presence
  end

  # The conductor's Pokémon, resolved from the stored mascot slug (nil when
  # unstamped — old releases, or no session — so the card degrades gracefully).
  def mascot
    slug = devops_field("mascot")
    return nil if slug.blank?

    @mascot ||= Pokemon.find_by(slug: slug)
  end

  # Stamp the conductor session's mascot onto the release, drawing/reusing it via
  # SessionMascot.for (the same race-safe lookup tasks use). Idempotent and
  # handoff-aware, mirroring Task#sync_session_mascot: it (re)assigns only when no
  # mascot is set yet OR a DIFFERENT session is now acting — so re-running the
  # conductor in the same session is a no-op, but a handoff swaps the face. A
  # blank session, an unseeded Pokémon table, or a draw that yields nothing all
  # leave the release untouched (no mascot rather than a crash). Returns self.
  def stamp_conductor_mascot!(session_id)
    sid = session_id.to_s.strip
    return self if sid.empty?
    return self unless Pokemon.table_exists?
    return self unless devops_field("mascot").blank? || devops_field("mascot_session") != sid

    slug = SessionMascot.for(sid)&.mascot_slug
    return self unless slug

    meta = (metadata.presence || {}).deep_dup
    d = (meta["devops"] ||= {})
    d["mascot"] = slug
    d["mascot_session"] = sid
    update!(metadata: meta)
    @mascot = nil # bust the memo so a re-read reflects the swap
    self
  end

  # Member tasks in PRODUCER-FIRST order: gems (published) before apps
  # (deployed), honoring task `dependencies` within that. This is the order the
  # conductor publishes/deploys in and the order `member_plan` reports.
  def ordered_members
    Release::Ordering.producer_first(tasks.to_a)
  end

  def shipped?
    state == "shipped"
  end

  # Attach a reviewed task to this (assembling) release. The TASK's stage becomes
  # `assembled` (its PR is now riding the train) — the release's own state is
  # unchanged. The actual branch merge + per-merge tests are the conductor's job;
  # this is the membership + stage bookkeeping.
  #
  # `override: true` is the explicit, audited escape hatch for
  # `bin/release merge --override` — it skips the `reviewed` precondition so an
  # operator can carry a not-yet-reviewed PR onto the train. The review skip is
  # itself recorded on the audit spine (Conductor.adopt! stamps
  # Current.task_event_review_bypass, drained onto the assembled transition), so
  # the bypass is never silent.
  def add(task, override: false)
    # Validate the task BEFORE mutating release state, so adopting a non-reviewed
    # task onto an assembled RC doesn't needlessly reopen it. `override` is the
    # only path that may attach a non-reviewed task (audited by adopt!).
    unless override || task.stage == "reviewed"
      raise ArgumentError, "task #{task.slug} is not reviewed (stage: #{task.stage})"
    end

    # On the durable `release` branch a PR can merge AFTER we've assembled (QA'd)
    # the candidate. That late merge must re-open the RC so it re-assembles and
    # re-QAs before shipping — so absorb an assembled state by reopening, rather
    # than refusing the member.
    #
    # Atomic: the reopen and the member flip are ONE unit. The conductor's
    # late-merge caller (Conductor.adopt! ← `bin/release merge`) runs `add`
    # standalone with no enclosing transaction (unlike prepare!/curate!), so
    # without this wrapper a failed member flip would leave the RC reopened
    # (assembling) with the member never attached — a DISTINCT half-state from the
    # adopt! no-op the incident actually hit (that one — member attached but stage
    # regressed to reviewed — is healed by adopt!'s reconciliation, not here); this
    # wrapper is defense-in-depth against a never-observed second mode.
    transaction do
      reopen! if state == "assembled"
      raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

      task.update!(release_slug: slug, stage: "assembled")
    end
    task
  end

  # Every member in + tests check out → the RC is complete.
  def assemble!
    raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

    update!(state: "assembled")
  end

  # The operator "Makes the release" → ship to prod; members flip to `shipped`.
  # Allowed from an active release (assembling or assembled); never from terminal.
  #
  # `usage_by_slug` is the optional { slug => {model, tokens_in, tokens_out, cost} }
  # best-effort per-member usage for the assembled→shipped transition (captured by
  # bin/release from the conductor's local transcript). Each member's ship! runs
  # inside Current.with_task_event_usage, which stamps that member's shipped
  # TaskEvent and clears the fields afterward so the next member isn't
  # mis-attributed. A member with no entry records the deterministic spine only.
  def ship!(by: nil, usage_by_slug: {})
    raise ArgumentError, "release #{slug} is already terminal (state: #{state})" unless active?

    usage_by_slug ||= {}
    transaction do
      update!(state: "shipped", confirmed_by: by, confirmed_at: Time.current)
      tasks.to_a.each do |task|
        Current.with_task_event_usage(usage_by_slug[task.slug]) { task.ship! }
      end
    end
  end

  # Pull an assembled RC back to `assembling` so more reviewed work can be added.
  # Adding members invalidates the prior QA pass, so the RC must re-assemble (and
  # re-QA) before it can ship. This is what lets `Prepare release` be additive
  # instead of refusing when a release is already in flight.
  def reopen!
    raise ArgumentError, "release #{slug} is not assembled (state: #{state})" unless state == "assembled"

    update!(state: "assembling")
  end

  # Discard a stuck RC → members fall back to `reviewed` (off the train), and the
  # singleton frees up for a fresh release.
  #
  # NOTE: this only drops BOARD membership. On the DURABLE per-repo `release`
  # branch the git-side remediation — reverting each abandoned member's merge
  # commit on `release` (never a force-push, since `release` is permanent and
  # shared) — is owned by the conductor/CLI as a documented step. The model never
  # touches git.
  def abandon!
    raise ArgumentError, "release #{slug} is already terminal (state: #{state})" unless active?

    transaction do
      tasks.to_a.each { |task| task.update!(stage: "reviewed", release_slug: nil) }
      update!(state: "abandoned")
    end
  end

  private

  def at_most_one_active_release
    scope = Release.where(state: ACTIVE_STATES)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:state, "another release is already active") if scope.exists?
  end

  def set_state_timestamp
    case state
    when "assembled" then self.assembled_at = Time.current
    when "shipped"   then self.shipped_at = Time.current
    when "abandoned" then self.abandoned_at = Time.current
    end
  end

  def generate_slug
    self.slug ||= "rel-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(3)}"
  end

  # Push the refreshed release modules to the live /deployments board. Delegates to
  # the broadcaster, which is itself wrapped in Studio::Cable.safe_broadcast, so
  # this after_commit can never raise into the release write.
  def broadcast_release_modules
    DeploymentsBroadcaster.release_modules
  end
end
