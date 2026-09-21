require "csv"
require "open-uri"

# Seeds Person + Athlete records from nflverse's master players.csv. This is
# the identity backbone — one row per NFL player ever, with cross-references
# to every external system (ESPN, PFF, Spotrac/OTC, PFR, Sleeper, NFL).
# Subsequent imports (PFF grades, Spotrac salaries, ESPN depth charts) match
# by these IDs instead of fragile name matching.
#
# Source: https://github.com/nflverse/nflverse-data/releases/download/players/players.csv
#
# Defaults filter to status=ACT AND last_season >= 2024 to keep the dataset
# scoped to current/recent rosters (the master CSV has 24k rows total). Pass
# MIN_SEASON=0 to ingest everything, or status="" to skip the status filter.
#
# Headshot caching is enabled by default and REQUIRES AWS credentials —
# the constructor raises if AWS_ACCESS_KEY_ID is missing. Each Athlete with
# an espn_id gets its 100w/400w variants cached in S3 via Studio::ImageCache.
# Idempotent — variants already cached are skipped. To opt out (CI, tests),
# pass upload_headshots: false or set SKIP_HEADSHOTS=1 on the rake task.
#
# Usage:
#   Nflverse::SeedPlayers.new.call
#   Nflverse::SeedPlayers.new(min_season: 2025, upload_headshots: false).call
class Nflverse::SeedPlayers
  PLAYERS_URL = "https://github.com/nflverse/nflverse-data/releases/download/players/players.csv"
  DEFAULT_MIN_SEASON = 2024

  # nflverse uses standard NFL abbreviations with a few quirks: "LA" for the
  # Rams, "LAC" for the Chargers, "LV" for the Raiders, "WAS" for the
  # Commanders. Maps to our canonical team slugs.
  TEAM_ABBR_TO_SLUG = {
    "ARI" => "arizona-cardinals",   "ATL" => "atlanta-falcons",
    "BAL" => "baltimore-ravens",    "BUF" => "buffalo-bills",
    "CAR" => "carolina-panthers",   "CHI" => "chicago-bears",
    "CIN" => "cincinnati-bengals",  "CLE" => "cleveland-browns",
    "DAL" => "dallas-cowboys",      "DEN" => "denver-broncos",
    "DET" => "detroit-lions",       "GB"  => "green-bay-packers",
    "HOU" => "houston-texans",      "IND" => "indianapolis-colts",
    "JAX" => "jacksonville-jaguars", "KC"  => "kansas-city-chiefs",
    "LA"  => "los-angeles-rams",    "LAC" => "los-angeles-chargers",
    "LV"  => "las-vegas-raiders",   "MIA" => "miami-dolphins",
    "MIN" => "minnesota-vikings",   "NE"  => "new-england-patriots",
    "NO"  => "new-orleans-saints",  "NYG" => "new-york-giants",
    "NYJ" => "new-york-jets",       "PHI" => "philadelphia-eagles",
    "PIT" => "pittsburgh-steelers", "SF"  => "san-francisco-49ers",
    "SEA" => "seattle-seahawks",    "TB"  => "tampa-bay-buccaneers",
    "TEN" => "tennessee-titans",    "WAS" => "washington-commanders"
  }.freeze

  attr_reader :stats

  def initialize(verbose: false, upload_headshots: true,
                 min_season: DEFAULT_MIN_SEASON, status_filter: nil,
                 source_url: PLAYERS_URL, csv_body: nil)
    @verbose = verbose
    @upload_headshots = upload_headshots
    if @upload_headshots && ENV["AWS_ACCESS_KEY_ID"].blank?
      raise "AWS_ACCESS_KEY_ID not set — headshot caching requires AWS credentials. " \
            "Pass upload_headshots: false (or SKIP_HEADSHOTS=1) to opt out."
    end
    @min_season = min_season.to_i
    @status_filter = status_filter.presence
    @source_url = source_url
    @csv_body = csv_body
    @stats = Hash.new(0)
  end

  def call
    rows = ordered(parse_csv)
    puts "  #{rows.size} rows; filter: status=#{@status_filter || "any"} last_season>=#{@min_season}"

    rows.each do |row|
      next @stats[:skipped_inactive] += 1 if @status_filter && row["status"] != @status_filter
      last_season = row["last_season"].to_i
      next @stats[:skipped_old] += 1 if last_season > 0 && last_season < @min_season

      ingest_row(row)
    end

    puts "\nnflverse seed: #{@stats.inspect}"
    @stats
  end

  # Public so tests can drive a single row without a CSV. Returns the Athlete
  # (or nil if skipped).
  # A DETERMINISTIC ingest order, independent of how the feed happens to ship
  # the file.
  #
  # It matters only for namesakes, and only on a rebuild from empty — but that
  # is exactly what a pre-season sync does. Of two players sharing a name, the
  # FIRST one ingested keeps the clean "justin-jefferson" slug and the second
  # gets the disambiguated one. Leave that to CSV order and a rebuild can hand
  # the clean slug to the other player, silently changing a URL that other
  # records point at by slug.
  #
  # Sorting on the league ID makes the outcome a property of the DATA rather
  # than of the file. Rows with no ID sort last and keep their relative order.
  def ordered(rows)
    rows.sort_by { |r| [r["gsis_id"].to_s.strip.empty? ? 1 : 0, r["gsis_id"].to_s.strip] }
  end

  def ingest_row(row)
    gsis_id = row["gsis_id"].to_s.strip.presence
    pff_id  = row["pff_id"].to_s.strip.presence&.to_i
    otc_id  = row["otc_id"].to_s.strip.presence
    espn_id = row["espn_id"].to_s.strip.presence
    pfr_id  = row["pfr_id"].to_s.strip.presence

    # ID hierarchy lookup — every cross-ref ID nflverse provides is unique to a
    # specific player. If any matches an existing Athlete, that's the canonical
    # record (regardless of name). This prevents split-record collisions where
    # "Will Anderson Jr." (with pff_id from PFF CSV) and "Will Anderson" (from
    # Spotrac without suffix) live as two Person+Athlete pairs and a name match
    # picks the wrong one.
    athlete = lookup_athlete_by_ids(gsis_id: gsis_id, pff_id: pff_id, otc_id: otc_id,
                                     espn_id: espn_id, pfr_id: pfr_id)
    person = athlete&.person

    if athlete.nil?
      first = (row["common_first_name"].to_s.strip.presence || row["first_name"].to_s.strip)
      last  = row["last_name"].to_s.strip
      if first.empty? || last.empty?
        @stats[:skipped_no_name] += 1
        return nil
      end

      person = Person.find_or_create_by_name!(first, last, athlete: true)
      @stats[:people_created] += 1 if person.previously_new_record?

      athlete = resolve_athlete!(person, first, last, gsis_id, espn_id)
    end

    attrs = build_attrs(row, gsis_id)
    begin
      athlete.update!(attrs.compact)
      @stats[:athletes_updated] += 1
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @stats[:athletes_failed] += 1
      vputs "  [!] update fail #{person&.slug} (gsis=#{gsis_id}): #{e.message}"
      return nil
    end

    cache_headshot(athlete) if @upload_headshots && attrs[:espn_headshot_url]
    athlete
  end

  private

  # WHICH ATHLETE RECORD THIS ROW BELONGS TO, once a name lookup has found a
  # Person. The name is not enough:
  #
  #   - no athlete yet              -> create one
  #   - athlete with no gsis_id     -> an unidentified record for this name (a
  #                                    seed, or a hand-entered row); adopt it
  #                                    rather than making a twin
  #   - athlete with a DIFFERENT
  #     gsis_id                     -> a DIFFERENT HUMAN who shares the name.
  #                                    Give them their own Person, slugged with
  #                                    a disambiguator, so the two never collide
  #
  # That last branch is the whole point. Adopting blindly is what silently
  # overwrote one of each namesake pair: the row is counted as an update, the
  # import reports success, and a player is simply gone.
  def resolve_athlete!(person, first, last, gsis_id, espn_id)
    existing = Athlete.find_by(person_slug: person.slug)

    return existing if existing && (existing.gsis_id.blank? || existing.gsis_id == gsis_id)

    if existing
      person = Person.create!(
        first_name: first, last_name: last, athlete: true,
        disambiguator: disambiguator_for(gsis_id, espn_id)
      )
      @stats[:people_created] += 1
      @stats[:name_collisions] = @stats.fetch(:name_collisions, 0) + 1
      vputs "  [~] name collision: #{first} #{last} -> #{person.slug}"
    end

    @stats[:athletes_created] += 1
    Athlete.create!(person_slug: person.slug, sport: "football")
  end

  # A short, STABLE suffix. Derived from the league ID rather than a counter, so
  # re-running the import in a different row order produces the same slug — a
  # counter would make a person's URL depend on CSV ordering.
  def disambiguator_for(gsis_id, espn_id)
    source = gsis_id.presence || espn_id.presence
    raise "cannot disambiguate a namesake with no league ID" if source.blank?

    source.gsub(/\D/, "").last(4)
  end

  def lookup_athlete_by_ids(gsis_id:, pff_id:, otc_id:, espn_id:, pfr_id:)
    return Athlete.find_by(gsis_id: gsis_id) if gsis_id && Athlete.exists?(gsis_id: gsis_id)
    return Athlete.find_by(pff_id: pff_id)   if pff_id  && Athlete.exists?(pff_id: pff_id)
    return Athlete.find_by(otc_id: otc_id)   if otc_id  && Athlete.exists?(otc_id: otc_id)
    return Athlete.find_by(espn_id: espn_id) if espn_id && Athlete.exists?(espn_id: espn_id)
    return Athlete.find_by(pfr_id: pfr_id)   if pfr_id  && Athlete.exists?(pfr_id: pfr_id)
    nil
  end

  def build_attrs(row, gsis_id)
    espn_id = row["espn_id"].to_s.strip.presence
    team_abbr = row["latest_team"].to_s.strip.upcase

    {
      gsis_id:           gsis_id,
      pff_id:            row["pff_id"].to_s.strip.presence&.to_i,
      otc_id:            row["otc_id"].to_s.strip.presence,
      espn_id:           espn_id,
      pfr_id:            row["pfr_id"].to_s.strip.presence,
      nflverse_id:       row["nfl_id"].to_s.strip.presence,
      position:          resolve_position(row),
      height_inches:     row["height"].to_s.strip.presence&.to_i,
      weight_lbs:        row["weight"].to_s.strip.presence&.to_i,
      team_slug:         TEAM_ABBR_TO_SLUG[team_abbr],
      espn_headshot_url: (espn_id && "https://a.espncdn.com/i/headshots/nfl/players/full/#{espn_id}.png")
    }
  end

  # Prefer pff_position (PFF's role classification) over the generic position
  # column. nflverse's `position` collapses 3-4 OLBs and 4-3 OLBs into "OLB",
  # which our NFLVERSE_MAP collapses further into "LB" — so true edge rushers
  # (T.J. Watt, Maxx Crosby, Andrew Van Ginkel, etc.) end up tagged LB and
  # never make it to the EDGE pool. PFF disambiguates: "ED" for edge rushers,
  # "DI" for interior linemen, "LB" for off-ball backers.
  def resolve_position(row)
    pff_pos = row["pff_position"].to_s.strip.presence
    return PositionConcern.normalize_position(pff_pos, source: :pff) if pff_pos
    PositionConcern.normalize_position(row["position"], source: :nflverse)
  end

  def cache_headshot(athlete)
    folder = athlete.team_slug.presence || "free-agents"
    key_prefix = "headshots/nfl/#{folder}/#{athlete.person_slug}"
    Studio::ImageCache.cache!(
      owner: athlete,
      purpose: "headshot",
      source_url: athlete.espn_headshot_url,
      key_prefix: key_prefix,
      widths: [100, 400],
      content_type: "image/png"
    )
    @stats[:headshots_cached] += 1
  rescue StandardError => e
    @stats[:headshots_failed] += 1
    vputs "  [!] headshot fail #{athlete.person_slug}: #{e.message}"
  end

  def parse_csv
    body = @csv_body || fetch_remote
    CSV.parse(body, headers: true)
  end

  def fetch_remote
    puts "Fetching #{@source_url}"
    URI.open(@source_url, read_timeout: 60).read.force_encoding("UTF-8")
  end

  def vputs(msg)
    puts msg if @verbose
  end
end
