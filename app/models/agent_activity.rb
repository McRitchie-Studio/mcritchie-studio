# An agent-narrated activity — a meaningful block of work the agent declares as it
# works. Where an AgentAction is one raw tool call (best-effort, captured by the
# PostToolUse hook), an AgentActivity is the activity the agent opens and closes:
#
#   Explore · "find issue with api"   →   (raw reads/greps attribute here)   →
#     close · "located the nil-guard in AgentAction.capture"
#
# The agent NARRATES its own work — there is no per-call classifier and no reader
# sub-agent. It declares the activity (category + reason), the raw tool-calls
# attribute server-side to whatever activity is currently OPEN, and the agent
# closes the activity with a result. A simple task that used to log ~100 noisy
# rows collapses to a handful of narrated activities.
#
# INVARIANT: at most one OPEN activity per (session, AGENT) at a time — a
# per-agent LANE. Opening a new activity auto-closes the prior open one FOR THAT
# AGENT (see .open_activity!). This is what lets the documented reviewer fan-out work: a
# PRIMARY and its nested LIGHT both narrate `--agent <soul>` in the SAME parent
# session (subagents inherit the session id), and each soul's start/end operates
# on its OWN lane instead of silently closing the other's in-flight activity and
# dropping its verdict. The orchestrator's un-agented activities are the nil lane.
#
# (Raw AgentAction attribution stays best-effort last-open-activity within the
# session — an action carries no agent, and a subagent's PostToolUse hook posts
# under the parent session id, so per-agent ACTION attribution is a harness-level
# limit this does not claim to fix. The activity/verdict integrity — the graded
# signal — is what the per-agent lane protects.)
class AgentActivity < ApplicationRecord
  # Optional key_method (+ lang badge) — the activity's one load-bearing call, stamped
  # by the agent at close (`bin/agent-activity next/end --key-method "…"`).
  include HasKeyMethod

  # The agent-declared activity vocabulary — a fixed, small set so activities stay
  # comparable across sessions. The agent picks ONE per activity.
  CATEGORIES = %w[
    Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan
  ].freeze

  # The McRitchie soul roster — the ONE acting agent an activity may be attributed to
  # (via `bin/agent-activity --agent <soul>`), distinct from the base session
  # `mascot`. A nil `agent` means "the base session mascot did it" (no soul
  # override); the heartbeat can later STACK the acting soul over the stable base
  # mascot. An unknown slug is coerced to nil by #normalize_agent — non-fatal, so
  # a typo'd soul never fails a narration.
  SOULS = %w[avi carl shannon jasper steffon alex].freeze

  # The playful genesis reason for a session's very FIRST span — a self-contained
  # opener that needs no derived preamble (sidestepping the first-turn "assistant
  # line not yet flushed" race) and no prior span to seal. "%s" is the base session
  # mascot, title-cased; a mascot-less session falls back to a generic challenger.
  GENESIS_REASON = "A wild %s appeared"

  # The fallback reason when a derived (non-genesis) open arrives with a blank
  # preamble — a span must never sink on an empty reason_slug (the seam can backfill).
  DEFAULT_DERIVED_REASON = "(working)"

  # Cap on a derived reason/outcome length — a preamble can be a paragraph, but a
  # span's reason should stay a glanceable line on the heartbeat.
  DERIVED_REASON_MAX = 160

  # Slug FK to tasks (the ecosystem convention). Optional: PRE-task activities (boot,
  # intake) carry a null task_slug and must never fail a task lookup.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug,
                    optional: true, inverse_of: :agent_activities

  # The raw tool-calls that attributed to this activity. Nullify (not destroy) so
  # closing/removing an activity never destroys the actions it framed.
  has_many :agent_actions, dependent: :nullify, inverse_of: :agent_activity

  # The grades targeting this activity — Alex's grade and the McRitchie audit-of-Alex
  # are two ActionGrade rows (distinguished by grader), the activity-level mirror of
  # AgentAction#action_grades. Nullify (not destroy), matching the FK's
  # on_delete: :nullify — removing an activity orphans its grades rather than deleting
  # the recorded feedback.
  has_many :action_grades, dependent: :nullify, inverse_of: :agent_activity

  validates :session_id, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :reason_slug, presence: true
  validates :opened_at, presence: true
  validates :seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Coerce the acting soul to a known roster slug (down-cased), else nil. This is
  # deliberately NON-FATAL — an unknown/typo'd `agent` becomes nil rather than an
  # invalid record, so a bad --agent value never sinks a best-effort narration.
  before_validation :normalize_agent, :normalize_supervisor_agent

  # Live-update the /agents/activities feed. Guarded inside ActivitiesBroadcaster's
  # safe_broadcast, so a dead cable never breaks a narration write. Note: the prior
  # activity that open_activity! auto-closes via update_all does NOT fire this (no
  # callbacks on update_all) — so open_activity! broadcasts that close explicitly
  # after commit (see below), keeping the closed row live on the feed.
  after_create_commit  { ActivitiesBroadcaster.activity_created(self) }
  after_update_commit  { ActivitiesBroadcaster.activity_updated(self) }

  scope :for_session,  ->(session_id) { where(session_id: session_id) }
  scope :open,         -> { where(closed_at: nil) }
  scope :closed,       -> { where.not(closed_at: nil) }
  scope :chronological, -> { order(opened_at: :asc, seq: :asc, id: :asc) }

  # Default batch size for the Alex heartbeat grade-events loop (the SOP's "10 most
  # recent resolved activities"), and the hard cap.
  DEFAULT_GRADE_BATCH = 10
  MAX_GRADE_BATCH     = 100

  # The RESOLVED (closed) activities that carry NO grade by `grader` yet — the "activities
  # awaiting grade" the Alex heartbeat works through, newest-resolved first, capped.
  # This is the READ half of the first-class agent grading flow (the WRITE is
  # ActionGrade.record_activity_grade); together they let grade-events run as a bearer
  # CLI SOP instead of scraping the HTML page.
  def self.awaiting_grade(grader: ActionGrade::ALEX, limit: DEFAULT_GRADE_BATCH)
    capped = limit.to_i.clamp(1, MAX_GRADE_BATCH)
    graded = ActionGrade.by_grader(grader).where.not(agent_activity_id: nil).select(:agent_activity_id)
    closed.where.not(id: graded).order(closed_at: :desc, seq: :desc).limit(capped)
  end

  # The shape an agent needs to JUDGE an activity: its id + what happened (category,
  # reason → outcome) + provenance (task, session, acting soul). No raw actions —
  # the grader judges the narrated activity, not the tool stream. nil fields dropped.
  def to_grading_row
    { "id" => id, "category" => category, "reason" => reason_slug, "outcome" => outcome_slug,
      "task_slug" => task_slug, "session_id" => session_id, "agent" => agent,
      "supervisor_agent" => supervisor_agent }.compact
  end

  # Open a new activity for the session, auto-closing any prior OPEN activity first.
  #
  # The BOUNDARY transition (see `bin/agent-activity next` / `start --outcome`):
  # pass `prior_outcome_slug:` to stamp the auto-closed prior activity's result as we
  # cross into the new activity — so an activity resolves with "what happened" in the SAME
  # call that opens "what's next", instead of hanging half-narrated with a NULL
  # result (the production failure this fixes). Without it, the prior activity still
  # auto-closes, just with a NULL result (the legacy behavior).
  #
  # Backend discipline — VALIDATE BEFORE the irreversible side effect: we reject an
  # invalid activity (e.g. a bad category) BEFORE auto-closing the prior activity, so a
  # typo never strands the session with everything closed and nothing open. The
  # auto-close + insert then run in one transaction to preserve the single-open
  # invariant. Raises ActiveRecord::RecordInvalid on an invalid activity (the caller —
  # the controller — turns that into a 422).
  #
  # `agent:` is the acting soul (see SOULS) — an unknown value is coerced to nil
  # (via #normalize_agent) rather than raising, so a bad --agent never sinks the
  # open. `mascot:` stays the STABLE base session mascot; the agent stacks on top.
  #
  #   AgentActivity.open_activity!(session_id:, category:, reason_slug:,
  #                           task_slug: nil, mascot: nil, stage: nil,
  #                           agent: nil, prior_outcome_slug: nil,
  #                           opened_at: Time.current) => AgentActivity
  def self.open_activity!(session_id:, category:, reason_slug:, task_slug: nil,
                          mascot: nil, stage: nil, agent: nil, supervisor_agent: nil,
                          prior_outcome_slug: nil,
                          prior_key_method: nil, prior_key_method_lang: nil,
                          prior_model: nil, prior_tokens_in: nil, prior_tokens_out: nil,
                          prior_cache_creation_tokens: nil, prior_cache_read_tokens: nil,
                          prior_cost: nil,
                          turn_uuid: nil, parent_span_id: nil, transcript_path: nil,
                          opened_at: Time.current)
    activity = new(
      session_id:  session_id,
      category:    category,
      reason_slug: reason_slug,
      task_slug:   task_slug,
      mascot:      mascot,
      stage:       stage,
      agent:       agent,
      supervisor_agent: supervisor_agent,
      turn_uuid:   turn_uuid,
      parent_span_id: parent_span_id,
      transcript_path: transcript_path,
      seq:         next_seq_for(session_id),
      opened_at:   opened_at
    )
    raise ActiveRecord::RecordInvalid, activity unless activity.valid?

    closed_prior_ids = []
    transaction do
      close_attrs = { closed_at: opened_at, updated_at: opened_at }
      # Stamp the crossed-over activity's result only when the agent narrated one,
      # so a bare open never blanks a result a prior close already set.
      close_attrs[:outcome_slug] = prior_outcome_slug if prior_outcome_slug.present?
      # Same for the completed activity's key method (`next --key-method`). update_all
      # skips callbacks, so normalize the pair here.
      close_attrs.merge!(HasKeyMethod.normalize_pair(prior_key_method, prior_key_method_lang)) if prior_key_method.present?
      close_attrs.merge!(usage_attrs(model: prior_model, tokens_in: prior_tokens_in,
                                     tokens_out: prior_tokens_out,
                                     cache_creation_tokens: prior_cache_creation_tokens,
                                     cache_read_tokens: prior_cache_read_tokens,
                                     cost: prior_cost))
      # Per-agent, per-transcript lanes: auto-close only THIS agent's open activity in
      # THIS transcript lineage (activity.agent is the normalized lane key — a known
      # soul or nil; transcript_path isolates a subagent's turns from the parent's), so
      # neither a parallel soul nor a running subagent ever closes another lane's
      # in-flight activity. A subagent turn (different transcript) therefore never
      # seals the parent's open Delegate span.
      lane = for_session(session_id).where(agent: activity.agent, transcript_path: activity.transcript_path).open
      closed_prior_ids = lane.pluck(:id)
      lane.update_all(close_attrs)
      activity.save!
    end
    # update_all skips the after_update_commit broadcaster, so the just-closed prior
    # activity would otherwise stay visually OPEN on the /agents/activities feed. Re-query
    # the closed rows post-commit (fresh close state + stamped outcome) and broadcast each
    # in place — the same live update a callback-firing close_activity! would emit.
    if closed_prior_ids.any?
      where(id: closed_prior_ids).find_each { |prior| ActivitiesBroadcaster.activity_updated(prior) }
    end
    activity
  end

  # The DERIVED lifecycle's single entry point — an idempotent, TURN-KEYED span open
  # the PreToolUse capture hook calls on EVERY tool call, passing the assistant turn's
  # uuid. Because parallel tool calls in one turn share a turn_uuid:
  #   * the FIRST call for a (session, turn_uuid) opens the span — a BOUNDARY that
  #     seals the lane's prior span (prior_outcome_slug + prior usage) as it opens the
  #     new one (see open_activity!), and
  #   * the 2nd..Nth calls are NO-OPS returning the span the first opened, so the
  #     sibling actions attribute to ONE span instead of spawning duplicates.
  # The (session_id, turn_uuid) partial-unique index makes the create race-safe: a
  # concurrent open that loses rescues RecordNotUnique and returns the winner.
  #
  # GENESIS: a session's very first span skips the derived reason and opens with the
  # canned "A wild <mascot> appeared" — self-contained, with nothing before it to seal
  # (this also sidesteps the first-turn preamble-not-yet-flushed race).
  #
  # NESTING: parent_span_id links a subagent's span to the delegating span — subagents
  # inherit the parent session_id, so the child rides the same lane and the feed can
  # render it nested under the Delegate span. Returns the span, or nil on blank input.
  def self.open_for_turn!(session_id:, turn_uuid:, reason_slug: nil, category: "Explore",
                          mascot: nil, task_slug: nil, stage: nil, agent: nil,
                          supervisor_agent: nil, parent_span_id: nil, transcript_path: nil,
                          prior_outcome_slug: nil, prior_key_method: nil,
                          prior_key_method_lang: nil, prior_model: nil,
                          prior_tokens_in: nil, prior_tokens_out: nil,
                          prior_cache_creation_tokens: nil, prior_cache_read_tokens: nil,
                          prior_cost: nil,
                          opened_at: Time.current)
    return nil if session_id.blank? || turn_uuid.blank?

    # Same turn (e.g. a parallel tool-call sibling) → the span already exists; no new
    # boundary, no re-seal. Return it so the action attributes to the open span.
    existing = for_session(session_id).find_by(turn_uuid: turn_uuid)
    return existing if existing

    # A session's FIRST span is the genesis: canned reason, no prior to seal.
    genesis = !for_session(session_id).exists?
    reason  = genesis ? genesis_reason(mascot) : reason_slug.to_s.strip.presence
    reason  = DEFAULT_DERIVED_REASON if reason.blank?

    # NESTING: a turn arriving on a DIFFERENT transcript than the session's root
    # lineage is a subagent turn — link it to the delegating span. (The transcript-
    # scoped lane in open_activity! keeps it from sealing that parent.)
    parent_span_id ||= parent_span_for(session_id, transcript_path) unless genesis

    open_activity!(
      session_id: session_id, category: category, reason_slug: reason,
      task_slug: task_slug, mascot: mascot, stage: stage, agent: agent,
      supervisor_agent: supervisor_agent, turn_uuid: turn_uuid,
      parent_span_id: parent_span_id, transcript_path: transcript_path, opened_at: opened_at,
      prior_outcome_slug:      (genesis ? nil : prior_outcome_slug),
      prior_key_method:        (genesis ? nil : prior_key_method),
      prior_key_method_lang:   prior_key_method_lang,
      prior_model:             prior_model,
      prior_tokens_in:         prior_tokens_in,
      prior_tokens_out:        prior_tokens_out,
      prior_cache_creation_tokens: prior_cache_creation_tokens,
      prior_cache_read_tokens: prior_cache_read_tokens,
      prior_cost:              prior_cost
    )
  rescue ActiveRecord::RecordNotUnique
    # A concurrent opener won the (session, turn_uuid) race — return the winner so
    # this call still attributes its action to the single shared span.
    for_session(session_id).find_by(turn_uuid: turn_uuid)
  end

  # The delegating span for a SUBAGENT turn, or nil. Subagents share the session but
  # arrive on a DIFFERENT transcript than the ROOT lineage (the genesis span's
  # transcript); such a turn nests under the root lineage's currently-open span — the
  # Delegate span still running the Agent tool. A same-lineage (or unknown) turn → nil.
  # Best-effort: any lookup hiccup degrades to no nesting rather than sinking the open.
  def self.parent_span_for(session_id, transcript_path)
    return nil if transcript_path.blank?

    root = for_session(session_id).order(:seq).first
    return nil if root.nil? || root.transcript_path.blank? || root.transcript_path == transcript_path

    for_session(session_id)
      .where(transcript_path: root.transcript_path, agent: nil).open.order(:seq).last&.id
  rescue StandardError
    nil
  end

  # "A wild Charmander appeared" — the base session mascot, title-cased, or a generic
  # challenger when the session has no mascot yet. The genesis span's reason.
  def self.genesis_reason(mascot)
    name = mascot.to_s.strip.presence
    format(GENESIS_REASON, name ? name.titleize : "challenger")
  end

  # Split a turn's assistant PREAMBLE into { prior_outcome:, reason: } — the lead
  # sentence is the PRIOR span's result ("Found it — only User#avatar…"), the rest is
  # THIS span's reason ("Now let me check how Pokémon store images"). Splits ONLY when
  # there are >= 2 sentences; a single-sentence preamble is all reason (nothing
  # confidently attributable as the prior outcome). Both fields collapse to one line
  # and truncate to DERIVED_REASON_MAX. A blank preamble yields both nil.
  def self.split_preamble(text)
    clean = text.to_s.strip.gsub(/\s+/, " ")
    return { prior_outcome: nil, reason: nil } if clean.empty?

    sentences = clean.split(/(?<=[.!?])\s+/)
    prior, reason = sentences.length >= 2 ? [sentences.first, sentences[1..].join(" ")] : [nil, clean]
    { prior_outcome: truncate_derived(prior), reason: truncate_derived(reason) }
  end

  # One-line, length-capped form of a derived field (nil stays nil).
  def self.truncate_derived(text)
    slug = text.to_s.strip.presence
    return nil unless slug

    slug.length > DERIVED_REASON_MAX ? "#{slug[0, DERIVED_REASON_MAX - 1]}…" : slug
  end

  # Close the current OPEN activity for (session, agent), stamping the narrated
  # outcome. `agent` selects the LANE (normalized like the record's own agent — an
  # unknown/blank value is the nil lane, the orchestrator's), so a reviewer's close
  # resolves ITS OWN activity, not whichever soul opened last. Returns the closed
  # activity, or nil when that lane has no open activity.
  def self.close_activity!(session_id:, agent: nil, outcome_slug: nil,
                           key_method: nil, key_method_lang: nil,
                           model: nil, tokens_in: nil, tokens_out: nil,
                           cache_creation_tokens: nil, cache_read_tokens: nil, cost: nil,
                           closed_at: Time.current)
    activity = for_session(session_id).where(agent: normalize_agent_value(agent)).open.order(:seq).last
    return nil unless activity

    attrs = { outcome_slug: outcome_slug.presence, closed_at: closed_at }
    # Stamp the activity's key method only when the close narrates one — a bare close
    # never blanks a key method the open already set.
    if key_method.present?
      attrs[:key_method]      = key_method
      attrs[:key_method_lang] = key_method_lang
    end
    attrs.merge!(usage_attrs(model: model, tokens_in: tokens_in, tokens_out: tokens_out,
                             cache_creation_tokens: cache_creation_tokens,
                             cache_read_tokens: cache_read_tokens, cost: cost))
    activity.update!(attrs)
    activity
  end

  # Close EVERY still-open activity for the session — the session-end teardown behind
  # `bin/agent-activity close-open` + the Claude Code SessionEnd hook. By the
  # single-open invariant this is usually one activity, but a session that ended
  # mid-narration would otherwise leave its last activity open FOREVER (and trailing
  # actions falling into "Unlabeled"); this closes them all with a shared generic
  # outcome (e.g. "session ended"). Returns the count closed — 0 is a no-op, never
  # an error (telemetry must not surface a session teardown as a failure).
  def self.close_all_open!(session_id:, outcome_slug: nil, closed_at: Time.current)
    attrs = { closed_at: closed_at, updated_at: closed_at }
    attrs[:outcome_slug] = outcome_slug if outcome_slug.present?
    for_session(session_id).open.update_all(attrs)
  end

  # The session's activity windows for the fan-out reconciler (id, agent lane,
  # opened_at, closed_at, seq), chronological. The reconciler reads the CHILD
  # subagents/*.jsonl transcripts the board can't see and needs these windows to
  # attribute each child's spend to the activity that authored it. Times are ISO8601
  # (UTC) so the plain-Ruby reconciler can Time.parse them.
  def self.usage_windows(session_id)
    return [] if session_id.blank?

    for_session(session_id).chronological.pluck(:id, :agent, :opened_at, :closed_at, :seq).map do |id, agent, opened_at, closed_at, seq|
      { "id" => id, "agent" => agent, "seq" => seq,
        "opened_at" => opened_at&.utc&.iso8601, "closed_at" => closed_at&.utc&.iso8601 }
    end
  end

  # Stamp the fan-out reconciler's per-activity usage. `usages` is an array of
  # { activity_id/id, model, tokens_in, tokens_out, cache_creation_tokens,
  # cache_read_tokens, cost } (string OR symbol keys); usage_attrs re-derives cost
  # server-side when the cache_creation bucket is present, so a reconciled row honors
  # an operator rate override exactly like a live close does. Each row is applied
  # ONLY to an activity in THIS session (the
  # session_id scope is the guard — a token can never patch another session's rows),
  # reusing usage_attrs so a blank/zero usage is dropped rather than clobbering a
  # real value with nils. Per-row update! fires the after_update_commit broadcaster,
  # so the live feed refreshes. Returns the count of activities updated.
  def self.apply_reconciled_usage!(session_id:, usages:)
    return 0 if session_id.blank?

    rows = Array(usages).filter_map do |u|
      id = (u["activity_id"] || u[:activity_id] || u["id"] || u[:id]).presence
      next nil unless id

      attrs = usage_attrs(
        model:             u["model"] || u[:model],
        tokens_in:         u["tokens_in"] || u[:tokens_in],
        tokens_out:        u["tokens_out"] || u[:tokens_out],
        cache_creation_tokens: u["cache_creation_tokens"] || u[:cache_creation_tokens],
        cache_read_tokens: u["cache_read_tokens"] || u[:cache_read_tokens],
        cost:              u["cost"] || u[:cost]
      )
      attrs.empty? ? nil : [id.to_i, attrs]
    end

    by_id = for_session(session_id).where(id: rows.map(&:first)).index_by(&:id)
    rows.count do |id, attrs|
      (activity = by_id[id]) && activity.update!(attrs)
    end
  end

  # The next activity position for a session — max+1, 0-based.
  # Best-effort: a lookup hiccup falls back to 0 rather than sinking the open.
  def self.next_seq_for(session_id)
    return 0 if session_id.blank?

    (where(session_id: session_id).maximum(:seq) || -1) + 1
  rescue StandardError
    0
  end

  def open?
    closed_at.nil?
  end

  def closed?
    !open?
  end

  def measured_usage?
    model.present? || tokens_in.present? || tokens_out.present? ||
      cache_read_tokens.present? || cost.present?
  end

  private

  # Normalize `agent` to a known soul slug (down-cased + stripped) or nil. An
  # unknown/blank value becomes nil — the coercion is deliberately silent so a
  # typo'd --agent degrades to "base session mascot did it", never a hard error.
  def normalize_agent
    self.agent = self.class.normalize_agent_value(agent)
  end

  def normalize_supervisor_agent
    self.supervisor_agent = self.class.normalize_agent_value(supervisor_agent)
  end

  # The lane key for an agent value: a known SOULS slug (down-cased + stripped),
  # else nil (the orchestrator's un-agented lane). Shared by #normalize_agent (the
  # record) and the per-lane close scopes (open_activity!/close_activity!) so a WHERE on
  # `agent` matches the SAME normalized value the record was stored under.
  def self.normalize_agent_value(value)
    slug = value.to_s.strip.downcase
    SOULS.include?(slug) ? slug : nil
  end

  # The single funnel for an activity's usage columns — and the place cost is
  # DERIVED. The capture CLI mints its cost in a plain-Ruby process with no
  # ActiveRecord, so it can never see an operator's rate override (UsagePricing
  # .db_rates returns {} there); re-deriving here is what makes a saved rate
  # actually apply to the dominant cost path. The client's cost is kept only as a
  # FALLBACK — for an unpriced model, or an older CLI that doesn't yet send the
  # un-folded cache_creation bucket we need to split tokens_in faithfully.
  def self.usage_attrs(model: nil, tokens_in: nil, tokens_out: nil,
                       cache_creation_tokens: nil, cache_read_tokens: nil, cost: nil)
    values = {
      model: model.to_s.strip.presence,
      tokens_in: integer_or_nil(tokens_in),
      tokens_out: integer_or_nil(tokens_out),
      cache_creation_tokens: integer_or_nil(cache_creation_tokens),
      cache_read_tokens: integer_or_nil(cache_read_tokens),
      cost: decimal_or_nil(cost)
    }.compact
    return {} unless values[:model].present? ||
                     values[:tokens_in].to_i.positive? ||
                     values[:tokens_out].to_i.positive? ||
                     values[:cache_read_tokens].to_i.positive? ||
                     values[:cost].to_f.positive?

    derived = UsagePricing.cost_from_capture(
      model: values[:model],
      tokens_in: values[:tokens_in],
      tokens_out: values[:tokens_out],
      cache_creation_tokens: values[:cache_creation_tokens],
      cache_read_tokens: values[:cache_read_tokens]
    )
    values[:cost] = derived if derived

    values
  end

  def self.integer_or_nil(value)
    return nil if value.nil? || value.to_s.strip.empty?

    value.to_i
  end

  def self.decimal_or_nil(value)
    return nil if value.nil? || value.to_s.strip.empty?

    value.to_d
  end

  class << self
    alias_method :open_event!, :open_activity!
    alias_method :close_event!, :close_activity!
  end
end
