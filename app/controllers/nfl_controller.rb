class NflController < ApplicationController
  def index
    @season = Season.find_by(year: 2025, league: "nfl")
    @team_count = Team.nfl.count
    @person_count = Person.count
    @game_count = @season ? Game.joins(slate: :season).where(seasons: { slug: @season.slug }, slates: { sequence: 1 }).count : 0

    # Newest NFL season with a populated schedule — drives the "current season"
    # card. Falls back gracefully if no schedule has been seeded yet.
    @current_nfl_season = Season.where(league: "nfl")
                                .joins(:slates)
                                .where(slates: { slate_type: "regular_season" })
                                .order(year: :desc)
                                .distinct
                                .first
    @current_season_game_count = @current_nfl_season ? Game.joins(:slate).where(slates: { season_slug: @current_nfl_season.slug, slate_type: "regular_season" }).count : 0
    @qb_count = Athlete.where(position: "QB").joins(:grades).distinct.count
    @oline_count = Athlete.where(position: %w[LT LG C RG RT OT OG]).joins(:grades).distinct.count
    @wr_count = Athlete.where(position: %w[WR TE]).joins(:grades).distinct.count
    @rb_count = Athlete.where(position: %w[RB FB HB]).joins(:grades).distinct.count
    @def_count = Athlete.where(position: %w[EDGE DE DT NT DL LB ILB OLB MLB CB S FS SS]).joins(:grades).distinct.count
    @pass_rush_count = Athlete.where(position: %w[EDGE DE DT NT]).joins(:grades).distinct.count
    @coverage_count = Athlete.where(position: %w[CB S FS SS]).joins(:grades).distinct.count
    @coach_count = Coach.where(sport: "football").count
    @pass_first_count = @season ? CoachRanking.where(rank_type: "pass_first", season_slug: @season.slug).count : 0
    @prospect_count = Athlete.where(sport: "football").where.not(draft_pick: nil)
                              .joins("INNER JOIN contracts ON contracts.person_slug = athletes.person_slug AND contracts.contract_type = 'draft_pick'")
                              .distinct.count
    @contract_count = Contract.joins(:team).where(teams: { league: "nfl" }).count
    @team_ranking_count = TeamRanking.count
  end

  COACH_ROLE_ORDER = %w[head_coach offensive_coordinator defensive_coordinator special_teams_coordinator].freeze

  def rosters
    @season = Season.find_by(year: 2025, league: "nfl")
    nfl_team_slugs = Team.where(league: "nfl").pluck(:slug)
    slate_slug = Roster.where(team_slug: nfl_team_slugs)
                       .joins(:slate)
                       .where(slates: { season_slug: @season&.slug })
                       .order("slates.sequence")
                       .pick(:slate_slug)
    @rosters = Roster.joins(:team)
                     .where(teams: { league: "nfl" }, slate_slug: slate_slug)
                     .includes(:team)
                     .order("teams.name")
    @coaches_by_team = Coach.where(sport: "football", team_slug: @rosters.map(&:team_slug))
                            .includes(:person, :image_caches)
                            .group_by(&:team_slug)
                            .transform_values { |cs| cs.sort_by { |c| COACH_ROLE_ORDER.index(c.role) || 99 } }

    @week1_games_by_team = {}
    if @season
      week1_slate = @season.slates.find_by(sequence: 1)
      if week1_slate
        week1_slate.games.each do |g|
          @week1_games_by_team[g.home_team_slug] = g
          @week1_games_by_team[g.away_team_slug] = g
        end
      end
    end
  end
end
