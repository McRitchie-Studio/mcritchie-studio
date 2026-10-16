# /agents/:slug/settings: a CTO's identity and its owner's settings
# (docs/agents/system/app-owners.md). The one setting today is where the CTO's
# daily report posts: the same ReportDestination row (`cto_report:<domain>`)
# Alex edits at /admin/report_destinations.
#
# CTO souls only (config/cto_reports.yml). Past the AdminWall (SIGNED_IN), every
# action answers 404 unless the viewer owns the CTO's app or is an admin, so a CTO
# of an app the viewer does not own does not exist for them.
#
#   index   /agents/settings: the CTOs the viewer may set; 404 when none
#   show    name, avatar, app, the report channel and its on/off switch, and the
#           app's usage meter (AgentUsage)
#   update  saves the channel and switch; the channel must be one the picker
#           offers (AppOwnership.report_channels), checked here, not trusted
#
# Nothing here gives a CTO a tool or a capability, or reaches another app.
class AgentSettingsController < ApplicationController
  before_action :load_cto, only: %i[show update]

  def index
    @ctos = AppOwnership.visible_ctos(current_user)
    raise ActiveRecord::RecordNotFound, "no visible agents" if @ctos.empty?

    @apps = App.where(slug: @ctos.map(&:app_slug)).index_by(&:slug)
    @destinations = ReportDestination.includes(:discord_channel).where(report_key: @ctos.map(&:report_key)).index_by(&:report_key)
  end

  def show
    @destination = ReportDestination.includes(:discord_channel).find_by(report_key: @cto.report_key)
    @bot = AppOwnership.report_bot(@cto)
    @channels = AppOwnership.report_channels(@cto).to_a
    @parent_names = DiscordChannel.where(external_id: @channels.filter_map(&:parent_external_id)).pluck(:external_id, :name).to_h
    @last_delivery = ReportDelivery.where(report_key: @cto.report_key).newest_first.first
    @meter = AgentUsage.meter(@app)
  end

  def update
    destination = ReportDestination.find_or_initialize_by(report_key: @cto.report_key)
    channel_id = params.dig(:report_destination, :discord_channel_id).presence
    channel = channel_id && DiscordChannel.find_by(id: channel_id)
    if channel_id && !offered?(channel, destination)
      return redirect_to settings_agent_path(@cto.slug), alert: "That channel is not one #{@cto.display_name} can post in.", status: :see_other
    end

    destination.discord_channel = channel
    destination.enabled = ActiveModel::Type::Boolean.new.cast(params.dig(:report_destination, :enabled))
    destination.updated_by = current_user.email
    saved = rescue_and_log(target: @app) { destination.save }

    if saved
      where = channel ? channel.display_name : "no channel"
      redirect_to settings_agent_path(@cto.slug), notice: "Daily report: #{where}, #{destination.enabled? ? 'on' : 'off'}.", status: :see_other
    else
      redirect_to settings_agent_path(@cto.slug), alert: "Not saved: #{destination.errors.full_messages.to_sentence}.", status: :see_other
    end
  end

  private

  def load_cto
    @cto = AppOwnership.cto_for_agent(params[:slug])
    raise ActiveRecord::RecordNotFound, "no such agent" unless @cto && AppOwnership.manage_app?(current_user, @cto.app_slug)

    @app = App.find_by(slug: @cto.app_slug)
    raise ActiveRecord::RecordNotFound, "no such app" unless @app
  end

  # The picker's set, or the channel already saved (kept so a Save that only
  # turns the report off does not drop it).
  def offered?(channel, destination)
    return false if channel.nil?
    return true if destination.persisted? && destination.discord_channel_id == channel.id

    AppOwnership.report_channels(@cto).exists?(id: channel.id)
  end
end
