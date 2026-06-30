class HeartbeatController < ApplicationController
  # Alex learning / distillation heartbeat — the per-action atomic trajectory
  # VIEW. Reads AtomicAction.for_session(...).chronological (oldest -> newest) and
  # groups the rows by stage for display. Read-only meta surface, so like the
  # launcher it opts out of the engine's authenticate-by-default before_action.
  #
  # The launcher's Alex avenue points at alex_heartbeat_path, which routes here
  # (it used to render LauncherController#heartbeat's placeholder). The named
  # route stayed stable across the repoint, so the launcher anchor followed for
  # free. Feedback capture (Alex grades each event, Mr. McRitchie grades Alex) is
  # a separate follow-up (T4) — this view is read-only.
  skip_before_action :require_authentication

  def show
    @session_id = params[:session_id].presence || latest_session_id
    @actions = @session_id ? AtomicAction.for_session(@session_id).chronological.to_a : []
    @groups = group_by_stage(@actions)
    @sessions = session_options
    @pokemon_by_slug = pokemon_lookup(@actions)
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

  # Distinct sessions for the switcher, most-recent first. [[label, id], ...].
  def session_options
    AtomicAction.group(:session_id).maximum(:occurred_at)
                .sort_by { |_id, last_at| last_at }
                .reverse
                .map { |id, _last_at| id }
  end

  # One query for every mascot on the page so the Pokémon column reuses the
  # seeded Pokémon (name/emoji) instead of N+1 lookups; falls back to the slug.
  def pokemon_lookup(actions)
    slugs = actions.filter_map { |action| action.mascot.presence }.uniq
    return {} if slugs.empty?

    Pokemon.where(slug: slugs).index_by(&:slug)
  end
end
