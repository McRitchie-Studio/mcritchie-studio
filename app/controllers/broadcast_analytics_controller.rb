# GET /broadcasts/analytics — the email analytics dashboard (admin): how every
# broadcast is doing against Resend's limits, and what readers did with it.
# ?broadcast=<slug> narrows it to one email. The numbers are Broadcasts::Analytics.
class BroadcastAnalyticsController < ApplicationController
  before_action :require_admin

  def show
    @broadcasts = Broadcast.recent
    @broadcast = @broadcasts.find { |b| b.slug == params[:broadcast] } if params[:broadcast].present?
    @analytics = Broadcasts::Analytics.new(broadcast: @broadcast)
    @summary = @analytics.summary
  end
end
