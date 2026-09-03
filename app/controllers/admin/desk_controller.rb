module Admin
  # /admin/desk — the mail side of the knowledge-capture front door
  # (team@mcritchie.studio). Lists what has arrived and what the capture sweep
  # did with it. Read-only for now: filing happens through the
  # knowledge-capture SOP, not through buttons.
  class DeskController < ApplicationController
    before_action :require_admin

    STATUSES = DeskCaptureItem::STATUSES

    def index
      @status = STATUSES.include?(params[:status]) ? params[:status] : nil
      scope = DeskCaptureItem.recent_first
      scope = scope.where(status: @status) if @status
      @items = scope.limit(200)
      @counts = DeskCaptureItem.group(:status).count
    end
  end
end
