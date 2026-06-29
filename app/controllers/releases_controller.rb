class ReleasesController < ApplicationController
  skip_before_action :require_authentication, only: %i[index show]

  def index
    @releases = Release.includes(:tasks).order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
    @duration_dashboard = Release::DurationCache.dashboard(limit: 3)
  end

  def show
    @release = Release.includes(:release_events, tasks: :task_events).find_by(slug: params[:slug])
    return redirect_to all_deployments_path, alert: "Release not found" unless @release

    @duration_metrics = Release::DurationCache.cached_or_built(@release)
    @release_events = @release.release_events.chronological.to_a
    @tasks = @release.tasks.includes(:task_events).order(:position, :created_at).to_a
  end
end
