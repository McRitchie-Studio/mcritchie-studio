# /communications — the communications record: who said what, and what was asked.
#
# Read-only, like /admin/desk. Rows arrive from the ingest and are worked by the
# enrichment pipeline; this page is how the operator SEES the record, not how it
# is edited.
#
# THE PATH IS /communications AND THE GATE IS STILL require_admin. The operator
# asked for the short path rather than /admin/communications; the page renders
# deal correspondence, so the path is a preference and the gate is not.
class CommunicationsController < ApplicationController
  before_action :require_admin

  # Guards the filters. A status or channel that is not in the model's own
  # enumerations is ignored rather than passed to the query, so a hand-edited
  # URL cannot turn into an unfiltered dump or a 500.
  def index
    @kind    = permitted(params[:kind], Communication::KINDS)
    @status  = permitted(params[:status], Communication::STATUSES)
    @channel = permitted(params[:channel], Communication::CHANNELS)
    @entity  = params[:entity].presence

    scope = Communication.all
    scope = scope.where(kind: @kind) if @kind
    scope = scope.with_status(@status) if @status
    scope = scope.on_channel(@channel) if @channel
    scope = scope.for_entity(@entity) if @entity

    # Asks first, newest first — the operator's stated reading order.
    @communications = scope.board_order.limit(200)

    @counts = Communication.group(:kind).count
    @open_asks = Communication.open_asks.count
    # Drawn from the rows themselves: there is no entity table, and a filter
    # listing entities nobody has any communications for is noise.
    @entities = Communication.where.not(entity: nil).distinct.order(:entity).pluck(:entity)
  end

  private

  def permitted(value, allowed)
    allowed.include?(value) ? value : nil
  end
end
