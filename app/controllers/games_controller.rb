class GamesController < ApplicationController
  # GET /games/:year
  # Season overview — grid of all weeks with kickoff date range, game count,
  # and a primetime teaser per week.
  def season
    @year = params[:year].to_i
    @season = Season.find_by(year: @year, league: "nfl")
    return redirect_to nfl_hub_path, alert: "Season #{@year} not found" unless @season

    @regular_slates = @season.slates
                             .where(slate_type: "regular_season")
                             .order(:sequence)
                             .includes(games: [:home_team, :away_team])

    @other_slates = @season.slates
                           .where.not(slate_type: "regular_season")
                           .where.not(sequence: 0)
                           .order(:sequence)
                           .includes(games: [:home_team, :away_team])

    @season_options = Season.where(league: "nfl").order(year: :desc).pluck(:year)

    # Current/upcoming week: first regular slate whose latest game hasn't kicked off yet
    today = Date.current
    @current_week = @regular_slates.find { |s| s.ends_at && s.ends_at >= today }&.sequence

    # Bye teams per week (computed once, cached). Stores short_names directly to
    # avoid N+1 lookups in the view.
    nfl_teams = Team.where(league: "nfl").index_by(&:slug)
    all_team_slugs = nfl_teams.keys
    @bye_teams_by_week = @regular_slates.each_with_object({}) do |slate, h|
      participating = slate.games.flat_map { |g| [g.home_team_slug, g.away_team_slug] }
      h[slate.sequence] = (all_team_slugs - participating).map { |s| nfl_teams[s].short_name }.sort
    end
  end

  # GET /games/:year/week/:week
  def week
    @year = params[:year].to_i
    @week = params[:week].to_i

    season = Season.find_by(year: @year, league: "nfl")
    return redirect_to root_path, alert: "Season not found" unless season

    @slate = season.slates.find_by(sequence: @week)
    return redirect_to root_path, alert: "Week not found" unless @slate

    @games = @slate.games
                   .includes(:home_team, :away_team)
                   .order(:kickoff_at)

    @games_by_day = @games.group_by { |g| g.display_day }

    @prev_week = season.slates.where(slate_type: "regular_season").where("sequence < ?", @week).order(sequence: :desc).first&.sequence
    @next_week = season.slates.where(slate_type: "regular_season").where("sequence > ?", @week).order(:sequence).first&.sequence
  end

  # GET /games/:year/week/:week/:slug
  def show
    @year = params[:year].to_i
    @week = params[:week].to_i

    season = Season.find_by(year: @year, league: "nfl")
    return redirect_to root_path, alert: "Season not found" unless season

    @slate = season.slates.find_by(sequence: @week)
    return redirect_to root_path, alert: "Week not found" unless @slate

    @game = @slate.games.includes(:home_team, :away_team).find_by(slug: params[:slug])
    return redirect_to games_week_path(@year, @week), alert: "Game not found" unless @game

    # Load rosters for this slate (or fall back to offseason).
    # :image_caches must be eager-loaded — the player_card partial calls
    # athlete.headshot_url which reads through image_caches; without this
    # we N+1 ~48 queries per game page render.
    roster_includes = { roster_spots: { person: { athlete_profile: [:grades, :image_caches] } } }

    @home_roster = Roster.includes(roster_includes)
                         .find_by(team_slug: @game.home_team_slug, slate_slug: @slate.slug)
    @home_roster ||= Roster.includes(roster_includes)
                           .find_by(team_slug: @game.home_team_slug, slate_slug: "#{@year}-nfl-offseason")

    @away_roster = Roster.includes(roster_includes)
                         .find_by(team_slug: @game.away_team_slug, slate_slug: @slate.slug)
    @away_roster ||= Roster.includes(roster_includes)
                           .find_by(team_slug: @game.away_team_slug, slate_slug: "#{@year}-nfl-offseason")

    # Load team unit rankings for matchup display
    season = Season.find_by(year: @year, league: "nfl")
    if season
      @home_rankings = TeamRanking.where(team_slug: @game.home_team_slug, season_slug: season.slug, week: nil).index_by(&:rank_type)
      @away_rankings = TeamRanking.where(team_slug: @game.away_team_slug, season_slug: season.slug, week: nil).index_by(&:rank_type)
    else
      @home_rankings = {}
      @away_rankings = {}
    end
  end
end
