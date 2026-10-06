# /intelligence — the task-development trends dashboard. All aggregation lives in
# TaskIntelligence; this controller just instantiates it and hands the view a
# single object to read from. Admin-only, like every ops page (AdminWall).
class IntelligenceController < ApplicationController
  def index
    @intel = TaskIntelligence.new
  end
end
