# One DB record per agent action — the forward-only action log.
#
# Where TaskEvent records a COMPLETED stage CHANGE (the coarse spine), an
# AgentAction records a SINGLE step within a stage: a read, an edit, a bash run,
# a test/verify, a delegate. The two compose — a stage's worth of AgentActions
# rolls up under the TaskEvent that closes that stage. There is no historical
# backfill; capture starts the moment this ships and only ever moves forward.
#
# Capture is BEST-EFFORT (backend discipline): AgentAction.capture writes one row
# and NEVER lets a telemetry failure break the calling action — any exception is
# swallowed into an ErrorLog and capture returns nil. Telemetry must not be able
# to take down the work it observes.
#
# Usage attribution (model/tokens/cost) mirrors TaskEvent: capture takes explicit
# attrs first, then falls back to the request/job's Current.task_event_* context
# (the same seam Task#write_stage_event drains), then to the column defaults. So a
# harness that sets Current usage once gets every action it captures attributed
# for free, exactly like a `bin/task move` does.
#
# TOKENS are split FRESH vs RE-USED: tokens_in/tokens_out hold the fresh spend the
# turn actually processed (input + cache_creation, and output) — this is what the
# heartbeat DISPLAYS — while cache_read_tokens holds the context re-read from the
# prompt cache, carried for COSTING only (never shown). Lumping cache reads into
# tokens_in is what once read a long session as ~300K tokens/action and overstated
# its cost ~10x.
#
# COST is DERIVED, not stored blindly: when no explicit cost is given (the live-
# capture hook path — it carries model + tokens but can't price them), capture
# computes cost via the shared UsagePricing module — fresh tokens at the model rate, plus
# cache_read at the cache tier (10% of input). A model with no known rate leaves
# cost NULL — we never fabricate a price. source_turn_uuid records the assistant
# turn a row's usage came from; because ONE turn can fire N parallel tool calls (N
# rows sharing that turn's usage), every ACTIVITY/SESSION aggregation dedupes by it (see
# HeartbeatHelper#heartbeat_usage_totals) so a fan-out isn't multi-counted.
#
# Activity attribution (agent_activity_id): the agent self-narrates its work as
# OPEN/CLOSE AgentActivities; each captured action prefers the explicit
# agent_activity_id stamped by the local hook marker, then falls back server-side to
# the session's current OPEN activity (AgentActivity.for_session(sid).open.order(:seq).last).
# A missing marker/open activity simply yields a null agent_activity_id and capture
# proceeds.
class AgentAction < ApplicationRecord
  # The outcome of a single action — the local credit signal.
  OK       = "ok"
  ERROR    = "error"
  PENDING  = "pending"
  OUTCOMES = [OK, ERROR, PENDING].freeze

  # Optional key_method (+ lang badge) — the action's load-bearing call. The
  # capture hook derives it from a bash tool call's command (post-redaction);
  # explicit capture attrs win. `summary` is the sibling GOAL slug (outcome-free),
  # derived from the bash call's description.
  include HasKeyMethod

  MAX_SUMMARY_LENGTH = 160

  before_validation { self.summary = summary.to_s.strip.presence&.first(MAX_SUMMARY_LENGTH) }

  # Who took the action. Mirrors the prototype's actor lane.
  HARNESS = "harness" # Claude Code / Codex runtime
  AGENT   = "agent"   # the session agent (on-policy)
  BOARD   = "board"   # Rails board / bin command
  HUMAN   = "human"   # the operator
  ACTORS  = [HARNESS, AGENT, BOARD, HUMAN].freeze

  # Per-model token pricing now lives in the shared UsagePricing module (list price,
  # one roster shared with the per-activity/per-task path), so every usage surface
  # prices identically. See .cost_for and lib/usage_pricing.rb.

  # Slug FK to tasks (the ecosystem convention). Optional: PRE-task actions (boot,
  # intake) carry a null task_slug, and capture must never fail on a task lookup.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug,
                    optional: true, inverse_of: :agent_actions

  # The narrated activity this raw tool-call rolls up under — the session's OPEN
  # AgentActivity at capture time (prefer explicit pin, else server fallback; see .capture). Optional:
  # an action captured with no open activity carries a null agent_activity_id.
  belongs_to :agent_activity, optional: true, inverse_of: :agent_actions
  belongs_to :atomic_event, class_name: "AgentActivity", foreign_key: :agent_activity_id,
                            optional: true
  alias_attribute :atomic_event_id, :agent_activity_id

  # The grading layer — Alex's grade and the McRitchie audit-of-Alex are two
  # ActionGrade rows (distinguished by grader). The Insight Bank is the banked
  # subset. Destroyed with the action so grades never outlive what they grade.
  has_many :action_grades, dependent: :destroy, inverse_of: :agent_action

  # Live-update the /agents/activities drill-down. Guarded inside ActivitiesBroadcaster's
  # safe_broadcast so a cable failure never breaks the best-effort capture write. Actions
  # with a nil agent_activity_id (unlabeled) are skipped by the broadcaster.
  after_create_commit  { ActivitiesBroadcaster.action_created(self) }
  after_update_commit  { ActivitiesBroadcaster.action_updated(self) }

  validates :session_id, presence: true
  validates :kind, presence: true
  validates :occurred_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :actor, inclusion: { in: ACTORS }
  validates :seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :chronological, -> { order(occurred_at: :asc, seq: :asc, id: :asc) }
  scope :for_session,   ->(session_id) { where(session_id: session_id) }
  scope :anchors,       -> { where(feedback_anchor: true) }
  scope :errored,       -> { where(outcome: ERROR) }

  # The wide text blobs the /agents/activities feed NEVER renders. `output` is the
  # captured tool RESULT (a full file read, a command's stdout, a transcript dump —
  # by far the heaviest column); `input` is the raw tool-call payload, which once
  # rode the feed as a full-text title tooltip and made the page weigh megabytes
  # (the 2026-08-09 outage page measured 1.8-5.4 MB). The feed's turn rows lead
  # with `summary` + `key_method` instead; only the drill-down DRAWER on
  # /alex/heartbeat (heartbeat/_drawer, a full-record load) reads input/output.
  FEED_OMITTED_COLUMNS = %w[input output].freeze

  # The narrowed column set the /agents/activities drill-down loads — every column
  # EXCEPT the wide, unrendered blobs above. Every scalar the feed reads stays
  # present (no MissingAttributeError surprise), only the heavy blobs are dropped.
  scope :for_activity_feed, -> { select(column_names - FEED_OMITTED_COLUMNS) }

  # Most actions the feed will drill into under ONE activity. 25 activities ×
  # unbounded actions is how the 2026-08-09 page reached 2958 kB for a single
  # 1339-action activity; 50 newest rows keeps the drill-down useful while the
  # view's "N more actions omitted" row owns the remainder.
  FEED_ACTIONS_PER_ACTIVITY = 50

  # The capped drill-down load behind /agents/activities — the newest
  # FEED_ACTIONS_PER_ACTIVITY actions PER activity (not per page), on the feed's
  # narrowed columns, in the feed's newest-first display order. One statement: a
  # window-ranked subquery picks each activity's newest ids so an over-cap
  # activity never ships (or even loads) its long tail. Both render paths — the
  # controller's page load and ActivitiesBroadcaster's tbody re-render — MUST load
  # through this seam so the dual-render markup stays identical.
  def self.for_activity_drilldown(activity_ids, per_activity: FEED_ACTIONS_PER_ACTIVITY)
    ranked = where(agent_activity_id: activity_ids)
             .select("id, ROW_NUMBER() OVER (PARTITION BY agent_activity_id " \
                     "ORDER BY occurred_at DESC, seq DESC, id DESC) AS feed_rank")
    newest = from(ranked, :ranked).select("ranked.id").where("ranked.feed_rank <= ?", per_activity.to_i)
    for_activity_feed.where(id: newest).order(occurred_at: :desc, seq: :desc, id: :desc)
  end

  # Best-effort forward write of ONE action record. Returns the persisted
  # AgentAction, or nil if anything went wrong (already logged). Accepts string
  # OR symbol keys so harness, service, and in-process callers all work.
  #
  #   AgentAction.capture(
  #     session_id:, kind:,                      # required
  #     task_slug: nil, mascot: nil, seq: nil,   # seq auto-derives per session when omitted
  #     event_slug: nil, result_slug: nil,
  #     input: nil, output: nil,
  #     outcome: "pending", actor: "agent",
  #     model: nil, tokens_in: nil, tokens_out: nil, cost: nil,  # fall back to Current.task_event_*
  #     source_turn_uuid: nil,                   # the assistant turn N actions may share
  #     stage: nil, feedback_anchor: false,
  #     occurred_at: Time.current, duration_ms: nil
  #   ) => AgentAction | nil
  def self.capture(attrs = {})
    attrs = attrs.to_h.symbolize_keys

    # Idempotency (opt-in): a source that RE-READS the same verdict — CI ingestion
    # (bin/ci-scope-capture) re-reading a PR's checks when dor-check/preflight run
    # twice — carries a stable key (ci:<pr>:<sha>:<job>). Find-first short-circuits
    # the duplicate BEFORE we do any create work; the partial unique index is the
    # hard guard against a concurrent double-write (handled below). Blank key =
    # the ordinary non-idempotent path (every generic tool-call action).
    idempotency_key = attrs[:idempotency_key].to_s.strip.presence
    if idempotency_key && (existing = find_by(idempotency_key: idempotency_key))
      return existing
    end

    model_value      = attrs.fetch(:model) { Current.task_event_model }.presence
    tokens_in_value  = (attrs.fetch(:tokens_in)  { Current.task_event_tokens_in }  || 0).to_i
    tokens_out_value = (attrs.fetch(:tokens_out) { Current.task_event_tokens_out } || 0).to_i
    # cache_read is the RE-USED prompt-cache context — hook-only (no Current seam),
    # kept OUT of the displayed token count and used only to price the cache tier.
    cache_read_value = (attrs[:cache_read_tokens] || 0).to_i

    # Cost priority: an EXPLICIT cost (in-process caller or the Current.task_event_*
    # seam a `bin/task move` sets) always wins; otherwise DERIVE it from the model +
    # tokens via UsagePricing — the FRESH tokens at the model rate plus cache_read at
    # the cache tier (10% of input). When the model has no known rate the derivation
    # returns nil and cost stays NULL — never a fabricated $0. The live-capture hook
    # carries model + tokens but no cost, so it lands on the derived path.
    explicit_cost = attrs.fetch(:cost) { Current.task_event_cost }
    cost_value    = if explicit_cost.nil?
                      cost_for(model_value, tokens_in_value, tokens_out_value, cache_read_value)
                    else
                      explicit_cost.to_d
                    end

    create!(
      session_id:       attrs[:session_id],
      task_slug:        attrs[:task_slug],
      mascot:           attrs[:mascot],
      seq:              attrs[:seq] || next_seq_for(attrs[:session_id]),
      agent_activity_id:  activity_id_from(attrs) ||
                          activity_for_turn_id(attrs[:session_id], attrs[:source_turn_uuid]) ||
                          current_activity_id_for(attrs[:session_id]),
      kind:             attrs[:kind],
      event_slug:       attrs[:event_slug],
      result_slug:      attrs[:result_slug],
      summary:          attrs[:summary],
      key_method:       attrs[:key_method],
      key_method_lang:  attrs[:key_method_lang],
      input:            attrs[:input],
      output:           attrs[:output],
      outcome:          attrs[:outcome].presence || PENDING,
      model:            model_value,
      tokens_in:        tokens_in_value,
      tokens_out:       tokens_out_value,
      cache_read_tokens: cache_read_value,
      cost:             cost_value,
      source_turn_uuid: attrs[:source_turn_uuid].presence,
      stage:            attrs[:stage],
      actor:            attrs[:actor].presence || AGENT,
      feedback_anchor:  attrs.fetch(:feedback_anchor, false) || false,
      occurred_at:      attrs[:occurred_at] || Time.current,
      duration_ms:      attrs[:duration_ms],
      idempotency_key:  idempotency_key
    )
  rescue ActiveRecord::RecordNotUnique
    # Lost a race on the partial unique index (a concurrent capture wrote the same
    # idempotency_key first). Return the winner instead of nil — the caller gets
    # the persisted row, and no ErrorLog noise for an expected dedupe.
    idempotency_key ? find_by(idempotency_key: idempotency_key) : nil
  rescue StandardError => e
    # Telemetry is best-effort: log and move on, NEVER re-raise into the caller.
    # Double-guard the logger itself so a failing ErrorLog can't break the action.
    begin
      ErrorLog.capture!(e)
    rescue StandardError => log_error
      Rails.logger.error("[AgentAction.capture] swallowed #{e.class}: #{e.message} " \
                         "(logging also failed: #{log_error.class})")
    end
    nil
  end

  # The next trajectory position for a session — max+1, 0-based, 0 for the first
  # action. Best-effort: a lookup hiccup falls back to 0 rather than sinking the
  # whole capture (the caller is inside capture's rescue regardless).
  def self.next_seq_for(session_id)
    return 0 if session_id.blank?

    (where(session_id: session_id).maximum(:seq) || -1) + 1
  rescue StandardError
    0
  end

  # The id of the session's current OPEN activity, or nil when none is open. This is
  # the server-side activity attribution the agent's self-narration hangs on. Wrapped
  # best-effort: an attribution lookup must NEVER break capture, so any failure
  # degrades to nil (the action still writes, just unattributed).
  def self.current_activity_id_for(session_id)
    return nil if session_id.blank?

    AgentActivity.for_session(session_id).open.order(:seq).last&.id
  rescue StandardError
    nil
  end

  def self.current_event_id_for(session_id)
    current_activity_id_for(session_id)
  end

  # The id of the span opened for THIS action's assistant turn — the deterministic
  # join the DERIVED (turn-keyed) lifecycle attributes on. The PreToolUse hook opens a
  # span stamped with the turn_uuid; every action from that turn carries the SAME
  # source_turn_uuid, so they attribute to it WITHOUT a local open-activity marker.
  # Preferred over current_activity_id_for (last-open) because it is turn-exact. nil
  # when no turn span exists yet (the manual/legacy narration flow). Best-effort.
  def self.activity_for_turn_id(session_id, turn_uuid)
    return nil if session_id.blank? || turn_uuid.blank?

    AgentActivity.for_session(session_id).where(turn_uuid: turn_uuid).order(:seq).last&.id
  rescue StandardError
    nil
  end

  def self.activity_id_from(attrs)
    attrs.key?(:agent_activity_id) ? attrs[:agent_activity_id] : attrs[:atomic_event_id]
  end

  # Dollar cost (BigDecimal, 4dp) for a model's token usage, or nil when the model
  # has no known rate (never fabricate a price). Delegates to the shared UsagePricing
  # source of truth so every usage surface prices identically. The action path
  # carries FRESH tokens_in (input + cache_creation folded at 1x) and tokens_out,
  # plus cache_read costed at the cache tier (10% of input) — re-used context is
  # cheap, so lumping it into tokens_in at the full rate overstated cost ~10x on long
  # sessions. It has no separate cache_creation bucket, so tokens_in maps to the
  # input bucket (splitting the write premium out is a later phase). Best-effort:
  # UsagePricing.price returns nil rather than raising on bad input.
  def self.cost_for(model, tokens_in, tokens_out, cache_read_tokens = 0)
    UsagePricing.price(
      {
        "input"          => tokens_in.to_i,
        "output"         => tokens_out.to_i,
        "cache_creation" => 0,
        "cache_read"     => cache_read_tokens.to_i
      },
      model
    )
  end

  def ok?
    outcome == OK
  end

  def error?
    outcome == ERROR
  end

  def pending?
    outcome == PENDING
  end

  def anchor?
    feedback_anchor
  end

  # Combined token count for this action (mirrors TaskEvent#tokens_total).
  def tokens_total
    tokens_in.to_i + tokens_out.to_i
  end
end
