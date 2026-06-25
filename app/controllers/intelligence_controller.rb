# /intelligence — the task-development trends dashboard. All aggregation lives in
# TaskIntelligence; this controller just instantiates it and hands the view a
# single object to read from (matching DashboardController's read-only posture,
# including skipping auth so the board surfaces stay public).
class IntelligenceController < ApplicationController
  skip_before_action :require_authentication

  def index
    @intel = TaskIntelligence.new
  end
end
