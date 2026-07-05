class HeartbeatController < ApplicationController
  # Alex learning / distillation heartbeat — the agent-narrated activity log.
  #
  # #show reads AgentActivity.for_session(...).chronological (oldest -> newest) as the
  # PRIMARY rows — agent-narrated activities (category · reason -> result) — and rolls the
  # raw AgentActions attributed to each activity (agent_activity_id) underneath as an
  # expandable, read-only drill-down; actions the agent never narrated (null
  # agent_activity_id) fall into the "Unlabeled" group. Grading is unchanged and lives
  # entirely in the drawer: #feedback renders the per-action grading drawer, #grade
  # upserts a grade (and banks/discards it), and #insights is the curated Insight Bank.
  #
  # BUILD-FIRST (2026-07-03, operator decision): the WHOLE heartbeat surface — reads
  # AND the grade/bank/discard writes (incl. the pipeline's Confirm) — is an OPEN meta
  # surface, so Mr. McRitchie can grade and confirm (incl. `grader: "mcr"`) without an
  # admin login while the pipeline is being built. This deliberately re-opens audit
  # finding #5 (grade writes are public; an `mcr` audit row is forgeable) as a
  # conscious tradeoff — RE-GATE before any real multi-user exposure (restore the
  # `require_admin`-except-READ_ACTIONS split). The first-class AGENT write path stays
  # the bearer-gated /api/v1 endpoint, which still forces `grader: alex` (lever 2).
  skip_before_action :require_authentication

  # Page size for the cross-session All Activities view.
  ALL_ACTIVITIES_PER_PAGE = 100
  ALL_SPANS_PER_PAGE = ALL_ACTIVITIES_PER_PAGE

  def show
    @session_id = params[:session_id].presence || latest_session_id
    @actions = @session_id ? AgentAction.for_session(@session_id).chronological.to_a : []

    # Usage is metered per assistant TURN, so a turn's fan-out of tool-calls all
    # carry that turn's tokens/cost and render identical numbers. Flag the
    # non-primary rows of each source_turn_uuid (walked chronologically across the
    # WHOLE session) so the views fade their tokens/cost cells — the numbers are
    # inherited, not additive. Purely presentational; no total changes.
    @shared_turn_ids = helpers.heartbeat_shared_turn_ids(@actions)

    # The primary rows are agent-narrated activities, not raw tool-calls. Each
    # activity rolls up the actions attributed to it (agent_activity_id); actions the
    # agent never narrated fall into the read-only "Unlabeled" group. One actions
    # query, grouped in Ruby, so activities + Unlabeled share it with
    # no N+1.
    actions_by_activity = @actions.group_by(&:agent_activity_id)
    @activities = @session_id ? AgentActivity.for_session(@session_id).chronological.to_a : []
    @activity_rows = @activities.map { |activity| [activity, actions_by_activity[activity.id] || []] }
    @unlabeled = actions_by_activity[nil] || []

    @sessions = session_options
    @pokemon_by_slug = pokemon_lookup(@actions, @activities)
    @agents_by_slug = agent_soul_lookup(@activities)
    @activity_grades = activity_grade_lookup(@activities)
    @stage_transitions = stage_transitions_for(@activities)
    @counts = grade_counts(@session_id)
  end

  # Every narrated AgentActivity across all sessions, newest-first, paginated
  # 100 per page — the cross-session companion to #show.
  def all_activities
    @page  = [params[:page].to_i, 1].max
    scope  = AgentActivity.order(opened_at: :desc, seq: :desc, id: :desc)
    @total = scope.count
    @activities = scope.offset((@page - 1) * ALL_ACTIVITIES_PER_PAGE).limit(ALL_ACTIVITIES_PER_PAGE).to_a

    actions_by_activity = AgentAction.where(agent_activity_id: @activities.map(&:id))
                                   .chronological.to_a.group_by(&:agent_activity_id)
    @activity_rows = @activities.map { |activity| [activity, actions_by_activity[activity.id] || []] }

    page_actions = actions_by_activity.values.flatten
    @shared_turn_ids = helpers.heartbeat_shared_turn_ids(page_actions)
    @pokemon_by_slug = pokemon_lookup(page_actions, @activities)
    @agents_by_slug  = agent_soul_lookup(@activities)
    @activity_grades    = activity_grade_lookup(@activities)
    @stage_transitions = stage_transitions_for(@activities)
    @has_prev = @page > 1
    @has_next = @page * ALL_ACTIVITIES_PER_PAGE < @total
  end
  alias_method :all_spans, :all_activities

  # The OPSD distillation pipeline as three columns, left→right:
  #   1. ACTIVITIES    — recent narrated activities
  #   2. INSIGHTS      — Alex's banked grades (the distilled lessons)
  #   3. CONFIRMATIONS — McRitchie's mcr grades (the confirmed subset)
  # Read-only meta surface (like the rest of the heartbeat); the column-2 Confirm
  # button posts an mcr grade through the public grade endpoint.
  PIPELINE_ACTIVITIES    = 40
  PIPELINE_SPANS = PIPELINE_ACTIVITIES
  PIPELINE_INSIGHTS = 40

  def pipeline
    # Column 1 — activities + their attributed actions (for cost) + their Alex grade
    # (for the "not" indicator).
    @activities = AgentActivity.order(opened_at: :desc, seq: :desc, id: :desc).limit(PIPELINE_ACTIVITIES).to_a
    actions_by_activity = AgentAction.where(agent_activity_id: @activities.map(&:id))
                                  .chronological.to_a.group_by(&:agent_activity_id)
    @activity_rows       = @activities.map { |activity| [activity, actions_by_activity[activity.id] || []] }
    @pokemon_by_slug = pokemon_lookup(actions_by_activity.values.flatten, @activities)
    @agents_by_slug  = agent_soul_lookup(@activities)
    @activity_grades     = activity_grade_lookup(@activities)

    # Candidates awaiting grade — disposition:"not" grades MINED from resolved QA
    # blocks (Insights::BlockMiner), not yet banked into an insight nor discarded.
    # The block ledger surfaced as the learning loop's newest raw material: each is
    # a pre-labeled failure the operator/Alex promotes (bank) or sets aside.
    @candidates = ActionGrade.pending_candidates.by_grader(ActionGrade::ALEX)
                             .includes(:agent_activity, :source_activity)
                             .order(created_at: :desc).limit(PIPELINE_INSIGHTS).to_a

    # Column 2 — Alex's banked insights (the distilled lessons), newest curation first.
    @insights = ActionGrade.banked.by_grader(ActionGrade::ALEX)
                           .includes(:agent_activity, :agent_action)
                           .order(updated_at: :desc).limit(PIPELINE_INSIGHTS).to_a

    # Column 3 — McRitchie's confirmations (audit-of-Alex), newest first.
    @confirmations = ActionGrade.by_grader(ActionGrade::MCR)
                                .includes(:agent_activity, :agent_action)
                                .order(updated_at: :desc).limit(PIPELINE_INSIGHTS).to_a

    # Which activities already carry a McRitchie confirmation — so a column-2 insight
    # shows "confirmed" instead of a Confirm button.
    @confirmed_activity_ids = ActionGrade.by_grader(ActionGrade::MCR)
                                      .where.not(agent_activity_id: nil).pluck(:agent_activity_id).to_set
  end

  # Record Mr. McRitchie's confirmation (an `mcr` grade) of an insight's activity, then
  # redirect back to the pipeline — a no-JS form action for the column-2 Confirm
  # button. Upserts the one (activity, mcr) row (idempotent: re-confirming updates it).
  # A write, so on the current release gate it needs admin; it goes public with the
  # make-grading-actions-public change.
  def confirm
    activity = AgentActivity.find(params[:id])
    grade = ActionGrade.for_activity(activity).by_grader(ActionGrade::MCR)
                       .first_or_initialize(grader: ActionGrade::MCR)
    grade.disposition = ActionGrade::GOOD
    grade.slug        = params[:slug].presence || grade.slug.presence || activity.reason_slug
    rescue_and_log(target: grade) { grade.save! }
    redirect_to alex_pipeline_path(anchor: "col-confirmations"), notice: "Confirmed “#{grade.slug}”."
  rescue ActiveRecord::RecordNotFound
    redirect_to alex_pipeline_path, alert: "That activity no longer exists."
  end

  # The per-action grading drawer body, lazy-loaded into the shared turbo-frame on
  # row click. Renders Alex's grade editor, the McRitchie audit editor, and the
  # bank/discard actions for the action's existing (or fresh) grades.
  def feedback
    @action = AgentAction.find(params[:id])
    render partial: "heartbeat/drawer", locals: drawer_locals(@action)
  end

  # The per-activity grading drawer body — the activity-level analogue of #feedback,
  # lazy-loaded into the same shared turbo-frame when the operator clicks an activity's
  # grade affordance. Loads the activity's attributed actions once (for the rolled-up
  # token/cost/model summary the drawer shows) plus its current Alex grade + McRitchie
  # audit. Its editors POST to the JSON grade_activity endpoint (client-side fetch), so
  # this action, like #feedback, only READS.
  def feedback_activity
    @activity = AgentActivity.find(params[:id])
    actions = @activity.agent_actions.chronological.to_a
    grades  = @activity.action_grades.index_by(&:grader)
    render partial: "heartbeat/activity_drawer",
           locals: { activity: @activity, actions: actions,
                     alex: grades[ActionGrade::ALEX], mcr: grades[ActionGrade::MCR],
                     stage_transitions: stage_transitions_for([@activity]) }
  end
  alias_method :feedback_event, :feedback_activity

  # Upsert ONE grade for (action, grader) — the inline disposition radios and the
  # drawer editors both land here. An optional `intent` of bank|discard then routes
  # through ActionGrade#bank!/#discard!. Writes RAISE by design (a grade is a
  # deliberate user action), so they are wrapped in rescue_and_log with the grade as
  # target context, per backend discipline.
  def grade
    @action = AgentAction.find(params[:id])
    grader  = params[:grader].to_s
    @grade  = ActionGrade.for_action(@action).by_grader(grader).first_or_initialize(grader: grader)

    rescue_and_log(target: @grade) do
      @grade.disposition = params[:disposition].presence || @grade.disposition.presence || ActionGrade::GOOD
      @grade.slug        = params[:slug].presence || @grade.slug.presence || default_grade_slug(@action)
      @grade.long_form   = params[:long_form] if params.key?(:long_form)
      @grade.save!

      case params[:intent]
      when "bank"    then @grade.bank!
      when "discard" then @grade.discard!
      end

      @from_drawer = params[:surface] == "drawer"
      @counts = grade_counts(@action.session_id)
      @alex = ActionGrade.for_action(@action).by_grader(ActionGrade::ALEX).first
      @mcr  = ActionGrade.for_action(@action).by_grader(ActionGrade::MCR).first
      respond_to do |format|
        format.turbo_stream
        format.json { render json: grade_json(@grade) }
        format.html { redirect_to alex_heartbeat_path(session_id: @action.session_id) }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("hb-drawer", partial: "heartbeat/drawer_error", locals: { message: e.message }), status: :unprocessable_entity }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to alex_heartbeat_path(session_id: @action.session_id), alert: "Could not save feedback." }
    end
  end

  # Upsert ONE grade for (activity, grader) — the activity-level analogue of #grade,
  # targeting a narrated AgentActivity instead of a raw action. Same
  # disposition/slug/long_form/intent=bank|discard semantics. JSON ONLY by design:
  # E2 stays view-free so it never touches the heartbeat views or the existing
  # #grade turbo_stream path (E3 owns all heartbeat UI), which keeps the two
  # parallel tasks from colliding. Writes RAISE (a grade is a deliberate user
  # action), so they are wrapped in rescue_and_log with the grade as target
  # context, per backend discipline.
  def grade_activity
    @activity = AgentActivity.find(params[:id])
    grader = params[:grader].to_s

    if params[:intent] == "clear"
      unless ActionGrade::GRADERS.include?(grader)
        render json: { error: "Grader is not included in the list" }, status: :unprocessable_entity
        return
      end

      @grade = ActionGrade.for_activity(@activity).by_grader(grader).first
      rescue_and_log(target: @grade || @activity) do
        @grade&.destroy!
        render json: { agent_action_id: nil, agent_activity_id: @activity.id, grader: grader, cleared: true }
      end
      return
    end

    @grade = ActionGrade.for_activity(@activity).by_grader(grader).first_or_initialize(grader: grader)

    rescue_and_log(target: @grade) do
      @grade.disposition = params[:disposition].presence || @grade.disposition.presence || ActionGrade::GOOD
      @grade.slug        = params[:slug].presence || @grade.slug.presence || default_activity_grade_slug(@activity)
      @grade.long_form   = params[:long_form] if params.key?(:long_form)
      @grade.save!

      case params[:intent]
      when "bank"    then @grade.bank!
      when "discard" then @grade.discard!
      end

      render json: grade_json(@grade)
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  alias_method :grade_event, :grade_activity

  # The Insight Bank — exactly ActionGrade.banked, the curated lessons that make each
  # next agent smarter. Newest curation first.
  def insights
    # A banked grade targets EITHER a raw action OR a narrated activity (ActionGrade's
    # XOR), so eager-load BOTH — the view reads whichever target is set. Loading
    # only :agent_action left a banked activity grade (the Alex heartbeat's normal
    # output) dereferencing nil and 500ing the whole bank.
    @insights = ActionGrade.banked.includes(:agent_action, :agent_activity)
                           .order(updated_at: :desc).to_a
  end

  private

  # The session whose activity log we show by default: the one with the most recent
  # activity or action. Activity-primary now, so a session can narrate an activity before its first tool-call
  # attributes). nil when nothing has been captured yet (capture is forward-only,
  # so a fresh prod is legitimately empty).
  def latest_session_id
    AgentAction.order(occurred_at: :desc, id: :desc).limit(1).pick(:session_id) ||
      AgentActivity.order(opened_at: :desc, id: :desc).limit(1).pick(:session_id)
  end

  # Bucket the (already chronological) actions by stage, preserving each stage's
  # first-appearance order — except the null-stage "Session" group, which is
  # pulled to the very top regardless. Returns an ordered Array of [stage, actions].
  def group_by_stage(actions)
    grouped = actions.group_by { |action| action.stage.presence }
    session_group = grouped.delete(nil)

    groups = []
    groups << [nil, session_group] if session_group
    grouped.each { |stage, stage_actions| groups << [stage, stage_actions] }
    groups
  end

  # Distinct sessions for the switcher, most-recent first, as [[label, id], ...].
  # The id set is the union of every session that has captured an action OR narrated
  # an activity, keyed by its latest timestamp so an activity-only session still appears.
  # Each label then leads with the session's Pokémon mascot ("Bulbasaur · e2f6eb27")
  # so the picker reads as its handle, falling back to the bare session id when no
  # mascot was ever drawn for it (pre-mascot or seed sessions).
  def session_options
    times = AgentAction.group(:session_id).maximum(:occurred_at)
    ids = times.merge(AgentActivity.group(:session_id).maximum(:opened_at)) { |_id, a, b| [a, b].max }
               .sort_by { |_id, last_at| last_at }
               .reverse
               .map { |id, _last_at| id }
    labels = session_mascot_labels(ids)
    ids.map { |id| [labels[id] || id, id] }
  end

  # { session_id => "Pokémon · shortid" } for the sessions whose mascot resolves to
  # a seeded Pokémon. Two bulk queries — mascots by session_id, then Pokémon by
  # slug — so the switcher never N+1s, mirroring #pokemon_lookup.
  def session_mascot_labels(ids)
    return {} if ids.empty?

    mascots = SessionMascot.where(session_id: ids).index_by(&:session_id)
    pokemon = Pokemon.where(slug: mascots.values.map(&:mascot_slug).uniq).index_by(&:slug)
    ids.each_with_object({}) do |id, labels|
      name = pokemon[mascots[id]&.mascot_slug]&.name
      labels[id] = "#{name} · #{id.first(8)}" if name
    end
  end

  # One query for every mascot on the page so the Pokémon column reuses the
  # seeded Pokémon (name/emoji) instead of N+1 lookups; falls back to the slug.
  # Covers BOTH the raw actions AND the narrated activities — the activity rows now
  # show a mascot too.
  def pokemon_lookup(actions, activities = [])
    slugs = (actions.filter_map { |action| action.mascot.presence } +
             activities.filter_map { |activity| activity.mascot.presence }).uniq
    return {} if slugs.empty?

    Pokemon.where(slug: slugs).index_by(&:slug)
  end

  # One query for every acting SOUL on the page so the stacked Agent column reuses
  # the seeded Agent identity (name/emoji/status_color) instead of N+1 lookups. A
  # activity's `agent` is the soul that acted (avi/carl/…); the drill-down actions
  # inherit their activity's agent, so this single lookup covers both. Most activities carry
  # a nil agent (the base session mascot did it), so the set is usually tiny/empty.
  def agent_soul_lookup(activities)
    slugs = activities.filter_map { |activity| activity.agent.presence }.uniq
    return {} if slugs.empty?

    Agent.where(slug: slugs).index_by(&:slug)
  end

  # The stage-change spine for visible activities — every kind:"transition"
  # TaskEvent for the activities' task_slugs, grouped for status badges.
  def stage_transitions_for(activities)
    slugs = activities.filter_map { |activity| activity.task_slug.presence }.uniq
    return {} if slugs.empty?

    TaskTransition.where(task_slug: slugs)
             .order(:occurred_at, :id)
             .group_by(&:task_slug)
  end

  # Every activity's current grades in one query, grouped by activity id then keyed
  # by grader.
  def activity_grade_lookup(activities)
    return {} if activities.empty?

    ActionGrade.where(agent_activity_id: activities.map(&:id))
               .group_by(&:agent_activity_id)
               .transform_values { |grades| grades.index_by(&:grader) }
  end

  # The three live feedback tallies for a session: how many Alex graded, how many
  # McRitchie audited, and how many are banked into the Insight Bank. Counts grades
  # on BOTH the session's raw actions AND its narrated activities, so activity grading
  # reflects in the header stats on the next render, exactly as action grading does.
  def grade_counts(session_id)
    return { graded: 0, audited: 0, insights: 0 } if session_id.blank?

    action_ids = AgentAction.for_session(session_id).pluck(:id)
    activity_ids  = AgentActivity.for_session(session_id).pluck(:id)
    return { graded: 0, audited: 0, insights: 0 } if action_ids.empty? && activity_ids.empty?

    grades = ActionGrade.where(agent_action_id: action_ids)
                        .or(ActionGrade.where(agent_activity_id: activity_ids))
    { graded:   grades.by_grader(ActionGrade::ALEX).count,
      audited:  grades.by_grader(ActionGrade::MCR).count,
      insights: grades.banked.count }
  end

  # Locals for the drawer partial — the action plus its current Alex grade and
  # McRitchie audit (nil when ungraded).
  def drawer_locals(action)
    grades = action.action_grades.index_by(&:grader)
    { action: action, alex: grades[ActionGrade::ALEX], mcr: grades[ActionGrade::MCR] }
  end

  # A starter slug for an inline-radio grade (which carries no slug of its own): the
  # action's own event slug, so the ActionGrade slug-presence rule is satisfied with
  # a meaningful default the grader can refine in the drawer.
  def default_grade_slug(action)
    action.event_slug.presence || action.result_slug.presence || action.kind
  end

  # A starter slug for an activity grade that carries none of its own: the
  # activity's narrated reason, then its outcome, then its category — always a
  # meaningful default so the ActionGrade slug-presence rule holds.
  def default_activity_grade_slug(activity)
    activity.reason_slug.presence || activity.outcome_slug.presence || activity.category
  end

  # JSON shape for the Alpine/fetch fallback consumer (the turbo_stream path is the
  # primary one used by the UI). Carries BOTH target FKs — exactly one is set,
  # which tells the consumer whether this grade is of an action or an activity.
  def grade_json(grade)
    grade.slice(:id, :agent_action_id, :agent_activity_id, :grader, :disposition, :slug, :long_form, :banked, :discarded)
  end
end
