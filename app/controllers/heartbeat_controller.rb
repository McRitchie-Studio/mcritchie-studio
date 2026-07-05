class HeartbeatController < ApplicationController
  # Alex learning / distillation heartbeat — the agent-narrated event trajectory.
  #
  # #show reads AtomicEvent.for_session(...).chronological (oldest -> newest) as the
  # PRIMARY rows — agent-narrated spans (category · reason -> outcome) — and rolls the
  # raw AtomicActions attributed to each span (atomic_event_id) underneath as an
  # expandable, read-only drill-down; actions the agent never narrated (null
  # atomic_event_id) fall into the "Unlabeled" group. Grading is unchanged and lives
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

  # Page size for the cross-session All Spans view — the operator asked for 100
  # spans per page.
  ALL_SPANS_PER_PAGE = 100

  def show
    @session_id = params[:session_id].presence || latest_session_id
    @actions = @session_id ? AtomicAction.for_session(@session_id).chronological.to_a : []

    # Usage is metered per assistant TURN, so a turn's fan-out of tool-calls all
    # carry that turn's tokens/cost and render identical numbers. Flag the
    # non-primary rows of each source_turn_uuid (walked chronologically across the
    # WHOLE session) so the views fade their tokens/cost cells — the numbers are
    # inherited, not additive. Purely presentational; no total changes.
    @shared_turn_ids = helpers.heartbeat_shared_turn_ids(@actions)

    # The primary rows are now agent-narrated EVENT SPANS, not raw tool-calls. Each
    # event rolls up the actions attributed to it (atomic_event_id); the actions the
    # agent never narrated (null atomic_event_id) fall into the read-only "Unlabeled"
    # group. One actions query, grouped in Ruby, so events + Unlabeled share it with
    # no N+1.
    actions_by_event = @actions.group_by(&:atomic_event_id)
    @events = @session_id ? AtomicEvent.for_session(@session_id).chronological.to_a : []
    @event_rows = @events.map { |event| [event, actions_by_event[event.id] || []] }
    @unlabeled = actions_by_event[nil] || []

    @sessions = session_options
    @pokemon_by_slug = pokemon_lookup(@actions, @events)
    @agents_by_slug = agent_soul_lookup(@events)
    @event_grades = event_grade_lookup(@events)
    @stage_transitions = stage_transitions_for(@events)
    @counts = grade_counts(@session_id)
  end

  # Every narrated AtomicEvent SPAN across ALL sessions, newest-first, paginated
  # 100 per page — the cross-session companion to #show (which scopes to one
  # session). Reuses the SAME span table partial: one page of spans, each rolling
  # up the raw actions attributed to it (one grouped query, no N+1). There is no
  # "Unlabeled" group here — that is per-session context (null-span actions have no
  # coherent place in a newest-first cross-session list), so exactly one Unlabeled
  # group is never exceeded. Read-only meta surface, like #show.
  def all_spans
    @page  = [params[:page].to_i, 1].max
    scope  = AtomicEvent.order(opened_at: :desc, seq: :desc, id: :desc)
    @total = scope.count
    @events = scope.offset((@page - 1) * ALL_SPANS_PER_PAGE).limit(ALL_SPANS_PER_PAGE).to_a

    actions_by_event = AtomicAction.where(atomic_event_id: @events.map(&:id))
                                   .chronological.to_a.group_by(&:atomic_event_id)
    @event_rows = @events.map { |event| [event, actions_by_event[event.id] || []] }

    page_actions = actions_by_event.values.flatten
    @shared_turn_ids = helpers.heartbeat_shared_turn_ids(page_actions)
    @pokemon_by_slug = pokemon_lookup(page_actions, @events)
    @agents_by_slug  = agent_soul_lookup(@events)
    @event_grades    = event_grade_lookup(@events)
    @stage_transitions = stage_transitions_for(@events)
    @has_prev = @page > 1
    @has_next = @page * ALL_SPANS_PER_PAGE < @total
  end

  # The OPSD distillation pipeline as three columns, left→right:
  #   1. ACTIONS       — recent narrated spans (the raw trajectory)
  #   2. INSIGHTS      — Alex's banked grades (the distilled lessons)
  #   3. CONFIRMATIONS — McRitchie's mcr grades (the confirmed subset)
  # Read-only meta surface (like the rest of the heartbeat); the column-2 Confirm
  # button posts an mcr grade through the public grade endpoint.
  PIPELINE_SPANS    = 40
  PIPELINE_INSIGHTS = 40

  def pipeline
    # Column 1 — spans + their attributed actions (for cost) + their Alex grade
    # (for the "not" indicator).
    @spans = AtomicEvent.order(opened_at: :desc, seq: :desc, id: :desc).limit(PIPELINE_SPANS).to_a
    actions_by_span = AtomicAction.where(atomic_event_id: @spans.map(&:id))
                                  .chronological.to_a.group_by(&:atomic_event_id)
    @span_rows       = @spans.map { |span| [span, actions_by_span[span.id] || []] }
    @pokemon_by_slug = pokemon_lookup(actions_by_span.values.flatten, @spans)
    @agents_by_slug  = agent_soul_lookup(@spans)
    @span_grades     = event_grade_lookup(@spans) # {event_id => {grader => grade}} — the "not" flag

    # Candidates awaiting grade — disposition:"not" grades MINED from resolved QA
    # blocks (Insights::BlockMiner), not yet banked into an insight nor discarded.
    # The block ledger surfaced as the learning loop's newest raw material: each is
    # a pre-labeled failure the operator/Alex promotes (bank) or sets aside.
    @candidates = ActionGrade.pending_candidates.by_grader(ActionGrade::ALEX)
                             .includes(:atomic_event, :source_activity)
                             .order(created_at: :desc).limit(PIPELINE_INSIGHTS).to_a

    # Column 2 — Alex's banked insights (the distilled lessons), newest curation first.
    @insights = ActionGrade.banked.by_grader(ActionGrade::ALEX)
                           .includes(:atomic_event, :atomic_action)
                           .order(updated_at: :desc).limit(PIPELINE_INSIGHTS).to_a

    # Column 3 — McRitchie's confirmations (audit-of-Alex), newest first.
    @confirmations = ActionGrade.by_grader(ActionGrade::MCR)
                                .includes(:atomic_event, :atomic_action)
                                .order(updated_at: :desc).limit(PIPELINE_INSIGHTS).to_a

    # Which spans already carry a McRitchie confirmation — so a column-2 insight
    # shows "confirmed" instead of a Confirm button.
    @confirmed_event_ids = ActionGrade.by_grader(ActionGrade::MCR)
                                      .where.not(atomic_event_id: nil).pluck(:atomic_event_id).to_set
  end

  # Record Mr. McRitchie's confirmation (an `mcr` grade) of an insight's span, then
  # redirect back to the pipeline — a no-JS form action for the column-2 Confirm
  # button. Upserts the one (event, mcr) row (idempotent: re-confirming updates it).
  # A write, so on the current release gate it needs admin; it goes public with the
  # make-grading-actions-public change.
  def confirm
    event = AtomicEvent.find(params[:id])
    grade = ActionGrade.for_event(event).by_grader(ActionGrade::MCR)
                       .first_or_initialize(grader: ActionGrade::MCR)
    grade.disposition = ActionGrade::GOOD
    grade.slug        = params[:slug].presence || grade.slug.presence || event.reason_slug
    rescue_and_log(target: grade) { grade.save! }
    redirect_to alex_pipeline_path(anchor: "col-confirmations"), notice: "Confirmed “#{grade.slug}”."
  rescue ActiveRecord::RecordNotFound
    redirect_to alex_pipeline_path, alert: "That span no longer exists."
  end

  # The per-action grading drawer body, lazy-loaded into the shared turbo-frame on
  # row click. Renders Alex's grade editor, the McRitchie audit editor, and the
  # bank/discard actions for the action's existing (or fresh) grades.
  def feedback
    @action = AtomicAction.find(params[:id])
    render partial: "heartbeat/drawer", locals: drawer_locals(@action)
  end

  # The per-SPAN grading drawer body — the event-level analogue of #feedback,
  # lazy-loaded into the same shared turbo-frame when the operator clicks a span's
  # "grade" affordance. Loads the span's attributed actions once (for the rolled-up
  # token/cost/model summary the drawer shows) plus its current Alex grade + McRitchie
  # audit. Its editors POST to E2's JSON grade_event endpoint (client-side fetch), so
  # this action, like #feedback, only READS.
  def feedback_event
    @event = AtomicEvent.find(params[:id])
    actions = @event.atomic_actions.chronological.to_a
    grades  = @event.action_grades.index_by(&:grader)
    render partial: "heartbeat/event_drawer",
           locals: { event: @event, actions: actions,
                     alex: grades[ActionGrade::ALEX], mcr: grades[ActionGrade::MCR],
                     stage_transitions: stage_transitions_for([@event]) }
  end

  # Upsert ONE grade for (action, grader) — the inline disposition radios and the
  # drawer editors both land here. An optional `intent` of bank|discard then routes
  # through ActionGrade#bank!/#discard!. Writes RAISE by design (a grade is a
  # deliberate user action), so they are wrapped in rescue_and_log with the grade as
  # target context, per backend discipline.
  def grade
    @action = AtomicAction.find(params[:id])
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

  # Upsert ONE grade for (event, grader) — the span-level analogue of #grade,
  # targeting a narrated AtomicEvent span instead of a raw action. Same
  # disposition/slug/long_form/intent=bank|discard semantics. JSON ONLY by design:
  # E2 stays view-free so it never touches the heartbeat views or the existing
  # #grade turbo_stream path (E3 owns all heartbeat UI), which keeps the two
  # parallel tasks from colliding. Writes RAISE (a grade is a deliberate user
  # action), so they are wrapped in rescue_and_log with the grade as target
  # context, per backend discipline.
  def grade_event
    @event = AtomicEvent.find(params[:id])
    grader = params[:grader].to_s

    if params[:intent] == "clear"
      unless ActionGrade::GRADERS.include?(grader)
        render json: { error: "Grader is not included in the list" }, status: :unprocessable_entity
        return
      end

      @grade = ActionGrade.for_event(@event).by_grader(grader).first
      rescue_and_log(target: @grade || @event) do
        @grade&.destroy!
        render json: { atomic_action_id: nil, atomic_event_id: @event.id, grader: grader, cleared: true }
      end
      return
    end

    @grade = ActionGrade.for_event(@event).by_grader(grader).first_or_initialize(grader: grader)

    rescue_and_log(target: @grade) do
      @grade.disposition = params[:disposition].presence || @grade.disposition.presence || ActionGrade::GOOD
      @grade.slug        = params[:slug].presence || @grade.slug.presence || default_event_grade_slug(@event)
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

  # The Insight Bank — exactly ActionGrade.banked, the curated lessons that make each
  # next agent smarter. Newest curation first.
  def insights
    # A banked grade targets EITHER a raw action OR a narrated span (ActionGrade's
    # XOR), so eager-load BOTH — the view reads whichever target is set. Loading
    # only :atomic_action left a banked SPAN grade (the Alex heartbeat's normal
    # output) dereferencing nil and 500ing the whole bank.
    @insights = ActionGrade.banked.includes(:atomic_action, :atomic_event)
                           .order(updated_at: :desc).to_a
  end

  private

  # The session whose trajectory we show by default: the one with the most recent
  # activity. Event-primary now, so we consider the latest SPAN as well as the
  # latest raw action (a session can narrate a span before its first tool-call
  # attributes). nil when nothing has been captured yet (capture is forward-only,
  # so a fresh prod is legitimately empty).
  def latest_session_id
    AtomicAction.order(occurred_at: :desc, id: :desc).limit(1).pick(:session_id) ||
      AtomicEvent.order(opened_at: :desc, id: :desc).limit(1).pick(:session_id)
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
  # a span, keyed by its latest timestamp so an event-only session still appears.
  # Each label then leads with the session's Pokémon mascot ("Bulbasaur · e2f6eb27")
  # so the picker reads as its handle, falling back to the bare session id when no
  # mascot was ever drawn for it (pre-mascot or seed sessions).
  def session_options
    times = AtomicAction.group(:session_id).maximum(:occurred_at)
    ids = times.merge(AtomicEvent.group(:session_id).maximum(:opened_at)) { |_id, a, b| [a, b].max }
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
  # Covers BOTH the raw actions AND the narrated spans — the event rows now show
  # a mascot too (the span's own mascot, or its dominant action mascot), so the
  # span mascots must resolve through the same single lookup.
  def pokemon_lookup(actions, events = [])
    slugs = (actions.filter_map { |action| action.mascot.presence } +
             events.filter_map { |event| event.mascot.presence }).uniq
    return {} if slugs.empty?

    Pokemon.where(slug: slugs).index_by(&:slug)
  end

  # One query for every acting SOUL on the page so the stacked Agent column reuses
  # the seeded Agent identity (name/emoji/status_color) instead of N+1 lookups. A
  # span's `agent` is the soul that acted (avi/carl/…); the drill-down actions
  # inherit their span's agent, so this single lookup covers both. Most spans carry
  # a nil agent (the base session mascot did it), so the set is usually tiny/empty.
  def agent_soul_lookup(events)
    slugs = events.filter_map { |event| event.agent.presence }.uniq
    return {} if slugs.empty?

    Agent.where(slug: slugs).index_by(&:slug)
  end

  # The STAGE-CHANGE spine for the visible spans — every kind:"transition" TaskEvent
  # for the spans' task_slugs, in ONE query (WHERE task_slug IN (...)), grouped by
  # slug and chronological so heartbeat_span_status_meta can badge a span with the
  # stage its task changed to during the span's window with no per-row lookup. Empty
  # when no span carries a task_slug (PRE-task spans / a fresh session).
  def stage_transitions_for(events)
    slugs = events.filter_map { |event| event.task_slug.presence }.uniq
    return {} if slugs.empty?

    TaskEvent.transitions.where(task_slug: slugs)
             .order(:occurred_at, :id)
             .group_by(&:task_slug)
  end

  # Every span's current grades in one query, grouped by event id then keyed by
  # grader, so the event table renders each span's Alex grade + McRitchie audit
  # markers (and the drawer seeds from them) with no per-row lookup.
  def event_grade_lookup(events)
    return {} if events.empty?

    ActionGrade.where(atomic_event_id: events.map(&:id))
               .group_by(&:atomic_event_id)
               .transform_values { |grades| grades.index_by(&:grader) }
  end

  # The three live feedback tallies for a session: how many Alex graded, how many
  # McRitchie audited, and how many are banked into the Insight Bank. Counts grades
  # on BOTH the session's raw actions AND its narrated spans, so span grading (E2)
  # reflects in the header stats on the next render, exactly as action grading does.
  def grade_counts(session_id)
    return { graded: 0, audited: 0, insights: 0 } if session_id.blank?

    action_ids = AtomicAction.for_session(session_id).pluck(:id)
    event_ids  = AtomicEvent.for_session(session_id).pluck(:id)
    return { graded: 0, audited: 0, insights: 0 } if action_ids.empty? && event_ids.empty?

    grades = ActionGrade.where(atomic_action_id: action_ids)
                        .or(ActionGrade.where(atomic_event_id: event_ids))
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

  # A starter slug for a span (event) grade that carries none of its own: the
  # span's narrated reason, then its outcome, then its category — always a
  # meaningful default so the ActionGrade slug-presence rule holds.
  def default_event_grade_slug(event)
    event.reason_slug.presence || event.outcome_slug.presence || event.category
  end

  # JSON shape for the Alpine/fetch fallback consumer (the turbo_stream path is the
  # primary one used by the UI). Carries BOTH target FKs — exactly one is set,
  # which tells the consumer whether this grade is of an action or a span.
  def grade_json(grade)
    grade.slice(:id, :atomic_action_id, :atomic_event_id, :grader, :disposition, :slug, :long_form, :banked, :discarded)
  end
end
