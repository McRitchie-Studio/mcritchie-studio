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
#   usage   JSON: this month's CTO usage meter and today's totals (AgentUsage,
#           docs/agents/system/agent-usage.md); owner or admin, like the page
#   usage_cap  admin only: the app's package tier and the per-app cap lift
class ApplicationsController < ApplicationController
  HEALTH_TTL = 15.minutes

  before_action :load_app, only: %i[show health usage usage_cap]
  before_action :require_admin_for_cap, only: :usage_cap

  def index
    @apps = AppOwnership.visible_apps(current_user).to_a
    raise ActiveRecord::RecordNotFound, "no visible apps" if @apps.empty?

    ctos = AppOwnership.ctos
    @ctos = @apps.to_h { |app| [ app.slug, AppOwnership.cto_for_app(app.slug, ctos: ctos) ] }
  end

  def show
    @cto = AppOwnership.cto_for_app(@app.slug)
    @admin = AppOwnership.admin?(current_user)
    @owners = @app.memberships.owners.includes(:user).map(&:user) if @admin
    @meter = AgentUsage.meter(@app)
    @today = usage_today(@meter)
  end

  def usage
    meter = AgentUsage.meter(@app)
    render json: { data: meter.as_json.merge("today" => usage_today(meter).as_json) }
  end

  # The admin's two levers: the tier (a config/workspace_packages.yml key, or
  # none) and the lift, which makes the app unlimited until it is cleared.
  def usage_cap
    tier = params.dig(:usage_cap, :package_tier).presence
    unless tier.nil? || WorkspacePackage.keys.include?(tier)
      return redirect_to application_path(@app.slug), alert: "Unknown tier.", status: :see_other
    end

    lift = ActiveModel::Type::Boolean.new.cast(params.dig(:usage_cap, :lifted))
    attrs = { package_tier: tier }
    attrs.merge!(cto_cap_lifted_at: Time.current, cto_cap_lifted_by: current_user.email) if lift && @app.cto_cap_lifted_at.nil?
    attrs.merge!(cto_cap_lifted_at: nil, cto_cap_lifted_by: nil) unless lift
    saved = rescue_and_log(target: @app) { @app.update(attrs) }
    if saved
      redirect_to application_path(@app.slug), notice: "Usage: #{tier || 'no tier'}, cap #{lift ? 'lifted' : 'on'}.", status: :see_other
    else
      redirect_to application_path(@app.slug), alert: "Not saved: #{@app.errors.full_messages.to_sentence}.", status: :see_other
    end
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

  def usage_today(meter)
    return AgentUsage::Totals.zero unless meter.domain

    AgentUsage.daily(meter.domain, days: 1).last&.last || AgentUsage::Totals.zero
  end

  # An owner who is not an admin gets the same 404 as a stranger.
  def require_admin_for_cap
    raise ActiveRecord::RecordNotFound, "no such app" unless AppOwnership.admin?(current_user)
  end

  def load_app
    @app = App.find_by(slug: params[:slug])
    raise ActiveRecord::RecordNotFound, "no such app" unless @app && AppOwnership.manage_app?(current_user, @app.slug)
  end
end
