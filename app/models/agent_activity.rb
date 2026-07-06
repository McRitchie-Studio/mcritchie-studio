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
  before_validation :normalize_agent

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
      "task_slug" => task_slug, "session_id" => session_id, "agent" => agent }.compact
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
                          mascot: nil, stage: nil, agent: nil, prior_outcome_slug: nil,
                          prior_key_method: nil, prior_key_method_lang: nil,
                          opened_at: Time.current)
    activity = new(
      session_id:  session_id,
      category:    category,
      reason_slug: reason_slug,
      task_slug:   task_slug,
      mascot:      mascot,
      stage:       stage,
      agent:       agent,
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
      # Per-agent lanes: auto-close only THIS agent's open activity (activity.agent is the
      # already-normalized lane key — a known soul or nil), so a parallel soul
      # narration in the same session never closes another soul's in-flight activity.
      lane = for_session(session_id).where(agent: activity.agent).open
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

  # Close the current OPEN activity for (session, agent), stamping the narrated
  # outcome. `agent` selects the LANE (normalized like the record's own agent — an
  # unknown/blank value is the nil lane, the orchestrator's), so a reviewer's close
  # resolves ITS OWN activity, not whichever soul opened last. Returns the closed
  # activity, or nil when that lane has no open activity.
  def self.close_activity!(session_id:, agent: nil, outcome_slug: nil,
                           key_method: nil, key_method_lang: nil, closed_at: Time.current)
    activity = for_session(session_id).where(agent: normalize_agent_value(agent)).open.order(:seq).last
    return nil unless activity

    attrs = { outcome_slug: outcome_slug.presence, closed_at: closed_at }
    # Stamp the activity's key method only when the close narrates one — a bare close
    # never blanks a key method the open already set.
    if key_method.present?
      attrs[:key_method]      = key_method
      attrs[:key_method_lang] = key_method_lang
    end
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

  private

  # Normalize `agent` to a known soul slug (down-cased + stripped) or nil. An
  # unknown/blank value becomes nil — the coercion is deliberately silent so a
  # typo'd --agent degrades to "base session mascot did it", never a hard error.
  def normalize_agent
    self.agent = self.class.normalize_agent_value(agent)
  end

  # The lane key for an agent value: a known SOULS slug (down-cased + stripped),
  # else nil (the orchestrator's un-agented lane). Shared by #normalize_agent (the
  # record) and the per-lane close scopes (open_activity!/close_activity!) so a WHERE on
  # `agent` matches the SAME normalized value the record was stored under.
  def self.normalize_agent_value(value)
    slug = value.to_s.strip.downcase
    SOULS.include?(slug) ? slug : nil
  end

  class << self
    alias_method :open_event!, :open_activity!
    alias_method :close_event!, :close_activity!
  end
end
