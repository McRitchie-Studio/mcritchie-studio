class LineupGraphicsController < ApplicationController
  include LineupLabelsHelper

  layout "lineup_graphic"

  # Offense slots that appear in the TikTok 5×2 graphic (no WR3, no Flex).
  OFFENSE_LINE_SLOTS  = %i[lt lg c rg rt].freeze
  OFFENSE_SKILL_SLOTS = %i[qb rb wr1 wr2 te].freeze

  # Defense slots arranged into the TikTok 3×3 graphic.
  DEFENSE_ROWS = [
    %i[edge1 dl1 edge2],
    %i[lb1 lb2 ss],
    %i[fs cb1 cb2]
  ].freeze

  def show
    @team = Team.find_by(slug: params[:slug])
    return redirect_to nfl_rosters_path, alert: "Team not found" unless @team

    @roster = @team.rosters.first
    return redirect_to nfl_rosters_path, alert: "No roster for #{@team.name}" unless @roster

    case params[:side]
    when "offense" then render_offense
    when "defense" then render_defense
    else                render_full
    end
  end

  private

  def render_full
    @offense = @roster.offense_starting_12.map { |slot, pick| [offense_slot_label(slot, pick), pick] }
    @defense = @roster.defense_starting_12.map { |slot, pick| [defense_slot_label(slot, pick), pick] }
    @special = @roster.special_teams_starting_4.flat_map { |slot, picks| picks.map { |p| [slot.to_s.upcase, p] } }
    # Default render → app/views/lineup_graphics/show.html.erb
  end

  def render_offense
    o = @roster.offense_starting_12
    @offense_line  = OFFENSE_LINE_SLOTS.map  { |s| [offense_slot_label(s, o[s]), o[s]] }
    @offense_skill = OFFENSE_SKILL_SLOTS.map { |s| [offense_slot_label(s, o[s]), o[s]] }
    render "offense"
  end

  def render_defense
    d = @roster.defense_starting_12
    @defense_rows = DEFENSE_ROWS.map do |row|
      row.map { |s| [defense_slot_label(s, d[s]), d[s]] }
    end
    render "defense"
  end
end
