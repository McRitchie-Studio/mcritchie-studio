class ReleasesController < ApplicationController
  RELEASES_PER_PAGE = 25

  skip_before_action :require_authentication, only: %i[index show]

  def index
    releases_scope = Release.order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
    @release_page = requested_page
    @release_count = releases_scope.count
    @release_total_pages = [(@release_count / RELEASES_PER_PAGE.to_f).ceil, 1].max
    @release_page = @release_total_pages if @release_page > @release_total_pages
    @release_per_page = RELEASES_PER_PAGE
    @release_offset = (@release_page - 1) * @release_per_page
    @releases = releases_scope.includes(:tasks).offset(@release_offset).limit(@release_per_page)
    @duration_dashboard = Release::DurationCache.dashboard(limit: 3)
  end

  def show
    @release = Release.includes(:release_events, tasks: :task_events).find_by(slug: params[:slug])
    return redirect_to all_deployments_path, alert: "Release not found" unless @release

    @duration_metrics = Release::DurationCache.cached_or_built(@release)
    @release_events = @release.release_events.chronological.to_a
    @tasks = @release.tasks.includes(:task_events).order(:position, :created_at).to_a
  end

  private

  def requested_page
    page = params[:page].to_i
    page.positive? ? page : 1
  end
end
