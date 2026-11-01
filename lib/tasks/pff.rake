namespace :pff do
  desc "Import PFF starting lineup CSV. FILE=path/to/csv SEASON=2025-nfl"
  task import_starters: :environment do
    file   = ENV.fetch("FILE", Rails.root.join("lib/pff/starting-lineups-2025.csv").to_s)
    season = ENV.fetch("SEASON", "2025-nfl")

    unless File.exist?(file)
      abort "File not found: #{file}\nCopy PFF CSV to the gitignored lib/pff/ and retry, or pass FILE=path/to/csv"
    end

    puts "Importing PFF starters from #{file} for season #{season}..."
    Pff::ImportStarters.new(csv_path: file, season_slug: season).call
  end

  desc "Import a single PFF CSV. FILE=path/to/csv SEASON=2025-nfl [TYPE=passing_summary]"
  task import: :environment do
    file   = ENV.fetch("FILE") { abort "FILE= is required" }
    season = ENV.fetch("SEASON", "2025-nfl")
    type   = ENV["TYPE"]

    unless File.exist?(file)
      abort "File not found: #{file}"
    end

    puts "Importing PFF CSV: #{File.basename(file)} (season=#{season}#{type ? ", type=#{type}" : ""})..."
    Pff::ImportCsv.new(csv_path: file, season_slug: season, stat_type: type).call
  end

  desc "Import all PFF CSVs from a directory. DIR=path/to/dir SEASON=2025-nfl"
  task import_dir: :environment do
    dir    = ENV.fetch("DIR") { abort "DIR= is required" }
    season = ENV.fetch("SEASON", "2025-nfl")

    unless Dir.exist?(dir)
      abort "Directory not found: #{dir}"
    end

    # PFF stat file patterns (only files that match known PFF naming)
    pff_patterns = %w[
      passing_summary passing_pressure passing_depth passing_concept passing_allowed_pressure
      rushing_summary receiving_summary receiving_depth receiving_concept receiving_scheme
      offense_blocking offense_pass_blocking offense_run_blockng
      defense_summary defense_coverage_summary defense_coverage_scheme
      run_defense_summary pass_rush_summary pass_rush_productivity
      field_goal_summary punting_summary kickoff_summary return_summary
      special_teams_summary time_in_pocket slot_coverage
      line_pass_blocking_efficiency
    ]

    csvs = Dir.glob(File.join(dir, "*.csv")).select do |f|
      basename = File.basename(f, ".csv").gsub(/\s*\(\d+\)\s*$/, "").strip.downcase.gsub(/\s+/, "_")
      pff_patterns.include?(basename)
    end

    if csvs.empty?
      abort "No PFF CSV files found in #{dir}"
    end

    # Deduplicate: keep highest-numbered copy per stat_type
    by_type = {}
    csvs.each do |f|
      basename = File.basename(f, ".csv")
      type_key = basename.gsub(/\s*\(\d+\)\s*$/, "").strip.downcase.gsub(/\s+/, "_")
      # Extract copy number (default 0 for no parens)
      copy_num = basename.match(/\((\d+)\)/)&.captures&.first&.to_i || 0
      if !by_type[type_key] || copy_num > by_type[type_key][:num]
        by_type[type_key] = { path: f, num: copy_num }
      end
    end

    puts "Found #{by_type.size} unique PFF stat types in #{dir}"
    by_type.each do |type, info|
      puts "\n--- #{type} (#{File.basename(info[:path])}) ---"
      Pff::ImportCsv.new(csv_path: info[:path], season_slug: season, stat_type: type).call
    end

    puts "\nAll done. #{by_type.size} stat types imported."
  end

  desc "Build rosters from PFF summary stats. SEASON=2025-nfl [TEAM=buffalo-bills]"
  task build_rosters: :environment do
    season_slug = ENV.fetch("SEASON", "2025-nfl")
    team_filter = ENV["TEAM"]

    season = Season.find_by(slug: season_slug)
    abort "Season not found: #{season_slug}" unless season

    offseason = season.slates.find_by(sequence: 0)
    abort "Offseason slate not found for #{season_slug}" unless offseason
    unless PffStat.where(season_slug: season_slug).exists?
      abort "pff:build_rosters: #{season_slug} has no imported PFF stats, so there is nothing to build from. " \
            "The repo ships no PFF data; import a licensed export first (bin/rails pff:import_dir DIR=... SEASON=#{season_slug})."
    end

    # Position priority: which stat_type is most authoritative per position group
    # For each position, pick the best summary stat_type to source from
    offense_types = %w[passing_summary rushing_summary receiving_summary offense_blocking]
    defense_types = %w[defense_summary]

    teams = team_filter ? Team.nfl.where(slug: team_filter) : Team.nfl
    total_created = 0

    teams.order(:name).each do |team|
      roster = Roster.find_or_create_by!(team_slug: team.slug, slate_slug: offseason.slug)
      existing_count = roster.roster_spots.count

      # Collect unique athletes for this team from PFF stats
      # Use summary stat types to get one entry per player
      players = {}
      (offense_types + defense_types).each do |st|
        PffStat.where(team_slug: team.slug, season_slug: season_slug, stat_type: st).each do |pff|
          next if players[pff.athlete_slug] # already seen
          position = pff.data["position"]
          next if position.blank?
          players[pff.athlete_slug] = {
            person_slug: pff.athlete.person_slug,
            position: PositionConcern.normalize_position(position, source: :pff),
            stat_type: st
          }
        end
      end

      if players.empty?
        puts "  #{team.short_name}: no PFF data, skipping"
        next
      end

      depth_tracker = Hash.new(0)
      # Count existing roster spots per position so we don't collide
      roster.roster_spots.each do |rs|
        key = "#{rs.position}"
        depth_tracker[key] = [depth_tracker[key], rs.depth].max
      end

      created = 0
      players.each do |athlete_slug, info|
        side = PositionConcern.side_for(info[:position])

        # Skip if this person already on the roster
        next if roster.roster_spots.exists?(person_slug: info[:person_slug])

        depth_tracker[info[:position]] += 1
        depth = depth_tracker[info[:position]]

        RosterSpot.create!(
          roster: roster,
          person_slug: info[:person_slug],
          position: info[:position],
          side: side,
          depth: depth
        )
        created += 1
      end

      total_created += created
      total = roster.roster_spots.count
      puts "  #{team.short_name}: +#{created} roster spots (#{total} total)"
    end

    puts "\nDone. Created #{total_created} roster spots across #{teams.count} teams."
  end
end
