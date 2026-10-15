module Admin
  # /admin/report_destinations (Ops → Report destinations): which Discord channel
  # each registered report (config/report_destinations.yml) posts to, whether it
  # is on, and its last delivery (docs/agents/system/report-destinations.md).
  #
  # index    one row per registered key, a select of the directory's postable,
  #          unarchived channels grouped by category, an enable toggle.
  # update   saves one key's channel and toggle (PATCH /admin/report_destinations/:report_key).
  # refresh  runs DiscordChannelSyncJob now and says what it saw.
  class ReportDestinationsController < ApplicationController
    before_action :require_admin

    def index
      @registrations = ReportDestinations.registrations
      @destinations = ReportDestination.includes(:discord_channel).where(report_key: @registrations.map(&:key)).index_by(&:report_key)
      @last_deliveries = @registrations.to_h { |r| [ r.key, ReportDelivery.where(report_key: r.key).newest_first.first ] }
      @channels = DiscordChannel.selectable.directory_order.to_a
      @parent_names = DiscordChannel.where(external_id: @channels.filter_map(&:parent_external_id)).pluck(:external_id, :name).to_h
      @last_synced_at = DiscordChannel.maximum(:synced_at)
      @sync_idle = DiscordChannelSyncJob.idle_reason
    end

    def update
      registration = ReportDestinations.registration(params[:report_key])
      raise ActionController::RoutingError, "unknown report key" unless registration

      destination = ReportDestination.find_or_initialize_by(report_key: registration.key)
      channel_id = params.dig(:report_destination, :discord_channel_id).presence
      destination.discord_channel = channel_id && DiscordChannel.find_by(id: channel_id)
      destination.enabled = ActiveModel::Type::Boolean.new.cast(params.dig(:report_destination, :enabled))
      destination.updated_by = current_user&.email

      if destination.save
        where = destination.discord_channel ? destination.discord_channel.display_name : "no channel"
        redirect_to admin_report_destinations_path, notice: "#{registration.label}: #{where}, #{destination.enabled? ? 'on' : 'off'}.", status: :see_other
      else
        redirect_to admin_report_destinations_path, alert: "#{registration.label} not saved: #{destination.errors.full_messages.to_sentence}.", status: :see_other
      end
    end

    def refresh
      reason = DiscordChannelSyncJob.idle_reason
      return redirect_to(admin_report_destinations_path, alert: "Channels not refreshed: #{reason}.", status: :see_other) if reason

      summary = DiscordChannelSyncJob.perform_now
      flash_key = summary.ok? ? :notice : :alert
      redirect_to admin_report_destinations_path, flash_key => "Channels refreshed: #{summary}.", status: :see_other
    end
  end
end
