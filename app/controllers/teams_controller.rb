class TeamsController < ApplicationController
  def index
    @teams = Team.includes(:people, :home_arena).order(:name)
  end
end
