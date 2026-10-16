# /applications: the apps a signed-in user owns (all of them for an admin), and
# one app's page with its health and its CTO (docs/agents/system/app-owners.md).
#
# Past the AdminWall (SIGNED_IN), every action answers 404, never 403, unless the
# viewer owns that app or is an admin: an app a viewer does not own does not
# exist for them, so an unannounced app's slug never leaks.
#
#   index   the visible apps; 404 for a viewer who owns none
#   show    name, emoji and colour, a lazy health frame, the CTO card
#   health  the frame: the app's health for the last morning window, cached
class ApplicationsController < ApplicationController
  HEALTH_TTL = 15.minutes

  before_action :load_app, only: %i[show health]

  def index
    @apps = AppOwnership.visible_apps(current_user).to_a
    raise ActiveRecord::RecordNotFound, "no visible apps" if @apps.empty?

    ctos = AppOwnership.ctos
    @ctos = @apps.to_h { |app| [ app.slug, AppOwnership.cto_for_app(app.slug, ctos: ctos) ] }
  end

  def show
    @cto = AppOwnership.cto_for_app(@app.slug)
    @owners = @app.memberships.owners.includes(:user).map(&:user) if AppOwnership.admin?(current_user)
  end

  # The health frame. One read per app per HEALTH_TTL: the hub reads itself in
  # process; any other app answers its token-gated /_studio/health_report, and
  # an app with no HEALTH_TOKEN_<SLUG> is "not wired" and is never fetched.
  def health
    @catalog_entry = DailyAppReport.apps.find { |entry| entry.slug == @app.slug }
    @ending = DailyAppReport.window_end
    @health = if @catalog_entry
      Rails.cache.fetch([ "applications/health", @app.slug, @ending.to_i ], expires_in: HEALTH_TTL) do
        DailyAppReport.health_for(@catalog_entry, @ending, fetcher: DailyAppReport::Fetcher.new, env: ENV)
      end
    end
    render layout: false
  end

  private

  def load_app
    @app = App.find_by(slug: params[:slug])
    raise ActiveRecord::RecordNotFound, "no such app" unless @app && AppOwnership.manage_app?(current_user, @app.slug)
  end
end
