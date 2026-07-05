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
# computes cost from MODEL_RATES per tier — fresh tokens at the model rate, plus
# cache_read at the cache tier (10% of input). A model with no known rate leaves
# cost NULL — we never fabricate a price. source_turn_uuid records the assistant
# turn a row's usage came from; because ONE turn can fire N parallel tool calls (N
# rows sharing that turn's usage), every ACTIVITY/SESSION aggregation dedupes by it (see
# HeartbeatHelper#heartbeat_usage_totals) so a fan-out isn't multi-counted.
#
# Activity attribution (agent_activity_id): the agent self-narrates its work as
# OPEN/CLOSE AgentActivities; each captured action attributes SERVER-SIDE to the
# session's current OPEN activity (AgentActivity.for_session(sid).open.order(:seq).last).
# The caller never sets it — it's derived here, best-effort: no open activity (or a
# lookup hiccup) simply yields a null agent_activity_id and capture proceeds. An
# explicit agent_activity_id in attrs still wins (in-process callers can pin it).
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

  # Per-model token pricing, in US dollars per 1,000,000 tokens (input, output).
  # Sourced from the authoritative Anthropic pricing table (the claude-api skill,
  # 2026-07). Keyed by the canonical model id; a `[tier]` suffix on a transcript
  # model id (e.g. "claude-opus-4-8[1m]") is stripped before lookup, since the 1M
  # context tier bills at standard rates for these models. A model with no entry
  # yields a NULL cost — we NEVER fabricate a price. An operator can extend the
  # map via the ATOMIC_ACTION_MODEL_RATES env (JSON: {"model": {"in": n, "out": n}}).
  MODEL_RATES = {
    "claude-fable-5"    => { in: 10.0, out: 50.0 },
    "claude-mythos-5"   => { in: 10.0, out: 50.0 },
    "claude-opus-4-8"   => { in: 5.0,  out: 25.0 },
    "claude-opus-4-7"   => { in: 5.0,  out: 25.0 },
    "claude-opus-4-6"   => { in: 5.0,  out: 25.0 },
    "claude-sonnet-4-6" => { in: 3.0,  out: 15.0 },
    "claude-haiku-4-5"  => { in: 1.0,  out: 5.0 }
  }.freeze

  PER_MILLION = 1_000_000

  # Slug FK to tasks (the ecosystem convention). Optional: PRE-task actions (boot,
  # intake) carry a null task_slug, and capture must never fail on a task lookup.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug,
                    optional: true, inverse_of: :agent_actions

  # The narrated activity this raw tool-call rolls up under — the session's OPEN
  # AgentActivity at capture time (attributed server-side, see .capture). Optional:
  # an action captured with no open activity carries a null agent_activity_id.
  belongs_to :agent_activity, optional: true, inverse_of: :agent_actions
  belongs_to :atomic_event, class_name: "AgentActivity", foreign_key: :agent_activity_id,
                            optional: true
  alias_attribute :atomic_event_id, :agent_activity_id

  # The grading layer — Alex's grade and the McRitchie audit-of-Alex are two
  # ActionGrade rows (distinguished by grader). The Insight Bank is the banked
  # subset. Destroyed with the action so grades never outlive what they grade.
  has_many :action_grades, dependent: :destroy, inverse_of: :agent_action

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

    model_value      = attrs.fetch(:model) { Current.task_event_model }.presence
    tokens_in_value  = (attrs.fetch(:tokens_in)  { Current.task_event_tokens_in }  || 0).to_i
    tokens_out_value = (attrs.fetch(:tokens_out) { Current.task_event_tokens_out } || 0).to_i
    # cache_read is the RE-USED prompt-cache context — hook-only (no Current seam),
    # kept OUT of the displayed token count and used only to price the cache tier.
    cache_read_value = (attrs[:cache_read_tokens] || 0).to_i

    # Cost priority: an EXPLICIT cost (in-process caller or the Current.task_event_*
    # seam a `bin/task move` sets) always wins; otherwise DERIVE it from the model +
    # tokens via MODEL_RATES — the FRESH tokens at the model rate plus cache_read at
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
      agent_activity_id:  activity_id_from(attrs) || current_activity_id_for(attrs[:session_id]),
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
      duration_ms:      attrs[:duration_ms]
    )
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

  def self.activity_id_from(attrs)
    attrs.key?(:agent_activity_id) ? attrs[:agent_activity_id] : attrs[:atomic_event_id]
  end

  # The cache-read (prompt-cache HIT) rate as a fraction of the base input rate.
  # Anthropic prices a cache read at 10% of the input rate; cache_creation (a cache
  # WRITE) is 1.25x, but the hook folds that into tokens_in at 1x as an accepted
  # best-effort, so only the cache-read tier is modelled here.
  CACHE_READ_RATE_FACTOR = 0.10

  # Dollar cost for a model's token usage, or nil when the model has no known rate
  # (never fabricate a price). Prices per tier: the FRESH tokens_in and tokens_out
  # at the model's input/output rate, plus cache_read_tokens at the cache-read tier
  # (10% of input) — re-used context is cheap, so lumping it into tokens_in at the
  # full rate overstated cost ~10x on long sessions. Best-effort + total: any bad
  # input degrades to nil rather than raising into capture. Returns dollars (BigDecimal).
  def self.cost_for(model, tokens_in, tokens_out, cache_read_tokens = 0)
    rate = rate_for(model)
    return nil unless rate

    ti = tokens_in.to_i
    to = tokens_out.to_i
    cr = cache_read_tokens.to_i
    in_rate = rate[:in].to_d
    ((ti * in_rate) +
     (cr * in_rate * CACHE_READ_RATE_FACTOR.to_d) +
     (to * rate[:out].to_d)) / PER_MILLION.to_d
  rescue StandardError
    nil
  end

  # The {in:, out:} per-million rate for a model, or nil. Tolerates a trailing
  # tier suffix ("[1m]") and a blank model, and returns nil unless BOTH sides
  # of the rate are present (a half-defined rate must not fabricate a $0).
  def self.rate_for(model)
    key = model.to_s.strip
    return nil if key.empty?

    base = model_rates[key] || model_rates[key.sub(/\[[^\]]*\]\z/, "")]
    return nil unless base.is_a?(Hash)

    in_rate  = base[:in]  || base["in"]
    out_rate = base[:out] || base["out"]
    return nil if in_rate.nil? || out_rate.nil?

    { in: in_rate, out: out_rate }
  rescue StandardError
    nil
  end

  # MODEL_RATES merged with an optional ATOMIC_ACTION_MODEL_RATES env override
  # (JSON: {"model-id": {"in": n, "out": n}}). Memoized; a malformed env is
  # ignored so a bad value can never break costing.
  def self.model_rates
    @model_rates ||= MODEL_RATES.merge(env_model_rates)
  end

  def self.env_model_rates
    raw = ENV["ATOMIC_ACTION_MODEL_RATES"].to_s.strip
    return {} if raw.empty?

    JSON.parse(raw).transform_values { |v| { in: v["in"], out: v["out"] } }
  rescue StandardError
    {}
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
