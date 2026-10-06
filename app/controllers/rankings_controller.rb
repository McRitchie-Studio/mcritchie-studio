class RankingsController < ApplicationController
  before_action :require_admin, only: [:confirm_draft_pick]
  before_action :set_season, only: [:quarterback, :offensive_line, :receiving, :rushing, :defense, :pass_rush, :coverage, :pass_first, :team_unit, :prospects]
  before_action :set_impact_context, only: [:player_impact, :confirm_draft_pick]

  # GET /nfl-quarterback-rankings
  def quarterback
    @sort_by = params[:sort].presence || "overall"

    grade_column = case @sort_by
                   when "passing"  then "athlete_grades.pass_grade_pff"
                   when "rushing"  then "athlete_grades.run_grade_pff"
                   else                 "athlete_grades.overall_grade_pff"
                   end

    @players = ranked_players(%w[QB], @season.slug, grade_column)
  end

  # GET /nfl-offensive-line-rankings
  def offensive_line
    @sort_by = params[:sort].presence || "pass_block"

    grade_column = case @sort_by
                   when "run_block" then "athlete_grades.run_block_grade_pff"
                   when "offense"   then "athlete_grades.offense_grade_pff"
                   else                  "athlete_grades.pass_block_grade_pff"
                   end

    @players = ranked_players(%w[LT LG C RG RT OT OG], @season.slug, grade_column)
  end

  # GET /nfl-receiving-rankings
  def receiving
    @sort_by = params[:sort].presence || "route"

    grade_column = case @sort_by
                   when "overall" then "athlete_grades.overall_grade_pff"
                   else                "athlete_grades.pass_route_grade_pff"
                   end

    @players = ranked_players(%w[WR TE], @season.slug, grade_column)
  end

  # GET /nfl-rushing-rankings
  def rushing
    @sort_by = params[:sort].presence || "rushing"

    grade_column = case @sort_by
                   when "overall" then "athlete_grades.overall_grade_pff"
                   else                "athlete_grades.run_grade_pff"
                   end

    @players = ranked_players(%w[RB FB HB], @season.slug, grade_column)
  end

  # GET /nfl-defense-rankings
  def defense
    @sort_by = params[:sort].presence || "overall"

    grade_column = case @sort_by
                   when "pass_rush" then "athlete_grades.pass_rush_grade_pff"
                   when "coverage"  then "athlete_grades.coverage_grade_pff"
                   when "run_def"   then "athlete_grades.rush_defense_grade_pff"
                   else                  "athlete_grades.defense_grade_pff"
                   end

    @players = ranked_players(
      %w[EDGE DE DT NT DL LB ILB OLB MLB CB S FS SS],
      @season.slug, grade_column
    )
  end

  # GET /nfl-pass-rush-rankings
  def pass_rush
    @sort_by = params[:sort].presence || "pass_rush"

    grade_column = case @sort_by
                   when "defense" then "athlete_grades.defense_grade_pff"
                   else                "athlete_grades.pass_rush_grade_pff"
                   end

    @players = ranked_players(%w[EDGE DE DT NT], @season.slug, grade_column)
  end

  # GET /nfl-coverage-rankings
  def coverage
    @sort_by = params[:sort].presence || "coverage"

    grade_column = case @sort_by
                   when "defense" then "athlete_grades.defense_grade_pff"
                   else                "athlete_grades.coverage_grade_pff"
                   end

    @players = ranked_players(%w[CB S FS SS], @season.slug, grade_column)
  end

  # GET /nfl-pass-first-rankings
  def pass_first
    @sort_by = params[:sort].presence || "pass_first"
    rank_type = @sort_by == "pass_heavy" ? "pass_heavy" : "pass_first"

    query = CoachRanking
      .where(rank_type: rank_type, season_slug: @season.slug)
      .joins(coach: [:person, :team])
      .select(
        "coach_rankings.*",
        "people.first_name", "people.last_name",
        "teams.name AS team_name", "teams.short_name AS team_short_name",
        "teams.emoji AS team_emoji", "teams.conference", "teams.division",
        "coaches.lean"
      )
      .order("coach_rankings.rank ASC")

    if params[:search].present?
      term = "%#{params[:search].downcase}%"
      query = query.where(
        "LOWER(people.first_name) LIKE ? OR LOWER(people.last_name) LIKE ? OR LOWER(teams.name) LIKE ?",
        term, term, term
      )
    end

    @rankings = query.to_a
  end

  # GET /nfl-team-rankings/:id
  def team_unit
    @team = Team.find_by(slug: params[:id])
    return redirect_to nfl_hub_path, alert: "Team not found" unless @team

    rankings = TeamRanking.where(team_slug: @team.slug, season_slug: @season.slug, week: nil)
    @rankings_by_type = rankings.index_by(&:rank_type)
  end

  # GET /nfl-player-impact/:player_id/to/:team_id
  def player_impact
    @athlete = Athlete.find_by(person_slug: @person.slug)
    @grade = AthleteGrade.find_by(athlete_slug: @athlete&.slug, season_slug: @season&.slug)

    @impact = TeamRanking.simulate_impact(
      person_slug: @person.slug,
      target_team_slug: @team.slug,
      season_slug: @season.slug
    )

    @current_rankings = TeamRanking.where(
      team_slug: @team.slug, season_slug: @season.slug, week: nil
    ).index_by(&:rank_type)

    # Build side-by-side lineups
    team_spots = load_team_spots(@team.slug)
    @affected_side = offense_position?(@athlete&.position) ? :offense : :defense
    @current_lineup = pick_starters(team_spots, @affected_side)

    # "With player" lineup — add the new player to the pool
    new_person = Person.includes(athlete_profile: :grades).find_by(slug: @person.slug)
    if new_person&.athlete_profile
      added_spot = LineupSpot.new(new_person, new_person.athlete_profile.position)
      modified_spots = team_spots + [added_spot]
      @modified_lineup = pick_starters(modified_spots, @affected_side)
    else
      @modified_lineup = @current_lineup
    end

    @draft_confirmed = Contract.exists?(person_slug: @person.slug, team_slug: @team.slug, contract_type: "draft_pick")
  end

  # POST /nfl-player-impact/:player_id/to/:team_id/confirm
  def confirm_draft_pick
    # Guard: already confirmed
    if Contract.exists?(person_slug: @person.slug, team_slug: @team.slug, contract_type: "draft_pick")
      return redirect_to nfl_player_impact_path(player_id: @person.slug, team_id: @team.slug),
                         notice: "#{@person.full_name} is already confirmed on the #{@team.name} roster."
    end

    athlete = Athlete.find_by(person_slug: @person.slug)
    contract = Contract.find_by(person_slug: @person.slug, team_slug: @team.slug) ||
               Contract.new(person_slug: @person.slug, team_slug: @team.slug)

    rescue_and_log(target: contract) do
      ActiveRecord::Base.transaction do
        # Delegate contract creation + college expiry to service
        Draft::CreateContract.new(
          person_slug: @person.slug,
          team_slug: @team.slug,
          position: athlete&.position
        ).call

        # Recompute rankings unless bench_rookie
        unless params[:bench_rookie] == "1"
          TeamRanking.compute_all!(season_slug: @season.slug)
        end

        # Create News at refined stage
        News.create!(
          title: "#{@person.full_name} drafted by #{@team.name}",
          stage: "refined",
          title_short: "#{@person.last_name} to #{@team.short_name}",
          summary: "#{@person.full_name} (#{athlete&.position}) has been drafted by the #{@team.name}.",
          feeling: "hyped",
          feeling_emoji: "\u{1F525}",
          what_happened: "#{@person.full_name} was drafted by the #{@team.name}.",
          primary_person: @person.full_name,
          primary_person_slug: @person.slug,
          primary_team: @team.name,
          primary_team_slug: @team.slug,
          primary_action: "drafted",
          reviewed_at: Time.current,
          processed_at: Time.current,
          refined_at: Time.current
        )
      end

      redirect_to nfl_player_impact_path(player_id: @person.slug, team_id: @team.slug),
                   notice: "#{@person.full_name} confirmed to the #{@team.name} roster."
    end
  rescue StandardError => e
    redirect_to nfl_player_impact_path(player_id: @person.slug, team_id: @team.slug),
                alert: "Failed to confirm draft pick: #{e.message}"
  end

  # GET /nfl-prospects
  def prospects
    @draft_year = params[:year].to_i
    @draft_year = 2025 unless [2025, 2026].include?(@draft_year)
    @sort_by = params[:sort].presence || "pick"

    contract_type = @draft_year == 2026 ? "mock_pick" : "draft_pick"

    query = AthleteGrade
      .joins(athlete: :person)
      .joins("INNER JOIN contracts ON contracts.person_slug = people.slug AND contracts.contract_type = '#{contract_type}'")
      .joins("INNER JOIN teams ON teams.slug = contracts.team_slug AND teams.league = 'nfl'")
      .where(season_slug: @season.slug)
      .where.not(athletes: { draft_pick: nil })
      .select(
        "athlete_grades.*",
        "people.first_name", "people.last_name", "people.slug AS person_slug_ref",
        "athletes.position", "athletes.draft_pick", "athletes.draft_round",
        "teams.name AS team_name", "teams.short_name AS team_short_name",
        "teams.emoji AS team_emoji", "teams.slug AS team_slug_ref"
      )
      .group("athlete_grades.id, people.id, athletes.id, teams.id")

    case @sort_by
    when "grade"
      query = query.order(Arel.sql("athlete_grades.overall_grade_pff DESC NULLS LAST"))
    when "position"
      query = query.order(Arel.sql("athletes.position ASC, athletes.draft_pick ASC"))
    else
      query = query.order(Arel.sql("athletes.draft_pick ASC"))
    end

    if params[:search].present?
      term = "%#{params[:search].downcase}%"
      query = query.where(
        "LOWER(people.first_name) LIKE ? OR LOWER(people.last_name) LIKE ? OR LOWER(teams.name) LIKE ? OR athletes.position ILIKE ?",
        term, term, term, term
      )
    end

    @prospects = query.to_a
  end

  # GET /nfl-coaches
  def coaches
    @sort_by = params[:sort].presence || "team"

    query = Coach.where(sport: "football")
      .joins(:person, :team)
      .select(
        "coaches.*",
        "people.first_name", "people.last_name",
        "teams.name AS team_name", "teams.short_name AS team_short_name",
        "teams.emoji AS team_emoji", "teams.conference", "teams.division"
      )

    if params[:search].present?
      term = "%#{params[:search].downcase}%"
      query = query.where(
        "LOWER(people.first_name) LIKE ? OR LOWER(people.last_name) LIKE ? OR LOWER(teams.name) LIKE ?",
        term, term, term
      )
    end

    role_order = "CASE coaches.role WHEN 'head_coach' THEN 1 WHEN 'offensive_coordinator' THEN 2 WHEN 'defensive_coordinator' THEN 3 WHEN 'special_teams_coordinator' THEN 4 END"

    query = case @sort_by
            when "name" then query.order(Arel.sql("people.last_name ASC, people.first_name ASC"))
            when "role" then query.order(Arel.sql("#{role_order}, teams.name ASC"))
            else query.order(Arel.sql("teams.conference ASC, teams.division ASC, teams.name ASC, #{role_order}"))
            end

    @coaches = query.to_a
  end

  private

  def set_season
    @season = Season.find_by(year: 2025, league: "nfl")
    return redirect_to root_path, alert: "Season not found" unless @season
  end

  def set_impact_context
    @person = Person.find_by(slug: params[:player_id])
    return redirect_to nfl_hub_path, alert: "Player not found" unless @person

    @team = Team.find_by(slug: params[:team_id])
    return redirect_to nfl_hub_path, alert: "Team not found" unless @team

    @season = Season.find_by(year: 2025, league: "nfl")
    return redirect_to nfl_hub_path, alert: "Season not found" unless @season
  end

  def ranked_players(positions, season_slug, sort_column)
    query = AthleteGrade
      .joins(athlete: :person)
      .joins("LEFT JOIN contracts ON contracts.person_slug = people.slug AND contracts.contract_type IN ('active', 'draft_pick')")
      .joins("LEFT JOIN teams ON teams.slug = contracts.team_slug AND teams.league = 'nfl'")
      .where(season_slug: season_slug)
      .where(athletes: { position: positions })
      .where("#{sort_column} IS NOT NULL AND #{sort_column} > 0")
      .select(
        "athlete_grades.*",
        "people.first_name", "people.last_name", "people.slug AS person_slug_ref",
        "athletes.position",
        "teams.name AS team_name", "teams.short_name AS team_short_name",
        "teams.emoji AS team_emoji", "teams.slug AS team_slug_ref"
      )
      .order(Arel.sql("#{sort_column} DESC NULLS LAST"))
      .group("athlete_grades.id, people.id, athletes.id, teams.id")

    if params[:search].present?
      term = "%#{params[:search].downcase}%"
      query = query.where(
        "LOWER(people.first_name) LIKE ? OR LOWER(people.last_name) LIKE ? OR LOWER(teams.name) LIKE ?",
        term, term, term
      )
    end

    query.to_a
  end

  # --- Player Impact lineup helpers ---

  LineupSpot = Struct.new(:person, :position)

  OFFENSE_POS = %w[QB RB FB HB WR TE LT LG C RG RT OT OG T G].freeze
  DEFENSE_POS = %w[EDGE DE DT NT DL DI LB ILB OLB MLB CB S FS SS].freeze

  def offense_position?(pos)
    OFFENSE_POS.include?(pos)
  end

  def load_team_spots(team_slug)
    people = Person
      .joins("INNER JOIN contracts ON contracts.person_slug = people.slug AND contracts.contract_type IN ('active', 'draft_pick')")
      .joins("INNER JOIN teams ON teams.slug = contracts.team_slug AND teams.league = 'nfl'")
      .where("teams.slug = ?", team_slug)
      .includes(athlete_profile: :grades)
      .distinct.to_a

    people.filter_map do |p|
      athlete = p.athlete_profile
      next unless athlete
      LineupSpot.new(p, athlete.position)
    end
  end

  def pick_starters(spots, side)
    if side == :offense
      pick_offense_12(spots)
    else
      pick_defense_12(spots)
    end
  end

  def pick_offense_12(spots)
    {
      qb:    top_spots(spots, %w[QB], 1, :pass_grade_pff),
      rb:    top_spots(spots, %w[RB FB HB], 2, :run_grade_pff),
      wr:    top_spots(spots, %w[WR], 3, :pass_route_grade_pff),
      te:    top_spots(spots, %w[TE], 1, :pass_route_grade_pff),
      oline: top_spots(spots, %w[LT LG C RG RT OT OG T G], 5, :pass_block_grade_pff)
    }
  end

  def pick_defense_12(spots)
    edges = top_spots(spots, %w[EDGE DE], 2, :pass_rush_grade_pff)
    dl    = top_spots(spots, %w[DT NT DL DI], 2, :rush_defense_grade_pff)
    taken = edges + dl
    flex  = spots.select { |s| %w[EDGE DE DT NT DL DI].include?(s.position) && !taken.include?(s) }
                 .sort_by { |s| -(spot_grade(s, :overall_grade_pff) || 0) }.first(1)
    {
      edge: edges, dl: dl, flex: flex,
      lb:   top_spots(spots, %w[LB ILB OLB MLB], 2, :overall_grade_pff),
      cb:   top_spots(spots, %w[CB], 3, :coverage_grade_pff),
      s:    top_spots(spots, %w[S FS SS], 2, :coverage_grade_pff)
    }
  end

  def top_spots(spots, positions, count, grade_key)
    spots.select { |s| positions.include?(s.position) }
         .sort_by { |s| -(spot_grade(s, grade_key) || 0) }
         .first(count)
  end

  def spot_grade(spot, key)
    spot.person&.athlete_profile&.grades&.first&.send(key)
  end
end
