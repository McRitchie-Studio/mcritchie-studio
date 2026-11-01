# Athlete grades: the fallback layer for athletes no PFF file covered.
#
# The repo ships no PFF data (see 29_pff_grades.rb), so on a clean checkout seed 29
# imported nothing and THIS FILE WRITES EVERY GRADE: a flat 50.0 placeholder for
# each active NFL athlete, sub-grades left empty, and tier-based grades for drafted
# prospects. A flat 50.0 is not a measurement. Ranking pages and the player-impact
# simulator get a value to sort and compute against, and that is all; depth chart
# ordering itself comes from ESPN's scraper (espn:scrape_depth_charts), not from
# grades. With a licensed export imported first, athletes it covers keep their rows.
#
# Prospects keep the tier-based grading with grade_ranges JSONB since draft
# slot is the only signal we have for them pre-NFL.

PROSPECT_TIERS = [
  { picks: 1..10,   overall: [68, 92], spread: 5 },
  { picks: 11..20,  overall: [60, 85], spread: 6 },
  { picks: 21..32,  overall: [55, 80], spread: 6 },
  { picks: 33..50,  overall: [50, 74], spread: 7 },
  { picks: 51..70,  overall: [46, 68], spread: 7 },
  { picks: 71..103, overall: [42, 64], spread: 8 },
]

POSITION_OFFSETS = {
  "QB"   => { pass_grade_pff: 2,         run_grade_pff: -10 },
  "WR"   => { pass_route_grade_pff: 2,   run_grade_pff: -10 },
  "TE"   => { pass_route_grade_pff: 2,   run_grade_pff: -6 },
  "RB"   => { run_grade_pff: 2,          pass_route_grade_pff: -8 },
  "FB"   => { run_grade_pff: 2,          pass_route_grade_pff: -8 },
  "HB"   => { run_grade_pff: 2,          pass_route_grade_pff: -8 },
  "OT"   => { pass_block_grade_pff: 2,   run_block_grade_pff: -2 },
  "OG"   => { pass_block_grade_pff: 2,   run_block_grade_pff: -2 },
  "C"    => { pass_block_grade_pff: 2,   run_block_grade_pff: -2 },
  "EDGE" => { pass_rush_grade_pff: 2,    rush_defense_grade_pff: -5,  coverage_grade_pff: -12 },
  "DE"   => { pass_rush_grade_pff: 2,    rush_defense_grade_pff: -5,  coverage_grade_pff: -12 },
  "DT"   => { rush_defense_grade_pff: 2, pass_rush_grade_pff: -3,     coverage_grade_pff: -15 },
  "DL"   => { rush_defense_grade_pff: 2, pass_rush_grade_pff: -3,     coverage_grade_pff: -15 },
  "NT"   => { rush_defense_grade_pff: 2, pass_rush_grade_pff: -3,     coverage_grade_pff: -15 },
  "LB"   => { rush_defense_grade_pff: 0, coverage_grade_pff: -2,      pass_rush_grade_pff: -6 },
  "CB"   => { coverage_grade_pff: 2,     rush_defense_grade_pff: -10 },
  "S"    => { coverage_grade_pff: 2,     rush_defense_grade_pff: -4,  pass_rush_grade_pff: -12 },
  "CB/WR" => { coverage_grade_pff: 2, pass_route_grade_pff: 0, rush_defense_grade_pff: -8 }
}.freeze

OFFENSE_POSITIONS = %w[QB WR TE RB FB HB OT OG C LT LG RT RG CB/WR].freeze

def prospect_tier_for(pick)
  PROSPECT_TIERS.find { |t| t[:picks].include?(pick) }
end

def prospect_overall(pick, slug)
  tier = prospect_tier_for(pick)
  return 65.0 unless tier

  low, high = tier[:overall]
  range = high - low
  seed = Digest::MD5.hexdigest("#{slug}-overall").to_i(16) % 10000
  (low + (seed / 10000.0) * range).round(1)
end

def prospect_grade_ranges(position, overall, _slug, pick)
  tier = prospect_tier_for(pick) || PROSPECT_TIERS.last
  spread = tier[:spread]
  offsets = POSITION_OFFSETS[position] || {}
  ranges = {}

  offsets.each do |grade_key, offset|
    midpoint = (overall + offset).clamp(40.0, 99.9)
    low  = [midpoint - spread, 40.0].max.round(1)
    high = [midpoint + spread, 99.9].min.round(1)
    ranges[grade_key.to_s] = [low, high]
  end

  ranges["overall_grade_pff"] = [[overall - spread, 40.0].max.round(1), [overall + spread, 99.9].min.round(1)]
  ranges
end

nfl_season = Season.find_by(year: 2025, league: "nfl")

if nfl_season
  # Active NFL athletes with no imported grade: flat baseline. find_or_create skips
  # any row an imported PFF file already wrote.
  Athlete.joins(:person).joins("INNER JOIN contracts ON contracts.person_slug = people.slug AND contracts.contract_type = 'active'")
         .where(sport: "football")
         .distinct.find_each do |athlete|
    AthleteGrade.find_or_create_by!(athlete_slug: athlete.slug, season_slug: nfl_season.slug) do |g|
      g.overall_grade_pff = 50.0
      g.games_played  = 17
    end
  end

  # NCAA prospects — tier-based grades with ranges JSONB
  Athlete.where(sport: "football").where.not(draft_pick: nil).find_each do |athlete|
    pick    = athlete.draft_pick
    overall = prospect_overall(pick, athlete.slug)
    pos     = athlete.position
    offsets = POSITION_OFFSETS[pos] || {}

    computed = offsets.transform_values { |o| (overall + o).clamp(40.0, 99.9).round(1) }
    if OFFENSE_POSITIONS.include?(pos)
      computed[:offense_grade_pff] = overall
      computed[:defense_grade_pff] = overall if pos == "CB/WR"
    else
      computed[:defense_grade_pff] = overall
    end

    AthleteGrade.find_or_create_by!(athlete_slug: athlete.slug, season_slug: nfl_season.slug) do |g|
      g.overall_grade_pff = overall
      g.games_played  = rand(10..14)
      g.snaps         = rand(400..900)
      g.grade_ranges  = prospect_grade_ranges(pos, overall, athlete.slug, pick)
      computed.each { |k, v| g.public_send(:"#{k}=", v) }
    end
  end
end

puts "AthleteGrades: #{AthleteGrade.count}"
