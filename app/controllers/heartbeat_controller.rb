class HeartbeatController < ApplicationController
  # Alex learning / distillation heartbeat — the agent-narrated event trajectory.
  #
  # #show has two faces, chosen by the session_id param:
  #   - NO session_id -> the GLOBAL FEED (#load_feed): every narrated span across
  #     ALL sessions, newest-first (AtomicEvent.recent). Lightweight — one query, no
  #     per-event action roll-up; each row drills into that session's detail view.
  #   - a session_id  -> that session's DETAIL trajectory (#load_session): the
  #     agent-narrated spans (category · reason -> outcome) chronological, each rolling
  #     the raw AtomicActions attributed to it (atomic_event_id) underneath as an
  #     expandable, read-only drill-down; actions the agent never narrated (null
  #     atomic_event_id) fall into the "Unlabeled" group.
  # Grading is unchanged and lives entirely in the drawer: #feedback renders the
  # per-action grading drawer, #grade upserts a grade (and banks/discards it), and
  # #insights is the curated Insight Bank.
  #
  # Open meta surface, like the launcher: it opts out of the engine's
  # authenticate-by-default before_action. The launcher's Alex avenue points at
  # alex_heartbeat_path, which routes here.
  skip_before_action :require_authentication

  # Cap on the global feed so an unbounded span history never blows out the page.
  # Truncation past this is surfaced in the view rather than silently dropped.
  FEED_LIMIT = 200

  def show
    @session_id = params[:session_id].presence
    @session_id ? load_session : load_feed
    @sessions = session_options
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
                     alex: grades[ActionGrade::ALEX], mcr: grades[ActionGrade::MCR] }
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
    @insights = ActionGrade.banked.includes(:atomic_action).order(updated_at: :desc).to_a
  end

  private

  # The global feed: every narrated span across every session, newest-first, capped
  # at FEED_LIMIT (truncation surfaced in the view, never silently dropped). No
  # per-event action roll-up — the feed is a lightweight index whose rows drill into
  # the per-session detail view, where the token/cost/model roll-up lives. One
  # AtomicEvent query plus the shared mascot lookup. Legitimately empty on a fresh
  # prod (capture is forward-only).
  def load_feed
    @feed = true
    @feed_total = AtomicEvent.count
    @feed_events = AtomicEvent.recent.limit(FEED_LIMIT).to_a
    @feed_truncated = @feed_total > @feed_events.size
    @feed_insights = ActionGrade.banked.count
    @pokemon_by_slug = pokemon_lookup([], @feed_events)
  end

  # One session's detail trajectory — the narrated spans (chronological, so the
  # session still reads as a trajectory) with their raw tool-calls rolled up
  # underneath, the Unlabeled group for un-narrated calls, mascots, span grades, and
  # the header tallies. One actions query, grouped in Ruby, so events + Unlabeled
  # share it with no N+1.
  def load_session
    @feed = false
    @actions = AtomicAction.for_session(@session_id).chronological.to_a

    # Usage is metered per assistant TURN, so a turn's fan-out of tool-calls all carry
    # that turn's tokens/cost and render identical numbers. Flag the non-primary rows of
    # each source_turn_uuid (walked chronologically across the WHOLE session) so the
    # detail table fades their tokens/cost cells — inherited, not additive. Purely
    # presentational; no total changes. (The feed is a lightweight index with no
    # per-action tokens/cost, so it needs none of this.)
    @shared_turn_ids = helpers.heartbeat_shared_turn_ids(@actions)

    actions_by_event = @actions.group_by(&:atomic_event_id)
    @events = AtomicEvent.for_session(@session_id).chronological.to_a
    @event_rows = @events.map { |event| [event, actions_by_event[event.id] || []] }
    @unlabeled = actions_by_event[nil] || []
    @pokemon_by_slug = pokemon_lookup(@actions, @events)
    @event_grades = event_grade_lookup(@events)
    @counts = grade_counts(@session_id)
  end

  # Distinct sessions for the switcher, most-recent first — the union of every
  # session that has captured an action OR narrated a span, keyed by its latest
  # timestamp so an event-only session still appears.
  def session_options
    times = AtomicAction.group(:session_id).maximum(:occurred_at)
    times.merge(AtomicEvent.group(:session_id).maximum(:opened_at)) { |_id, a, b| [a, b].max }
         .sort_by { |_id, last_at| last_at }
         .reverse
         .map { |id, _last_at| id }
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
