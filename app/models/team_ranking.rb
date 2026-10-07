class TeamRanking < ApplicationRecord
  include Sluggable
  # Its slug carries a snake_case word (a role, a stat or rank type), so a
  # rename accepts underscores between the words.
  self.slug_format = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/

  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :season, foreign_key: :season_slug, primary_key: :slug

  UNIT_TYPES = %w[quarterback receiving rushing pass_block run_block pass_rush coverage run_defense].freeze
  AGGREGATE_TYPES = %w[pass_offense run_offense offense pass_defense defense power].freeze
  RANK_TYPES = (UNIT_TYPES + AGGREGATE_TYPES).freeze

  validates :rank_type, presence: true, inclusion: { in: RANK_TYPES }
  validates :rank, presence: true, inclusion: { in: 1..32 }
  validates :team_slug, uniqueness: { scope: [:rank_type, :season_slug, :week] }

  scope :for_season, ->(slug) { where(season_slug: slug) }
  scope :for_week, ->(week) { where(week: week) }
  scope :preseason, -> { where(week: nil) }
  scope :units, -> { where(rank_type: UNIT_TYPES) }
  scope :aggregates, -> { where(rank_type: AGGREGATE_TYPES) }

  def name_slug
    base = "#{team_slug}-#{rank_type}-#{season_slug}"
    week ? "#{base}-week-#{week}" : base
  end

  # Compute all team rankings for a given season (and optional week).
  # Builds unit scores from AthleteGrade data, then computes aggregates.
  #
  # `grades_season_slug:` lets you decouple "what season am I ranking" from
  # "which grades do I score against". Useful for preseason: compute
  # 2026-nfl rankings against 2025-nfl grades since this year's PFF data
  # doesn't exist until games play out.
  def self.compute_all!(season_slug:, week: nil, grades_season_slug: nil)
    team_grades = fetch_team_grades(grades_season_slug || season_slug)
    unit_scores = compute_unit_scores(team_grades)
    aggregate_scores = compute_aggregate_scores(unit_scores)
    all_scores = unit_scores.merge(aggregate_scores) { |_type, u, a| u.merge(a) }

    # Flatten: { rank_type => { team_slug => score } }
    flat = {}
    all_scores.each do |rank_type, teams_hash|
      flat[rank_type] = teams_hash
    end

    # Rank each type 1-32 (DESC by score)
    flat.each do |rank_type, teams_hash|
      sorted = teams_hash.sort_by { |_slug, score| -score }
      sorted.each_with_index do |(team_slug, score), idx|
        TeamRanking.find_or_initialize_by(
          team_slug: team_slug,
          rank_type: rank_type,
          season_slug: season_slug,
          week: week
        ).tap do |tr|
          tr.rank = idx + 1
          tr.score = score.round(2)
          tr.save!
        end
      end
    end
  end

  private

  # Returns { team_slug => { position => [{ grade_cols }] } }
  def self.fetch_team_grades(season_slug)
    rows = AthleteGrade
      .joins(athlete: :person)
      .joins("INNER JOIN contracts ON contracts.person_slug = people.slug AND contracts.contract_type IN ('active', 'draft_pick')")
      .joins("INNER JOIN teams ON teams.slug = contracts.team_slug AND teams.league = 'nfl'")
      .where(season_slug: season_slug)
      .select(
        "teams.slug AS t_slug",
        "athletes.position",
        "athlete_grades.overall_grade_pff",
        "athlete_grades.pass_grade_pff",
        "athlete_grades.run_grade_pff",
        "athlete_grades.pass_route_grade_pff",
        "athlete_grades.pass_block_grade_pff",
        "athlete_grades.run_block_grade_pff",
        "athlete_grades.pass_rush_grade_pff",
        "athlete_grades.coverage_grade_pff",
        "athlete_grades.rush_defense_grade_pff"
      )

    result = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
    rows.each do |r|
      result[r.t_slug][r.position] << {
        overall: r.overall_grade_pff.to_f,
        pass: r.pass_grade_pff.to_f,
        run: r.run_grade_pff.to_f,
        route: r.pass_route_grade_pff.to_f,
        pass_block: r.pass_block_grade_pff.to_f,
        run_block: r.run_block_grade_pff.to_f,
        pass_rush: r.pass_rush_grade_pff.to_f,
        coverage: r.coverage_grade_pff.to_f,
        rush_def: r.rush_defense_grade_pff.to_f
      }
    end
    result
  end

  # Returns { rank_type => { team_slug => score } }
  def self.compute_unit_scores(team_grades)
    nfl_teams = Team.nfl.pluck(:slug)
    scores = {}

    UNIT_TYPES.each { |t| scores[t] = {} }

    nfl_teams.each do |slug|
      grades = team_grades[slug] || {}

      scores["quarterback"][slug] = score_quarterback(grades)
      scores["rushing"][slug] = score_rushing(grades)
      scores["receiving"][slug] = score_receiving(grades)
      scores["pass_block"][slug] = score_pass_block(grades)
      scores["run_block"][slug] = score_run_block(grades)
      scores["pass_rush"][slug] = score_pass_rush(grades)
      scores["coverage"][slug] = score_coverage(grades)
      scores["run_defense"][slug] = score_run_defense(grades)
    end

    scores
  end

  def self.compute_aggregate_scores(unit_scores)
    nfl_teams = Team.nfl.pluck(:slug)
    agg = {}
    AGGREGATE_TYPES.each { |t| agg[t] = {} }

    nfl_teams.each do |slug|
      units = {}
      UNIT_TYPES.each { |t| units[t] = unit_scores[t][slug] || 0 }
      team_agg = team_aggregates(units)
      team_agg.each { |type, score| agg[type][slug] = score }
    end

    agg
  end

  # Compute aggregate scores from a hash of { unit_type => score } for a single team.
  # Used by both compute_aggregate_scores (batch) and simulate_impact (single team).
  def self.team_aggregates(units)
    qb   = units["quarterback"] || 0
    rec  = units["receiving"] || 0
    rush = units["rushing"] || 0
    pb   = units["pass_block"] || 0
    rb   = units["run_block"] || 0
    pr   = units["pass_rush"] || 0
    cov  = units["coverage"] || 0
    rd   = units["run_defense"] || 0

    pass_off  = (qb > 0 ? qb**1.6 : 0) + 4 * rec + 2 * pb
    run_off   = 5 * rush + 2 * rb
    off       = pass_off + run_off
    pass_def  = 4 * pr + 3 * cov
    def_score = pass_def + 3 * rd

    {
      "pass_offense"  => pass_off,
      "run_offense"   => run_off,
      "offense"       => off,
      "pass_defense"  => pass_def,
      "defense"       => def_score,
      "power"         => off + def_score
    }
  end

  # Simulate adding a player to a team and return before/after rank deltas.
  # Returns { rank_type => { current_score:, modified_score:, current_rank:, modified_rank:, delta_rank:, delta_score:, changed: } }
  def self.simulate_impact(person_slug:, target_team_slug:, season_slug:)
    team_grades = fetch_team_grades(season_slug)
    target_grades = team_grades[target_team_slug] || {}

    athlete = Athlete.joins(:person).find_by(people: { slug: person_slug })
    return nil unless athlete

    grade = AthleteGrade.find_by(athlete_slug: athlete.slug, season_slug: season_slug)
    return nil unless grade

    # Build modified grades — deep dup target team, add player
    modified_grades = {}
    target_grades.each { |pos, arr| modified_grades[pos] = arr.dup }
    modified_grades[athlete.position] ||= []
    modified_grades[athlete.position] << {
      overall: grade.overall_grade_pff.to_f,
      pass: grade.pass_grade_pff.to_f,
      run: grade.run_grade_pff.to_f,
      route: grade.pass_route_grade_pff.to_f,
      pass_block: grade.pass_block_grade_pff.to_f,
      run_block: grade.run_block_grade_pff.to_f,
      pass_rush: grade.pass_rush_grade_pff.to_f,
      coverage: grade.coverage_grade_pff.to_f,
      rush_def: grade.rush_defense_grade_pff.to_f
    }

    # Compute unit scores for current vs modified
    current_units = {}
    modified_units = {}
    UNIT_TYPES.each do |type|
      current_units[type] = send("score_#{type}", target_grades)
      modified_units[type] = send("score_#{type}", modified_grades)
    end

    current_agg = team_aggregates(current_units)
    modified_agg = team_aggregates(modified_units)

    # Get all stored scores for ranking comparison (exclude target team)
    all_rankings = TeamRanking.where(season_slug: season_slug, week: nil)
    scores_by_type = {}
    all_rankings.each do |r|
      next if r.team_slug == target_team_slug
      scores_by_type[r.rank_type] ||= []
      scores_by_type[r.rank_type] << r.score
    end

    # Build result with rank deltas
    result = {}
    RANK_TYPES.each do |type|
      cur_score = current_units[type] || current_agg[type] || 0
      mod_score = modified_units[type] || modified_agg[type] || 0
      other_scores = scores_by_type[type] || []

      cur_rank = other_scores.count { |s| s > cur_score } + 1
      mod_rank = other_scores.count { |s| s > mod_score } + 1

      result[type] = {
        current_score: cur_score.round(2),
        modified_score: mod_score.round(2),
        current_rank: cur_rank,
        modified_rank: mod_rank,
        delta_rank: cur_rank - mod_rank,
        delta_score: (mod_score - cur_score).round(2),
        changed: (cur_score - mod_score).abs > 0.01
      }
    end

    result
  end

  # --- Unit scoring methods ---

  def self.score_quarterback(grades)
    qbs = (grades["QB"] || []).sort_by { |g| -g[:pass] }
    qbs.first&.dig(:pass) || 0
  end

  def self.score_rushing(grades)
    rbs = (grades.values_at("RB", "FB", "HB").flatten.compact).sort_by { |g| -g[:run] }
    return 0 if rbs.empty?
    weights = [1.0, 0.3]
    rbs.first(2).each_with_index.sum { |g, i| g[:run] * (weights[i] || 0.3) }
  end

  def self.score_receiving(grades)
    receivers = (grades.values_at("WR", "TE").flatten.compact).sort_by { |g| -g[:route] }
    return 0 if receivers.empty?
    weights = [1.0, 0.7, 0.4]
    receivers.first(3).each_with_index.sum { |g, i| g[:route] * (weights[i] || 0.4) }
  end

  def self.score_pass_block(grades)
    ol = (grades.values_at("LT", "LG", "C", "RG", "RT", "OT", "OG").flatten.compact).sort_by { |g| -g[:pass_block] }
    return 0 if ol.empty?
    # Average top 5 OL pass block grades
    top = ol.first(5)
    top.sum { |g| g[:pass_block] } / top.size.to_f
  end

  def self.score_run_block(grades)
    ol = (grades.values_at("LT", "LG", "C", "RG", "RT", "OT", "OG").flatten.compact).sort_by { |g| -g[:run_block] }
    return 0 if ol.empty?
    top = ol.first(5)
    top.sum { |g| g[:run_block] } / top.size.to_f
  end

  def self.score_pass_rush(grades)
    rushers = (grades.values_at("EDGE", "DE", "DT", "NT").flatten.compact).sort_by { |g| -g[:pass_rush] }
    return 0 if rushers.empty?
    weights = [1.0, 0.7, 0.4, 0.4, 0.4]
    rushers.first(5).each_with_index.sum { |g, i| g[:pass_rush] * (weights[i] || 0.4) }
  end

  def self.score_coverage(grades)
    cbs = (grades.values_at("CB").flatten.compact).sort_by { |g| -g[:coverage] }
    safties = (grades.values_at("S", "FS", "SS").flatten.compact).sort_by { |g| -g[:coverage] }

    cb_weights = [1.0, 0.9, 0.7]
    s_weights = [0.6, 0.6]

    cb_score = cbs.first(3).each_with_index.sum { |g, i| g[:coverage] * (cb_weights[i] || 0.7) }
    s_score = safties.first(2).each_with_index.sum { |g, i| g[:coverage] * (s_weights[i] || 0.6) }

    cb_score + s_score
  end

  def self.score_run_defense(grades)
    defenders = (grades.values_at("LB", "ILB", "OLB", "MLB", "DT", "NT", "DE", "EDGE", "S", "FS", "SS", "CB").flatten.compact)
      .sort_by { |g| -g[:rush_def] }
    return 0 if defenders.empty?
    # Weighted average of top 7 run defenders
    weights = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4]
    defenders.first(7).each_with_index.sum { |g, i| g[:rush_def] * (weights[i] || 0.4) }
  end
end
