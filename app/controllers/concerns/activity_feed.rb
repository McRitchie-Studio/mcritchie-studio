# The shared read layer behind the agent-narrated activity feed — the bulk lookups
# that turn a page of AgentActivity / AgentAction rows into the name / mascot / grade
# maps the tables render, each as ONE query so the views never N+1. Extracted from
# HeartbeatController so the reimagined /agents/activities page (AgentsController#activities)
# reuses the exact same feed queries the /alex/heartbeat surface built, instead of
# forking a second copy. Pure reads — nothing here mutates a record.
module ActivityFeed
  extend ActiveSupport::Concern

  private

  # Distinct sessions for the switcher/filter, most-recent first, as [[label, id], ...].
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

  # The richer session list the /agents/activities filter sidebar renders — one entry
  # per session with its Pokémon face (name + sprite + shiny), a short id, and its
  # activity count, most-recent first. Three bulk queries (session times, mascots,
  # Pokémon) so a 100-session sidebar never N+1s. `selected_ids` marks the sessions
  # already in the active ?sessions= filter so the view renders their checked state
  # server-side (Nokogiri-visible, no-JS correct).
  def session_filter_options(selected_ids = [])
    selected = Array(selected_ids).map(&:to_s).to_set
    times = AgentAction.group(:session_id).maximum(:occurred_at)
    times = times.merge(AgentActivity.group(:session_id).maximum(:opened_at)) { |_id, a, b| [a, b].max }
    ids = times.sort_by { |_id, last_at| last_at }.reverse.map { |id, _last_at| id }
    return [] if ids.empty?

    counts  = AgentActivity.where(session_id: ids).group(:session_id).count
    mascots = SessionMascot.where(session_id: ids).index_by(&:session_id)
    # Fallback mascot slug for sessions with no SessionMascot row (seed / pre-mascot
    # sessions): the session's own activity mascot. reverse.to_h keeps the newest per
    # session (pluck is newest-first, so the last pair after reverse wins).
    fallback = AgentActivity.where(session_id: ids).where.not(mascot: [nil, ""])
                            .order(opened_at: :desc).pluck(:session_id, :mascot).reverse.to_h
    slug_for = ->(id) { mascots[id]&.mascot_slug.presence || fallback[id] }
    pokemon  = Pokemon.where(slug: (mascots.values.map(&:mascot_slug) + fallback.values).compact.uniq).index_by(&:slug)
    # { type_key => hex } in one query so each session row can wear its Pokémon's
    # primary-type colour with no per-row lookup (empty {} when the enumeral gem/table
    # isn't installed — the view then falls back to the neutral accent).
    type_colors = Pokemon.type_colors

    ids.map do |id|
      mon  = pokemon[slug_for.call(id)]
      type = mon && (mon.primary_type.presence || mon.types&.first)
      {
        id:         id,
        short:      id.to_s.first(8),
        name:       mon&.name || id.to_s.first(8),
        sprite_url: mon&.sprite_url,
        shiny:      !!mascots[id]&.shiny,
        type_color: type && type_colors[type],
        count:      counts[id].to_i,
        last_at:    times[id],
        selected:   selected.include?(id.to_s)
      }
    end
  end

  # The active-filter CHIPS at the top of the feed — one { id, name, type_color } per
  # currently-selected session. Every query is scoped to the small, explicitly-filtered
  # id set (no cross-session GROUP BY / full-table pluck), so the main #activities render
  # stays cheap; the full all-sessions list the sidebar shows is built separately by
  # #session_filter_options behind the lazy aa-filter-frame.
  def selected_session_chips(ids)
    ids = Array(ids).map(&:to_s).reject(&:blank?).uniq
    return [] if ids.empty?

    mascots  = SessionMascot.where(session_id: ids).index_by(&:session_id)
    # Fallback mascot for a selected session with no SessionMascot row: its own newest
    # activity mascot (scoped to the selected ids, so this never scans other sessions).
    fallback = AgentActivity.where(session_id: ids).where.not(mascot: [nil, ""])
                            .order(opened_at: :desc).pluck(:session_id, :mascot).reverse.to_h
    slug_for = ->(id) { mascots[id]&.mascot_slug.presence || fallback[id] }
    pokemon  = Pokemon.where(slug: (mascots.values.map(&:mascot_slug) + fallback.values).compact.uniq).index_by(&:slug)
    type_colors = Pokemon.type_colors

    ids.map do |id|
      mon  = pokemon[slug_for.call(id)]
      type = mon && (mon.primary_type.presence || mon.types&.first)
      { id: id, name: mon&.name || id.first(8), type_color: type && type_colors[type] }
    end
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

  # One query for every acting/supervising SOUL on the page so the stacked Agent column reuses
  # the seeded Agent identity (name/emoji/status_color) instead of N+1 lookups. A
  # activity's `agent` is the soul that acted (avi/carl/…); the drill-down actions
  # inherit their activity's agent/supervisor, so this single lookup covers both.
  # Most activities carry a nil agent (the base session mascot did it), so the set
  # is usually tiny/empty.
  def agent_soul_lookup(activities)
    slugs = activities.flat_map { |activity| [activity.agent.presence, activity.supervisor_agent.presence] }
                      .compact.uniq
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

  # Every visible ACTION's current grades in one query, grouped by action id then
  # keyed by grader — the action-level analogue of #activity_grade_lookup, so the
  # /agents/activities drill-down rows render their inline Alex/McRitchie grade cells
  # with no per-row query.
  def action_grade_lookup(actions)
    ids = Array(actions).map(&:id)
    return {} if ids.empty?

    ActionGrade.where(agent_action_id: ids)
               .group_by(&:agent_action_id)
               .transform_values { |grades| grades.index_by(&:grader) }
  end

  # The full locals to render ONE agents/_activity_row partial (a single activity tbody).
  # Used by ActivitiesBroadcaster so a live broadcast renders the SAME markup the table
  # loop does (the dual-render-path discipline). Actions default to the activity's own,
  # newest-first — matching AgentsController#activities' ordering.
  def activity_row_locals(activity, actions = nil)
    actions ||= activity.agent_actions.order(occurred_at: :desc, seq: :desc, id: :desc).to_a
    {
      activity: activity,
      actions: actions,
      pokemon_by_slug: pokemon_lookup(actions, [activity]),
      agents_by_slug: agent_soul_lookup([activity]),
      activity_grades: activity_grade_lookup([activity]),
      action_grades: action_grade_lookup(actions),
      shared_turn_ids: feed_shared_turn_ids(actions),
      stage_transitions: stage_transitions_for([activity])
    }
  end

  # The shared-turn dup ids for an activity's actions, computed off a chronological pass
  # (the fade is defined by first-seen order) via the heartbeat helper — works outside a
  # request (e.g. in the broadcaster) through the app-wide helper proxy.
  def feed_shared_turn_ids(actions)
    chronological = Array(actions).sort_by { |a| [a.occurred_at || Time.at(0), a.seq.to_i, a.id] }
    ApplicationController.helpers.heartbeat_shared_turn_ids(chronological)
  end
end
