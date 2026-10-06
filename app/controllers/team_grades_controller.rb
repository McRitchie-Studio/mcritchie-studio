class TeamGradesController < ApplicationController
  # GET /nfl-team-grades/:team_slug
  def show
    @team = Team.find_by(slug: params[:team_slug], league: "nfl")
    return redirect_to nfl_hub_path, alert: "Team not found" unless @team

    season = Season.find_by(slug: "2025-nfl") || Season.where(league: "nfl").order(year: :desc).first
    offseason = season&.slates&.find_by(sequence: 0)

    roster_includes = { roster_spots: { person: { athlete_profile: [:grades, :image_caches] } } }
    @roster = Roster.includes(roster_includes).find_by(team_slug: @team.slug, slate_slug: offseason&.slug)

    if @roster
      @offense = @roster.offense_starting_12
      @defense = @roster.defense_starting_12
    else
      @offense = {}
      @defense = {}
    end
  end
end
