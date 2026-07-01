class HeartbeatController < ApplicationController
  # Alex learning / distillation heartbeat — the per-action atomic trajectory.
  #
  # #show reads AtomicAction.for_session(...).chronological (oldest -> newest) and
  # groups the rows by stage for display, then loads the ActionGrade feedback layer
  # (T5): each action carries up to two grades — Alex's grade and the McRitchie
  # audit-of-Alex. #feedback renders the per-action grading drawer, #grade upserts a
  # grade (and banks/discards it), and #insights is the curated Insight Bank.
  #
  # Open meta surface, like the launcher: it opts out of the engine's
  # authenticate-by-default before_action. The launcher's Alex avenue points at
  # alex_heartbeat_path, which routes here.
  skip_before_action :require_authentication

  def show
    @session_id = params[:session_id].presence || latest_session_id
    @actions = @session_id ? AtomicAction.for_session(@session_id).chronological.to_a : []
    @groups = group_by_stage(@actions)
    @sessions = session_options
    @pokemon_by_slug = pokemon_lookup(@actions)
    @grades = grades_lookup(@actions)
    @counts = grade_counts(@session_id)
  end

  # The per-action grading drawer body, lazy-loaded into the shared turbo-frame on
  # row click. Renders Alex's grade editor, the McRitchie audit editor, and the
  # bank/discard actions for the action's existing (or fresh) grades.
  def feedback
    @action = AtomicAction.find(params[:id])
    render partial: "heartbeat/drawer", locals: drawer_locals(@action)
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

  # The Insight Bank — exactly ActionGrade.banked, the curated lessons that make each
  # next agent smarter. Newest curation first.
  def insights
    @insights = ActionGrade.banked.includes(:atomic_action).order(updated_at: :desc).to_a
  end

  private

  # The session whose trajectory we show by default: the one with the most recent
  # action. nil when nothing has been captured yet (capture is forward-only, so a
  # fresh prod is legitimately empty).
  def latest_session_id
    AtomicAction.order(occurred_at: :desc, id: :desc).limit(1).pick(:session_id)
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
  # Each label leads with the session's Pokémon mascot ("Bulbasaur · e2f6eb27") so
  # the picker reads as its handle, falling back to the bare session id when no
  # mascot was ever drawn for it (pre-mascot or seed sessions).
  def session_options
    ids = AtomicAction.group(:session_id).maximum(:occurred_at)
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
  def pokemon_lookup(actions)
    slugs = actions.filter_map { |action| action.mascot.presence }.uniq
    return {} if slugs.empty?

    Pokemon.where(slug: slugs).index_by(&:slug)
  end

  # One query for every grade on the page: { action_id => { "alex" => grade,
  # "mcr" => grade } }. Lets each feedback cell render its stored grade without an
  # N+1 — and lets the drawer reuse the same loaded rows.
  def grades_lookup(actions)
    ids = actions.map(&:id)
    return {} if ids.empty?

    ActionGrade.where(atomic_action_id: ids).each_with_object({}) do |grade, lookup|
      (lookup[grade.atomic_action_id] ||= {})[grade.grader] = grade
    end
  end

  # The three live feedback tallies for a session's actions: how many Alex graded,
  # how many McRitchie audited, and how many are banked into the Insight Bank.
  def grade_counts(session_id)
    return { graded: 0, audited: 0, insights: 0 } if session_id.blank?

    ids = AtomicAction.for_session(session_id).pluck(:id)
    return { graded: 0, audited: 0, insights: 0 } if ids.empty?

    grades = ActionGrade.where(atomic_action_id: ids)
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

  # JSON shape for the Alpine/fetch fallback consumer (the turbo_stream path is the
  # primary one used by the UI).
  def grade_json(grade)
    grade.slice(:id, :atomic_action_id, :grader, :disposition, :slug, :long_form, :banked, :discarded)
  end
end
