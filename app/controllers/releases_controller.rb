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
    # Running-average rows sit AFTER the Nth release (the boundary of their window):
    # 3-avg between rows 3 and 4, 10-avg between rows 10 and 11. Clamped to the page
    # size and shown only on page 1, where the newest N releases actually live.
    rows_on_page = @releases.size
    @deployment_average_rows = [3, 10].map do |window|
      { label: "#{window}-release avg",
        averages: Release.deployment_stage_averages(limit: window),
        after_index: [window, rows_on_page].min - 1 }
    end
    @deployment_dashboard = @deployment_average_rows.last[:averages]
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
