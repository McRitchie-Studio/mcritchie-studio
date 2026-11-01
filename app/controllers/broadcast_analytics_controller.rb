# GET /broadcasts/analytics — the email analytics dashboard (admin): how every
# broadcast is doing against Resend's limits, and what readers did with it.
# ?broadcast=<slug> narrows it to one email. The numbers are Broadcasts::Analytics.
class BroadcastAnalyticsController < ApplicationController
  before_action :require_admin

  def show
    @broadcasts = Broadcast.recent
    @broadcast = @broadcasts.find { |b| b.slug == params[:broadcast] } if params[:broadcast].present?
    # A filter naming no email (a stale link) shows everything, and says so.
    @unknown_filter = params[:broadcast].present? && @broadcast.nil?
    @analytics = Broadcasts::Analytics.new(broadcast: @broadcast)
    @summary = @analytics.summary
  end

  # GET /broadcasts/analytics/cyvasse-four — the four-style test side by side.
  def cyvasse_four
    scoreboard = Broadcasts::CyvasseFourScoreboard.new
    @rows = scoreboard.rows
    @verdict = scoreboard.verdict
    @pick_answers = scoreboard.pick_answers
  end
end
