class DepthChartsController < ApplicationController
  include LineupLabelsHelper
  # Board primitive (studio-engine 0.29.0): the shared reorder + lock actions.
  # `reorder` restamps a lane's entry_ids to sequential depths 1..N (DG2), skipping
  # locked/pinned entries (DG4); `board_toggle_lock` flips a starter's `locked` flag
  # — both with the ErrorLog write discipline the hand-rolled versions carried.
  include Studio::Board::Reorderable
  board_reorderable model: DepthChartEntry, id_attr: :id, param: :entry_ids,
                    gap: 1, direction: :asc, skip_locked: true, rank_attr: :depth

  # The route names it depth_charts#toggle_lock; the concern provides board_toggle_lock.
  alias_method :toggle_lock, :board_toggle_lock

  skip_before_action :require_authentication, only: [:show]
  before_action :set_team, only: [:show]

  POSITION_ORDER = {
    "offense" => %w[QB RB FB WR TE LT LG C RG RT OT OG T G],
    "defense" => %w[EDGE DE DT NT DL LB ILB OLB MLB CB S FS SS],
    "special_teams" => %w[K P LS]
  }.freeze

  def show
    @season = Season.find_by(year: 2025, league: "nfl")
    @chart = @team.depth_chart
    return redirect_to nfl_rosters_path, alert: "No depth chart for #{@team.name}" unless @chart

    grades = AthleteGrade.where(season_slug: @season&.slug)
                         .where(athlete_slug: @chart.depth_chart_entries.joins(person: :athlete_profile).pluck("athletes.slug"))
                         .index_by(&:athlete_slug)
    @grades_by_person = {}
    @chart.depth_chart_entries.includes(person: { athlete_profile: :image_caches }).each do |e|
      ath = e.person.athlete_profile
      @grades_by_person[e.person_slug] = grades[ath.slug] if ath
    end

    @entries_by_side = @chart.depth_chart_entries
                             .includes(person: { athlete_profile: :image_caches })
                             .group_by(&:side)
                             .transform_values do |entries|
      entries.group_by(&:position)
             .sort_by { |pos, _| POSITION_ORDER[entries.first.side]&.index(pos) || 99 }
             .to_h
             .transform_values { |es| es.sort_by(&:depth) }
    end

    # Build a person_slug → slot label map for any athlete who lands in the
    # team's starting 28 (12 off + 12 def + 4 ST). Depth numbers are dropped —
    # depth is implied by the depth chart's row order. Flex labels derive
    # from the picked player's actual position.
    @starter_labels = {}
    roster = @team.rosters.first
    if roster
      roster.offense_starting_12.each do |slot, pick|
        next unless pick
        @starter_labels[pick.person_slug] = offense_slot_label(slot, pick)
      end
      roster.defense_starting_12.each do |slot, pick|
        next unless pick
        @starter_labels[pick.person_slug] = defense_slot_label(slot, pick)
      end
      roster.special_teams_starting_4.each do |slot, picks|
        picks.each { |p| @starter_labels[p.person_slug] ||= slot.to_s.upcase }
      end
    end
  end

  # reorder + toggle_lock are provided by Studio::Board::Reorderable (see the
  # board_reorderable config above). `reorder` reads params[:entry_ids] and
  # restamps depths 1..N skipping locked entries; `toggle_lock` (aliased to
  # board_toggle_lock) flips the entry's `locked` flag.

  private

  def set_team
    @team = Team.find_by(slug: params[:slug])
    redirect_to nfl_rosters_path, alert: "Team not found" unless @team
  end
end
