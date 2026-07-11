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

  # --- stage timeline ----------------------------------------------------------
  # The ordered fine-grained stage sequence under the coarse `state` machine. Each
  # stage maps to ONE timestamp column that acts as a time-AND-boolean: stamped =
  # the stage started (or landed), blank = not yet. The /deployments pizza-tracker
  # derives every node's complete/active/pending purely from these stamps, which
  # is what makes the Steffon→Avi QA handoff explicit: `qa_deployed` (Live on QA,
  # 3 green) does NOT imply `confirming` — stage 4 stays dark until Avi's
  # confirming stamp lands (via the release events API).
  #
  # `current_stage` is MONOTONIC — the LATEST stamped stage wins — so late or
  # out-of-order stamps (e.g. the conductor's post-QA-boot assemble! landing after
  # deploy_qa completed) can never wind the tracker backwards.
  STAGES = [
    ["testing",        :testing_started_at],
    # tested_at is VESTIGIAL: the conductor no longer posts review_tests
    # completed (the G3 Candidate gate_runs own prepare's test verdicts), so
    # nothing stamps it anymore. Kept for historical rows + API replay
    # (EVENT_STAGE_STAMPS still maps it); drop in a later cleanup.
    ["tested",         :tested_at],
    ["assembling",     :assembling_started_at],
    ["assembled",      :assembled_at],
    ["qa_deploying",   :qa_deploy_started_at],
    ["qa_deployed",    :qa_deployed_at],
    ["confirming",     :confirming_started_at],
    ["confirmed",      :confirmed_at],
    ["prod_deploying", :prod_deploy_started_at],
    ["shipped",        :shipped_at]
  ].freeze
  STAGE_NAMES = STAGES.map(&:first).freeze
  STAGE_STAMP_COLUMNS = STAGES.to_h { |name, column| [name.to_s, column] }.freeze

  # The one stage an event post may OPEN the slug-less `current` release from:
  # ASSEMBLY START. A candidate is born when qa-release begins assembling (the
  # sweep's current_or_open! / an `assembling` kick-off) — never during the review
  # wave, which runs before any release exists. `testing` used to open here too,
  # which surfaced an empty (0-task) `assembling` release on /deployments minutes
  # before qa-release ran; so a testing/start with no active RC is now a clean 404.
  # Any other (later) stage also requires an already-active release.
  STAGES_THAT_MAY_OPEN = %w[assembling].freeze

  # The stages surfaced as columns on the /deployments table + summary cards. Two
  # shapes:
  #   * stamp-backed — the stage's OWN start→end stamp pair (a span of
  #     Release::STAGES), so the cell shows both timestamps and the duration.
  #   * gate-backed (`gate:`) — the LATEST GateRun attempt of a release-grain
  #     testing gate (G3 Candidate / G4 Ship). Attempt-aware: the span carries
  #     `:success` (fail tint) and `:attempt` (the ×n retry badge), fixing the
  #     old overlap where prepare co-opted the review_tests bracket and "Tested"
  #     started AFTER "Assembled".
  # "Deployed" is the production rollout (prod_deploy_started_at → shipped_at);
  # the end-to-end "Total" (created_at → shipped_at) is #deployment_total_span.
  DEPLOYMENT_STAGES = [
    { key: "assembled",    label: "Assembled",    starts: :assembling_started_at, ends: :assembled_at },
    { key: "g3_candidate", label: "G3 Candidate", gate: "g3_candidate" },
    { key: "g4_ship",      label: "G4 Ship",      gate: "g4_ship" },
    { key: "deployed",     label: "Deployed",     starts: :prod_deploy_started_at, ends: :shipped_at }
  ].freeze

  # How many recently-shipped releases the /deployments summary cards average.
  DEPLOYMENT_DASHBOARD_SAMPLE = 10

  # (release-event step, status) → the stage that boundary stamps. Every write
  # path funnels through record_event! (conductor CLI + the release events API),
  # so posting an event IS the stage notification. `failed` events stamp nothing.
  # deploy_prod completion is deliberately absent: `shipped` is only ever stamped
  # by ship!'s state flip, so a stray API post can't mark a live release shipped.
  # The review_tests → testing/tested mapping stays for event replay + a
  # testing/start posted against an ALREADY-active release (a first-write-wins
  # no-op once assembling has stamped). It no longer OPENS a candidate
  # (STAGES_THAT_MAY_OPEN): node 1 Testing greens on its own the instant the first
  # sweep stamps `assembling` (which is ≥ testing), so no pre-assembly post needed.
  EVENT_STAGE_STAMPS = {
    %w[review_tests started]       => "testing",
    %w[review_tests completed]     => "tested",
    %w[assemble_release started]   => "assembling",
    %w[assemble_release completed] => "assembled",
    %w[deploy_qa started]          => "qa_deploying",
    %w[deploy_qa completed]        => "qa_deployed",
    %w[qa_smoke completed]         => "qa_deployed",
    %w[ship_gate started]          => "confirming",
    %w[ship_authorized started]    => "confirming",
    %w[ship_gate completed]        => "confirmed",
    %w[ship_authorized completed]  => "confirmed",
    %w[deploy_prod started]        => "prod_deploying"
  }.freeze

  # Per-step test-tier ownership for the Deploy workflow (devops-cycle-design
  # §1.2, "Test-tier → step map"). Each tier runs ONCE, at the step that OWNS it —
  # no step re-runs a lower tier a previous step already proved green:
  #   review  → base (unit/component), by the two senior reviewers
  #   prepare → integration + e2e-smoke, by Steffon on origin/release at QA
  #             (the hub registers its FULL suite as qa_test_cmd — the G3 batch
  #             certification that lets G4 self-gate an unchanged SHA)
  #   ship    → full-suite (the registry test_cmd — the repo's highest LOCAL
  #             tier; it was never a browser e2e run, hence the honest relabel
  #             from "e2e-full"), by Avi on the FROZEN ship SHA. SELF-GATED:
  #             skipped when G3 already certified that exact SHA with that
  #             exact command this run (bin/release test_gate), so the full
  #             suite runs once per release batch; a drifted/straggler SHA
  #             re-triggers it.
  # The ownership is disjoint by construction (a tier maps to exactly one step),
  # which is what makes "runs once" enforceable — see step_owning_tier.
  STEP_TEST_TIERS = {
    "review"  => %w[base],
    "prepare" => %w[integration e2e-smoke],
    "ship"    => %w[full-suite]
  }.freeze

  has_many :tasks, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release
  has_many :release_events, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release, dependent: :destroy
  # Attempt-aware runs of the release-owned testing gates (G3 Candidate, G4
  # Ship) — slug-FK like release_events, scoped to release-grain subjects.
  has_many :gate_runs, -> { where(subject_type: "release") },
           foreign_key: :subject_slug, primary_key: :slug, dependent: :delete_all

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
  after_commit :refresh_duration_metrics_safely, on: %i[create update]

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
  # the sweep membership path (Conductor#sweep!) leans on so a PR merging
  # into `release` always lands on an active candidate.
  def self.current_or_open!
    current || open!
  end

  def active?
    ACTIVE_STATES.include?(state)
  end

  # --- deployment table spans -------------------------------------------------
  # One /deployments cell: a stage's own start→end span read straight off the
  # stamp columns — or, for a gate-backed stage, off the latest GateRun attempt.
  # status is "completed" (both boundaries), "in_progress" (started, not
  # finished, release still active → the cell ticks a live count-up), or
  # "missing" (never started → the cell reads "—"). Pure column arithmetic, so
  # it is always current (no cache) and the live anchor is real.
  def deployment_stage_span(stage)
    stage = DEPLOYMENT_STAGES.find { |candidate| candidate[:key] == stage.to_s } if stage.is_a?(String) || stage.is_a?(Symbol)
    return deployment_gate_span(stage) if stage[:gate]

    started_at = self[stage.fetch(:starts)]
    ended_at = self[stage.fetch(:ends)]
    deployment_span(stage.fetch(:key), stage.fetch(:label), started_at, ended_at)
  end

  # A gate-backed /deployments cell: the LATEST GateRun attempt of the stage's
  # release-grain gate (retries are first-class — the newest attempt IS the
  # cell). Same span contract as a stamp-backed stage, plus two gate keys:
  #   :success — the attempt's verdict (false → the cell tints red with a ✗;
  #              nil while in flight)
  #   :attempt — the attempt number (> 1 → the ×n retry badge)
  # No run yet → a "missing" dash, like an unstamped column.
  def deployment_gate_span(stage)
    run = latest_gate_run(stage.fetch(:gate))
    span = deployment_span(stage.fetch(:key), stage.fetch(:label), run&.started_at, run&.finished_at)
    span[:success] = run&.success
    span[:attempt] = run&.attempt
    span
  end

  # The newest attempt of a release-grain gate, filtered in Ruby off the
  # gate_runs association so releases#index can `.includes(:gate_runs)` and
  # render every row's G3/G4 cells with no per-release query.
  def latest_gate_run(key)
    gate_runs.select { |run| run.key == key.to_s }.max_by { |run| [run.attempt, run.id] }
  end

  def deployment_stage_spans
    DEPLOYMENT_STAGES.map { |stage| deployment_stage_span(stage) }
  end

  # The end-to-end Total cell: created_at → shipped_at, or created_at → now (live)
  # while the release is still active. Same contract as a stage span.
  def deployment_total_span
    deployment_span("total", "Total", created_at, shipped_at)
  end

  # Averages each deployment stage (+ Total) over the last N shipped releases —
  # the summary cards. Same span math as the per-row cells, so cards and columns
  # can never disagree.
  def self.deployment_stage_averages(limit: DEPLOYMENT_DASHBOARD_SAMPLE)
    releases = where(state: "shipped")
               .order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
               .includes(:gate_runs) # the gate-backed spans read the association
               .limit(limit).to_a
    keys = DEPLOYMENT_STAGES.map { |stage| stage[:key] } + ["total"]
    stage_rows = keys.map do |key|
      spans = releases.map { |release| key == "total" ? release.deployment_total_span : release.deployment_stage_span(key) }
      label = key == "total" ? "Total" : DEPLOYMENT_STAGES.find { |stage| stage[:key] == key }.fetch(:label)
      [key, deployment_average_row(label, spans.filter_map { |span| span[:seconds] })]
    end
    { "stages" => stage_rows.to_h, "sample_count" => releases.size }
  end

  def self.deployment_average_row(label, values)
    { "label" => label,
      "average_seconds" => (values.any? ? (values.sum.to_f / values.size).round : nil),
      "sample_count" => values.size }
  end

  # Shared span builder for #deployment_stage_span / #deployment_total_span.
  def deployment_span(key, label, started_at, ended_at)
    status = if started_at && ended_at then "completed"
             elsif started_at && active? then "in_progress"
             else "missing"
             end
    seconds = started_at && ended_at ? [(ended_at - started_at).to_i, 0].max : nil
    { key: key, label: label, started_at: started_at, ended_at: ended_at, seconds: seconds, status: status }
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

  # --- production smoke seal --------------------------------------------------
  # The post-ship @qa-readonly verdict (bin/prod-smoke), persisted on the release
  # as the smoke_seal jsonb. The reader rehydrates the raw column into a
  # Release::SmokeSeal value object (nil when unsealed); record_smoke_seal! stores
  # one. Recorded in bin/release step 5c AFTER the deploy + /up gate, BEFORE
  # post_release_notes — so the notes/Discord/board all read the SAME verdict.

  # The seal as a value object, or nil when unsealed. Overrides the AR-generated
  # attribute reader; `self[:smoke_seal]` still reads the raw jsonb underneath.
  def smoke_seal
    Release::SmokeSeal.from_h(self[:smoke_seal])
  end

  def smoke_sealed?
    smoke_seal.present?
  end

  # Persist a Release::SmokeSeal (its {status, summary, checked_at} hash). The
  # after_commit broadcast re-renders the board so the 🟢/🔴 badge appears live.
  def record_smoke_seal!(seal)
    update!(smoke_seal: seal.to_h)
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

  # --- stage timeline reads/writes ---------------------------------------------

  # The stage's stamp (time-and-boolean): a Time when reached, nil when not.
  def stage_stamp(stage)
    column = STAGE_STAMP_COLUMNS.fetch(stage.to_s) do
      raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})"
    end
    self[column]
  end

  # A stage's "started at" for the tracker: its own start stamp when present,
  # else the nearest EARLIER stamped boundary as a lower-bound estimate (a stage
  # starts no sooner than the latest upstream stamp), falling back to the
  # release's open time as the floor. So every reached tracker node always has a
  # started_at even when its own start event was never posted — testing/review
  # and assembling starts are frequently un-instrumented or arrive late (see the
  # STAGES comment above), which otherwise left those nodes' timing blank.
  def stage_started_at_or_before(stage)
    index = STAGE_NAMES.index(stage.to_s)
    raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})" unless index

    index.downto(0) do |i|
      stamp = self[STAGES[i].last]
      return stamp if stamp.present?
    end
    created_at
  end

  # Index of the furthest stamped stage (monotonic: the LATEST stage wins, so a
  # late upstream stamp never regresses it). nil when nothing is stamped yet. A
  # shipped STATE counts as the terminal stage even if shipped_at was never set
  # (legacy rows), so a shipped release always reads fully complete.
  def current_stage_index
    index = STAGES.rindex { |name, _column| stage_stamp(name).present? }
    return STAGES.length - 1 if shipped?

    index
  end

  # The furthest stage name, or nil when the timeline is untouched.
  def current_stage
    index = current_stage_index
    index && STAGES[index].first
  end

  # true when the timeline is AT or PAST the stage. The tracker's per-node
  # complete/active/pending derives from exactly this.
  def stage_reached?(stage)
    target = STAGE_NAMES.index(stage.to_s)
    raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})" unless target

    index = current_stage_index
    index.present? && index >= target
  end

  # All stamps keyed by stage name (nil values included) — the API's stage
  # snapshot, so an agent posting an update sees the whole timeline it moved.
  def stage_stamps
    STAGES.to_h { |name, column| [name, self[column]] }
  end

  # Stamp a stage boundary. FIRST-WRITE-WINS: a stamped stage is immutable, so
  # replays and idempotent re-runs never rewrite history. Persisting the stamp
  # broadcasts the release modules (after_commit), which is what flips the live
  # /deployments tracker for every viewer. Returns self.
  def stamp_stage!(stage, at: Time.current)
    column = STAGE_STAMP_COLUMNS.fetch(stage.to_s) do
      raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})"
    end
    return self if self[column].present?

    update!(column => at)
    self
  end

  def record_event!(step:, status:, **attrs)
    event = ReleaseEvent.record!(release: self, step: step, status: status, **attrs)
    stamp_stage_for_event(step, status, at: event.occurred_at)
    event
  end

  def refresh_duration_metrics!
    Release::DurationCache.refresh!(self)
  end

  def refresh_duration_metrics_safely
    return unless persisted?

    refresh_duration_metrics!
  rescue StandardError => e
    Rails.logger.warn("[release-duration-cache] refresh failed for #{slug}: #{e.class}: #{e.message}")
  end

  def event_completed?(step)
    release_events.for_step(step).completed.exists?
  end

  def event_started?(step)
    release_events.for_step(step).started.exists?
  end

  # Attach (SWEEP) a task onto this (assembling) release: set its `release_slug`
  # and stamp `merged: "release"` (its PR is now riding the persistent `release`
  # branch). The task's STAGE does NOT move here — under the Steffon-owns-the-
  # middle flow (2026-07-03) a member flips `reviewed → assembled` only on
  # QA-green (`Release::Conductor.qa_green!`), so a QA-deploy failure leaves it
  # `reviewed` for the next self-healing sweep. The actual branch merge + the
  # pre-QA tests are the conductor/CLI's job; this is the membership bookkeeping.
  #
  # Eligible stages: `reviewed` (the standard sweep) and `assembled` (a
  # STRAGGLER — an already-QA-green member a prior RC left behind; it re-attaches
  # without moving and re-QAs with the new candidate).
  #
  # `override: true` is the explicit, audited escape hatch for
  # `bin/release merge --override` — it skips the stage precondition so an
  # operator can carry a not-yet-reviewed PR onto the train. The review skip is
  # itself recorded on the audit spine (Conductor.sweep! flips the target to
  # `reviewed` with Current.task_event_review_bypass stamped on that transition),
  # so the bypass is never silent.
  def add(task, override: false)
    # Validate the task BEFORE mutating release state, so sweeping an ineligible
    # task onto an assembled RC doesn't needlessly reopen it. `override` is the
    # only path that may attach an ineligible-stage task (audited by sweep!).
    unless override || %w[reviewed assembled].include?(task.stage)
      raise ArgumentError, "task #{task.slug} is not sweepable (stage: #{task.stage})"
    end

    # On the durable `release` branch a PR can merge AFTER we've assembled (QA'd)
    # the candidate. That late sweep must re-open the RC so it re-assembles and
    # re-QAs before shipping — so absorb an assembled state by reopening, rather
    # than refusing the member.
    #
    # Atomic: the reopen and the member attach are ONE unit. The conductor's
    # late-merge caller (Conductor.sweep! ← `bin/release merge`) runs `add`
    # standalone with no enclosing transaction (unlike prepare!/curate!), so
    # without this wrapper a failed member attach would leave the RC reopened
    # (assembling) with the member never attached. Defense-in-depth.
    transaction do
      reopen! if state == "assembled"
      raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

      # Sweeping the task onto the RC means its PR merged onto the `release`
      # branch — stamp the git-location (the qa-deploy heartbeat's crash-recovery
      # signal: an interrupted Steffon skips re-merging a `merged: "release"`
      # task). See Task::MERGED_STATES. Stage is untouched: `reviewed` members
      # flip to `assembled` only on QA-green.
      #
      # NEVER downgrade `merged: "main"` → "release". A cross-release straggler
      # (an interrupted ship stamped it "main"; a LATER release re-adopts it via
      # this path) is already fast-forwarded onto main — re-stamping "release"
      # would claim it still waits on the release→main ff. sweep!'s own
      # never-regress short-circuit only sees CURRENT-release members, so this
      # is the backstop that keeps that promise absolute.
      stamp = task.merged == Task::MERGED_MAIN ? Task::MERGED_MAIN : Task::MERGED_RELEASE
      task.update!(release_slug: slug, merged: stamp)
    end
    task
  end

  # Every member in + tests check out → the RC is complete.
  def assemble!
    raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

    update!(state: "assembled")
  end

  # The operator "Makes the release" → ship to prod; members flip to `shipped`.
  # Allowed from an active release (assembling or assembled). A shipped release
  # with unfinished members is also accepted so an interrupted production record
  # step can resume the member flips after the release itself has already become
  # the board's Last Release.
  #
  # `usage_by_slug` is the optional { slug => {model, tokens_in, tokens_out, cost} }
  # best-effort per-member usage for the assembled→shipped transition (captured by
  # bin/release from the conductor's local transcript). Each member's ship! runs
  # inside Current.with_task_event_usage, which stamps that member's shipped
  # TaskEvent and clears the fields afterward so the next member isn't
  # mis-attributed. A member with no entry records the deterministic spine only.
  def ship!(by: nil, usage_by_slug: {}, member_pause: 0)
    resumable_member_ship = shipped? && tasks.where.not(stage: "shipped").exists?
    unless active? || resumable_member_ship
      raise ArgumentError, "release #{slug} is already terminal (state: #{state})"
    end

    usage_by_slug ||= {}
    member_pause = member_pause.to_f

    # confirmed_at is a stage stamp (first-write-wins): when Avi already posted
    # his confirming completion via the events API, ship keeps that earlier,
    # truer boundary instead of re-dating it to the ship moment. Commit this
    # before member flips so /deployments swaps the candidate into Last Release
    # immediately, then each task moves to Shipped in its own after_commit.
    if active?
      update!(state: "shipped", confirmed_by: by, confirmed_at: confirmed_at || Time.current)
    elsif by.present? && confirmed_by.blank?
      update!(confirmed_by: by, confirmed_at: confirmed_at || Time.current)
    end

    shipped_count = 0
    # Each Task#ship! stamps position = target-column max + 100. Ship members in
    # stable oldest-first order so the newest task in a deployment batch receives
    # the freshest board rank, regardless of how the association was preloaded.
    tasks.order(:created_at, :id).to_a.each do |task|
      next if task.stage == "shipped"

      pause_between_member_shipments(member_pause) if member_pause.positive? && shipped_count.positive?
      Current.with_task_event_usage(usage_by_slug[task.slug]) { task.ship! }
      shipped_count += 1
    end
  end

  # Pull an assembled RC back to `assembling` so more reviewed work can be added.
  # Adding members invalidates the prior QA pass, so the RC must re-assemble (and
  # re-QA) before it can ship. This is what lets `Prepare release` be additive
  # instead of refusing when a release is already in flight.
  def reopen!
    raise ArgumentError, "release #{slug} is not assembled (state: #{state})" unless state == "assembled"

    # New members invalidate the prior assembly, QA pass, and any confirmation —
    # wind the stage timeline back to `assembling` so the tracker honestly shows
    # the re-assemble + re-QA ahead. The re-run re-stamps each boundary fresh
    # (first-write-wins applies to the NEW blanks). testing/assembling stamps
    # stay: the candidate's overall clock keeps its true origin.
    update!(
      state: "assembling",
      assembled_at: nil,
      qa_deploy_started_at: nil,
      qa_deployed_at: nil,
      confirming_started_at: nil,
      confirmed_at: nil
    )
  end

  # Discard a stuck RC → members fall back to `reviewed` (off the train), and the
  # singleton frees up for a fresh release.
  #
  # NOTE: this only drops BOARD membership. On the DURABLE per-repo `release`
  # branch the git-side remediation — reverting each abandoned member's merge
  # commit on `release` (never a force-push, since `release` is permanent and
  # shared) — is owned by the conductor/CLI as a documented step. The model never
  # touches git. `merged` is deliberately LEFT as-is: an un-reverted member's PR
  # still rides `release`, so `merged: "release"` stays true and the next sweep
  # correctly skips re-merging it. If you DO revert a member's merge commit,
  # clear its `merged` too (`Release::Conductor.eject!` does both for the
  # single-task regression path).
  def abandon!
    raise ArgumentError, "release #{slug} is already terminal (state: #{state})" unless active?

    transaction do
      tasks.to_a.each { |task| task.update!(stage: "reviewed", release_slug: nil) }
      update!(state: "abandoned")
    end
  end

  private

  # The event→stage seam: recording a step boundary stamps the matching stage
  # (EVENT_STAGE_STAMPS; unmapped steps and `failed` stamp nothing). Uses the
  # event's occurred_at so a backdated event stamps its true time. stamp_stage!
  # is first-write-wins, so idempotent event replays are stamp no-ops.
  def stamp_stage_for_event(step, status, at:)
    stage = EVENT_STAGE_STAMPS[[step.to_s, status.to_s]]
    return unless stage

    stamp_stage!(stage, at: at || Time.current)
  end

  def at_most_one_active_release
    scope = Release.where(state: ACTIVE_STATES)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:state, "another release is already active") if scope.exists?
  end

  # First-write-wins like every stage stamp: an agent may have already posted the
  # boundary (e.g. `assembled` at sweep-merge completion) before the state flip
  # lands — the earlier, truer time survives. reopen! clears the downstream
  # stamps, so a re-assembly stamps fresh.
  def set_state_timestamp
    case state
    when "assembled" then self.assembled_at ||= Time.current
    when "shipped"   then self.shipped_at ||= Time.current
    when "abandoned" then self.abandoned_at ||= Time.current
    end
  end

  def pause_between_member_shipments(seconds)
    sleep(seconds)
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
