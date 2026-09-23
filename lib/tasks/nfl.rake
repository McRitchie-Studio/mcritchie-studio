namespace :nfl do
  HEADSHOT_WIDTHS = [100, 400].freeze

  desc "For Athletes with espn_id, cache headshot variants in S3 + ImageCache. Idempotent."
  task upload_headshots: :environment do
    candidates = Athlete.where.not(espn_id: nil).includes(person: { contracts: :team }, image_caches: {})
    puts "candidates: #{candidates.count} athletes; widths: #{HEADSHOT_WIDTHS.inspect}"

    cached = 0
    skipped_complete = 0
    skipped_no_team = 0
    failed = 0

    candidates.find_each do |athlete|
      person = athlete.person
      contract = person.contracts.find { |c| c.team&.league == "nfl" }
      team = contract&.team

      unless team
        skipped_no_team += 1
        next
      end

      have = athlete.image_caches.select { |c| c.purpose == "headshot" }.map(&:variant)
      if (HEADSHOT_WIDTHS.map(&:to_s) - have).empty?
        skipped_complete += 1
        next
      end

      key_prefix = "headshots/nfl/#{team.slug}/#{person.slug}"

      begin
        Studio::ImageCache.cache!(
          owner: athlete,
          purpose: "headshot",
          source_url: athlete.espn_headshot_url,
          key_prefix: key_prefix,
          widths: HEADSHOT_WIDTHS,
          content_type: "image/png"
        )
        cached += 1
        puts "  [+] #{person.slug.ljust(28)} -> #{key_prefix}/{original,#{HEADSHOT_WIDTHS.join(',')}}.png" if cached <= 5 || (cached % 50).zero?
      rescue => e
        failed += 1
        puts "  [!] #{person.slug}: #{e.class}: #{e.message}"
      end
    end

    puts ""
    puts "cached:                 #{cached}"
    puts "skipped (already done): #{skipped_complete}"
    puts "skipped (no NFL team):  #{skipped_no_team}"
    puts "failed:                 #{failed}"

    # THE PER-ATHLETE RESCUE ABOVE IS RIGHT; ENDING ON `puts` WAS NOT. One dead
    # ESPN headshot URL must not cost the other thousand their upload, so each
    # failure is counted and the loop continues — and then the task returned
    # normally, so the process exited 0 no matter how many failed. MEASURED with
    # three manufactured candidates and Studio::ImageCache.cache! raising the
    # real Aws::Errors::MissingCredentialsError: `failed: 3`, `cached: 0`, exit
    # 0. That is the credential failure the phase-6c log line has been telling
    # operators to go and check, reported as a success.
    #
    # GRADED ON THE MAJORITY, not on `failed.positive?`. A single 404 is a
    # normal afternoon; reddening a whole rebuild for it trains an operator to
    # stop reading the line. More failures than successes cannot be one bad URL
    # — it is the uploader not working, which is what a credential failure looks
    # like from here: every attempt fails, so `cached` is 0 and `failed` is
    # everything.
    if failed > cached
      warn "nfl:upload_headshots: #{failed} of #{failed + cached} attempted uploads failed"
      abort "nfl:upload_headshots failed #{failed} of #{failed + cached} attempted uploads " \
            "(cached #{cached}) — read the [!] lines above. A total failure is usually AWS " \
            "credentials: check AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION in .env."
    end
  end

  ESPN_TEAMS_INDEX_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams"
  ESPN_TEAM_COACHES_URL = ->(team_id) { "https://sports.core.api.espn.com/v2/sports/football/leagues/nfl/teams/#{team_id}/coaches" }
  COACH_HEADSHOT_WIDTHS = [100, 400].freeze

  desc "Pull NFL head coaches from ESPN; populate Coach espn_id + espn_headshot_url. No S3 traffic."
  task link_coach_headshots: :environment do
    require "open-uri"
    require "json"

    teams_by_abbrev = Team.where(league: "nfl").index_by(&:short_name).merge(
      "LA"  => Team.find_by(slug: "los-angeles-rams"),
      "WSH" => Team.find_by(slug: "washington-commanders")
    )

    puts "Fetching ESPN team index..."
    teams_resp = JSON.parse(URI.open(ESPN_TEAMS_INDEX_URL).read)
    espn_teams = teams_resp.dig("sports", 0, "leagues", 0, "teams").map { |t| t["team"] }
    puts "  #{espn_teams.size} ESPN teams"

    matched = 0
    skipped_unchanged = 0
    skipped_no_team = 0
    skipped_no_coach = 0
    failed = 0

    espn_teams.each do |et|
      espn_team_id = et["id"]
      espn_abbrev  = et["abbreviation"]
      our_team     = teams_by_abbrev[espn_abbrev]

      unless our_team
        skipped_no_team += 1
        puts "  [?] No team match for ESPN abbrev=#{espn_abbrev}"
        next
      end

      coaches_resp = JSON.parse(URI.open(ESPN_TEAM_COACHES_URL.call(espn_team_id)).read)
      ref = coaches_resp.dig("items", 0, "$ref")
      unless ref
        skipped_no_coach += 1
        next
      end

      coach_resp = JSON.parse(URI.open(ref).read)
      espn_id = coach_resp["id"].to_s
      headshot_url = coach_resp.dig("headshot", "href")
      first = coach_resp["firstName"]
      last  = coach_resp["lastName"]
      espn_person_slug = "#{first} #{last}".parameterize

      coach = Coach.find_by(team_slug: our_team.slug, role: "head_coach", person_slug: espn_person_slug) ||
              Coach.find_by(team_slug: our_team.slug, role: "head_coach")

      unless coach
        skipped_no_coach += 1
        puts "  [?] #{our_team.slug.ljust(25)} no Coach record (ESPN HC: #{first} #{last})"
        next
      end

      if coach.person_slug != espn_person_slug
        puts "  [~] #{our_team.slug.ljust(25)} ESPN says HC=#{first} #{last}, we have #{coach.person.full_name}"
      end

      if coach.espn_id == espn_id && coach.espn_headshot_url == headshot_url
        skipped_unchanged += 1
      else
        coach.update!(espn_id: espn_id, espn_headshot_url: headshot_url)
        matched += 1
        puts "  [+] #{our_team.slug.ljust(25)} #{first} #{last} (espn_id=#{espn_id})"
      end
    rescue => e
      failed += 1
      puts "  [!] error for #{espn_abbrev}: #{e.class}: #{e.message}"
    end

    puts ""
    puts "matched/updated:      #{matched}"
    puts "skipped (unchanged):  #{skipped_unchanged}"
    puts "skipped (no team):    #{skipped_no_team}"
    puts "skipped (no Coach):   #{skipped_no_coach}"
    puts "failed:               #{failed}"
  end

  # Maps our team_slug to the team's official NFL.com subdomain.
  # Used to scrape the team's coaches roster page when ESPN's coach API
  # doesn't provide a headshot.href (which is the case for ~21/32 HCs and
  # for every coordinator).
  COACH_ROLE_LABELS = {
    "head coach"                 => "head_coach",
    "offensive coordinator"      => "offensive_coordinator",
    "defensive coordinator"      => "defensive_coordinator",
    "special teams coordinator"  => "special_teams_coordinator"
  }.freeze

  desc "Scrape each team's NFL.com coaches roster page; populate Coach espn_headshot_url where missing. Covers HC + 3 coordinators per team."
  task link_coach_headshots_from_team_sites: :environment do
    require "open-uri"
    require "nokogiri"

    matched = 0
    skipped_unchanged = 0
    skipped_no_coach = 0
    skipped_no_image = 0
    failed_team = 0

    Team.where(league: "nfl").where.not(coaches_url: nil).find_each do |team|
      team_slug = team.slug
      # Try Team.coaches_url first; if it 404s, try the alternate /team/coaches-roster/
      # path (Buccaneers and Titans use coaches-roster instead of coaches).
      candidate_urls = [team.coaches_url]
      if team.coaches_url.include?("/team/coaches/")
        candidate_urls << team.coaches_url.sub("/team/coaches/", "/team/coaches-roster/")
      elsif team.coaches_url.include?("/team/coaches-roster/")
        candidate_urls << team.coaches_url.sub("/team/coaches-roster/", "/team/coaches/")
      end

      html = nil
      candidate_urls.each do |url|
        html = URI.open(url, read_timeout: 15, "User-Agent" => "Mozilla/5.0").read
        break
      rescue OpenURI::HTTPError, SocketError, Net::OpenTimeout, Net::ReadTimeout
        next
      end

      unless html
        failed_team += 1
        puts "  [!] #{team_slug.ljust(25)} no coach page found (tried #{candidate_urls.size} URLs)"
        next
      end

      doc = Nokogiri::HTML(html)

      # Each coach card is the smallest ancestor of a coach link that contains
      # both a role label and an <img>.
      doc.css("a[href*='/team/coaches/'], a[href*='/team/coaches-roster/']").each do |link|
        href = link["href"].to_s
        next if href.match?(/coaches(?:-roster)?\/(index|all-time)?$/)

        card = link.ancestors.find { |n| n.css("img").any? }
        next unless card

        # Strip "Assistant Head Coach" / "Associate Head Coach" so they don't
        # match the bare "head coach" label.
        text = card.text.gsub(/(assistant|associate|interim|senior)\s+(head\s+coach|offensive\s+coordinator|defensive\s+coordinator|special\s+teams\s+coordinator)/i, "")
        role_label = COACH_ROLE_LABELS.keys.find { |label| text.match?(/#{Regexp.escape(label)}/i) }
        next unless role_label
        role = COACH_ROLE_LABELS[role_label]

        img = card.css("img").first
        img_url = img["src"].to_s.start_with?("http") ? img["src"] : img["data-src"].to_s
        if img_url.empty? || img_url.start_with?("data:")
          skipped_no_image += 1
          next
        end

        # Force a known-good high-res Cloudinary transform. NFL.com's default
        # mobile variant is ~12KB and gets blurry on hover. We strip whatever
        # transform stack is present and pin "t_headshot_desktop_3x/f_auto" —
        # works on both /image/upload/ (public) and /image/private/
        # (auth-required without a transform) paths, and yields a clean
        # ~80KB color portrait. Crucially do NOT include "t_lazy" — that's
        # Cloudinary's grayscale placeholder transform.
        img_url = img_url.sub(
          %r{(/image/(?:upload|private)/)(?:[a-z]+_[^/]+/)*},
          '\1t_headshot_desktop_3x/f_auto/'
        )

        person_slug = href.split("/").last.parameterize
        coach = Coach.find_by(team_slug: team_slug, role: role, person_slug: person_slug)

        unless coach
          skipped_no_coach += 1
          # Surface mismatch so seed can be corrected later
          our_coach = Coach.find_by(team_slug: team_slug, role: role)
          puts "  [~] #{team_slug.ljust(25)} #{role.ljust(28)} NFL.com=#{person_slug}, our DB has #{our_coach&.person_slug.inspect}"
          next
        end

        if coach.espn_headshot_url == img_url
          skipped_unchanged += 1
        else
          coach.update!(espn_headshot_url: img_url)
          matched += 1
          puts "  [+] #{team_slug.ljust(25)} #{role.ljust(28)} #{coach.person.full_name}" if matched <= 8 || (matched % 25).zero?
        end
      end
    end

    puts ""
    puts "matched/updated:      #{matched}"
    puts "skipped (unchanged):  #{skipped_unchanged}"
    puts "skipped (no Coach):   #{skipped_no_coach}"
    puts "skipped (no image):   #{skipped_no_image}"
    puts "failed (team page):   #{failed_team}"
  end

  desc "For Coaches with espn_headshot_url (from ESPN or NFL.com), cache variants. Idempotent."
  task upload_coach_headshots: :environment do
    with_url    = Coach.where.not(espn_headshot_url: nil).includes(:image_caches)
    without_url = Coach.where(sport: "football", espn_headshot_url: nil).count
    puts "candidates: #{with_url.count} coaches with headshot URL; #{without_url} football coaches with no image source; widths: #{COACH_HEADSHOT_WIDTHS.inspect}"

    cached = 0
    skipped_complete = 0
    failed = 0
    refreshed = 0

    with_url.find_each do |coach|
      headshots = coach.image_caches.select { |c| c.purpose == "headshot" }

      # Stale cache: coach.espn_headshot_url has changed since the variants
      # were uploaded. Sources differ across rows, OR all rows point to a
      # URL that no longer matches the current one. Wipe and re-upload so
      # 100w and 400w aren't from different photos (e.g., McVay's old ESPN
      # B&W still cached at 100w while 400w came from a later NFL.com URL).
      cached_sources = headshots.map(&:source_url).uniq
      if headshots.any? && (cached_sources.size > 1 || cached_sources.first != coach.espn_headshot_url)
        ImageCache.where(owner: coach, purpose: "headshot").destroy_all
        # Note: the S3 objects stay (orphaned). Studio::ImageCache.cache! will
        # overwrite them on re-upload since the s3_key is deterministic.
        headshots = []
        refreshed += 1
      end

      have = headshots.map(&:variant)
      if (["original"] + COACH_HEADSHOT_WIDTHS.map(&:to_s) - have).empty?
        skipped_complete += 1
        next
      end

      # Use coach.slug (person-team-role) for the S3 path so coaches with the
      # same person_slug across teams/roles don't collide.
      key_prefix = "headshots/nfl/coaches/#{coach.slug}"
      content_type = coach.espn_headshot_url.to_s.end_with?(".png") ? "image/png" : "image/jpeg"

      begin
        Studio::ImageCache.cache!(
          owner: coach,
          purpose: "headshot",
          source_url: coach.espn_headshot_url,
          key_prefix: key_prefix,
          widths: COACH_HEADSHOT_WIDTHS,
          content_type: content_type
        )
        cached += 1
        puts "  [+] #{coach.person_slug.ljust(28)} (#{coach.team_slug})"
      rescue => e
        failed += 1
        puts "  [!] #{coach.person_slug}: #{e.class}: #{e.message}"
      end
    end

    puts ""
    puts "cached:                 #{cached}"
    puts "refreshed (stale cache):#{refreshed}"
    puts "skipped (already done): #{skipped_complete}"
    puts "skipped (no ESPN img):  #{without_url}"
    puts "failed:                 #{failed}"

    # Per-coach gap report — surfaces which roles on which teams ended this
    # rebuild without a cached headshot, grouped by team. Makes the next
    # iteration's targets visible at the bottom of the rebuild log.
    puts ""
    puts "─── Coaches still missing headshots (post-upload) ───"
    missing = Coach.where(sport: "football").includes(:person, :image_caches).reject do |c|
      c.image_caches.any? { |ic| ic.purpose == "headshot" }
    end
    if missing.empty?
      puts "  (none — full coverage)"
    else
      missing.group_by(&:team_slug).sort.each do |team_slug, coaches|
        puts "  #{team_slug}"
        coaches.each do |c|
          reason = c.espn_headshot_url.present? ? "url present, upload failed" : "no espn_headshot_url"
          puts "    #{c.role.ljust(28)} #{c.person.full_name.ljust(22)} [#{reason}]"
        end
      end
      puts ""
      puts "  Total missing: #{missing.size} of #{Coach.where(sport: "football").count}"
    end
  end

  desc "Seed Person + Athlete from nflverse players.csv (cross-ref IDs + ESPN headshots → S3). VERBOSE=1 SKIP_HEADSHOTS=1 MIN_SEASON=2024 STATUS=ACT (default: any status)"
  task players_seed: :environment do
    Nflverse::SeedPlayers.new(
      verbose:          ENV["VERBOSE"] == "1",
      upload_headshots: ENV["SKIP_HEADSHOTS"] != "1",
      min_season:       ENV["MIN_SEASON"] || Nflverse::SeedPlayers::DEFAULT_MIN_SEASON,
      status_filter:    ENV["STATUS"]
    ).call
  end

  desc "Sync NFL salaries from Spotrac JSON. Annotates active Contracts (matched by otc_id, falling back to name); creates Person/Athlete/Contract for entries we don't have yet."
  task salaries_sync: :environment do
    Spotrac::SyncContracts.new(verbose: ENV["VERBOSE"] == "1").call
  end

  desc "Find suffix-stripped duplicate Persons (e.g. 'will-anderson' alongside 'will-anderson-jr') and merge into the canonical record. Default DRY_RUN=1; set DRY_RUN=0 to commit."
  task merge_duplicate_athletes: :environment do
    Athletes::MergeDuplicates.new(
      dry_run: ENV.fetch("DRY_RUN", "1") != "0",
      verbose: ENV["VERBOSE"] == "1"
    ).call
  end

  desc "Compute proprietary position-bucketed pass/run rank + 0-10 grade from PFF inputs. SEASON=2025-nfl (default)."
  task assign_grades: :environment do
    season_slug = ENV["SEASON"] || "2025-nfl"
    Athletes::ComputeProprietaryGrades.new(season_slug: season_slug).call
  end

  desc "Pull NFL season schedule from nflverse for YEAR (default 2026). Creates Season + Slates (PRE/REG/playoffs) + Games. Idempotent."
  task schedule_seed: :environment do
    year = (ENV["YEAR"] || 2026).to_i
    stats = Nflverse::SeedSchedule.new(year: year).call
    puts ""
    puts "Done. Season: #{stats[:season]}"
    puts "  Slates:  #{stats[:slates]}"
    puts "  Games:   #{stats[:games]} created/found"
    puts "  Skipped: #{stats[:skipped]}"
    stats[:slate_counts].each { |type, count| puts "    #{type.ljust(15)} #{count} games" }
  end

  desc "Compute TeamRanking rows for SEASON, scoring against GRADES_FROM (defaults to SEASON). Preseason use: SEASON=2026-nfl GRADES_FROM=2025-nfl."
  task rankings_compute: :environment do
    season_slug = ENV.fetch("SEASON", "2026-nfl")
    grades_slug = ENV["GRADES_FROM"]
    Season.find_by!(slug: season_slug)
    Season.find_by!(slug: grades_slug) if grades_slug

    before = TeamRanking.where(season_slug: season_slug).count
    TeamRanking.compute_all!(season_slug: season_slug, grades_season_slug: grades_slug)
    after = TeamRanking.where(season_slug: season_slug).count
    puts "TeamRankings for #{season_slug}: #{before} → #{after}#{grades_slug ? " (scored against #{grades_slug} grades)" : ""}"

    # THE ROW COUNT IS NOT THE VERDICT HERE, and the rebuild lane logs the row
    # count. MEASURED on a desk with AthleteGrade emptied inside a rolled-back
    # transaction: compute_all! wrote 448 rows and exited 0, the identical count
    # the healthy run writes. The two differ only in the SCORES — 448 distinct
    # values spanning 49.6..5604.37 with grades, one distinct value of 0.0
    # without — so a lane grading on the count cannot see the difference, and
    # "448 rank rows populated" reads the same through a missing grade season.
    #
    # An all-zero ranking is not a ranking: every team ties at 0 and the 1..32
    # order is whatever the sort happened to do. Refuse it and name the season
    # that came back empty, since GRADES_FROM is the knob that fixes it.
    scores = TeamRanking.where(season_slug: season_slug).pluck(:score).compact
    if scores.any? && scores.all?(&:zero?)
      abort "nfl:rankings_compute scored every team 0.0 across #{scores.size} rows — " \
            "#{grades_slug || season_slug} has no AthleteGrade rows to score against. " \
            "The ranks written are ties in sort order, not a ranking. Set GRADES_FROM to " \
            "a season that has grades, or import them first."
    end
  end

  desc "Snapshot current DepthChart → per-slate Roster+RosterSpot. SEASON=2026-nfl WEEK=N (default: current week)."
  task rosters_snapshot: :environment do
    season_slug = ENV.fetch("SEASON", "2026-nfl")
    season = Season.find_by(slug: season_slug)
    abort "Season not found: #{season_slug}" unless season

    slate = if ENV["WEEK"]
      season.slates.where(slate_type: "regular_season").find_by(sequence: ENV["WEEK"].to_i)
    else
      today = Date.current
      season.slates.where(slate_type: "regular_season")
                   .where("ends_at >= ?", today)
                   .order(:sequence)
                   .first ||
        season.slates.where(slate_type: "regular_season").order(:sequence).first
    end
    abort "No regular_season slate found for #{season_slug}#{ENV["WEEK"] ? " WEEK=#{ENV["WEEK"]}" : ""}" unless slate

    puts "Snapshotting DepthChart → Roster for #{slate.slug} (Week #{slate.sequence})..."
    stats = Rosters::SnapshotFromDepthChart.new(slate_slug: slate.slug, verbose: ENV["VERBOSE"] == "1").call
    puts "Done: #{stats[:teams_snapshotted]} teams, #{stats[:teams_without_chart]} skipped, #{stats[:spots_created]} spots created, #{stats[:spots_updated]} updated"
  end
end
