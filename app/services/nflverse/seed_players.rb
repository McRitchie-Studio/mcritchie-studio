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
  IDENTITY_COLUMNS = %i[gsis_id pff_id otc_id espn_id pfr_id nflverse_id].freeze
  DISAMBIGUATOR_PRIORITY = %i[gsis_id espn_id pff_id otc_id pfr_id nflverse_id].freeze

  # A third-party feed being unreachable is NOT an import defect, and must not
  # read as one: this service runs as a post-deploy command inside bin/release,
  # where an uncaught raise aborts the ENTIRE ship, not just this task.
  class FeedUnavailable < StandardError; end

  # Transport failures, matching the shape this repo already uses in
  # ReleaseNotes::DiscordClient and Gmail::Client.
  #
  # PARENT classes, deliberately. A literal list of concrete errors drifts the
  # moment the network finds a new way to fail, and it already had: an earlier
  # version named ECONNREFUSED/ECONNRESET/EHOSTUNREACH but missed their
  # siblings ETIMEDOUT, ENETUNREACH and EPIPE — an enumeration incomplete for
  # the very family it enumerates. `SystemCallError` is the parent of every
  # `Errno::`, and `IOError` the parent of `EOFError` (which a server that
  # hangs up mid-chunk raises).
  TRANSPORT_ERRORS = [
    SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
    OpenURI::HTTPError
  ].freeze

  # open-uri raises a BARE RuntimeError for "redirection forbidden" and "HTTP
  # redirection loop" (open-uri.rb:233 and :241). That path is LIVE here, not
  # theoretical: PLAYERS_URL is a GitHub release download, so every single
  # fetch redirects to objects.githubusercontent.com.
  REDIRECT_ERROR = /redirection forbidden|HTTP redirection loop/i

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
    # Recorded so a later reader can tell "nothing changed" apart from "nothing
    # was checked" — a question no record's own updated_at can answer, and the
    # one a delta sync has to ask before trusting an empty result.
    run_import
  rescue FeedUnavailable => e
    # RECORDED, LOUD, AND NOT FATAL. The deploy proceeds because the APP is
    # fine — only the data is stale — and the failed ImportRun is what tells a
    # later reader this refresh never happened. Swallowing it silently would be
    # worse than the abort it replaces.
    warn "nflverse seed: FEED UNAVAILABLE — data not refreshed (#{e.message})"
    @stats[:feed_unavailable] = 1
    @stats
  end

  # PRIVATE (declared below, not by a marker): calling this directly bypasses
  # `call`'s rescue, which is the whole point of the change. A bare `private`
  # here would also privatise `ingest_row`, which is deliberately public so a
  # test can drive one row without a CSV.
  def run_import
    ImportRun.track("nflverse_players") do |run|
      rows = ordered(parse_csv)
      puts "  #{rows.size} rows; filter: status=#{@status_filter || "any"} last_season>=#{@min_season}"

      rows.each do |row|
        next @stats[:skipped_inactive] += 1 if @status_filter && row["status"] != @status_filter
        last_season = row["last_season"].to_i
        next @stats[:skipped_old] += 1 if last_season > 0 && last_season < @min_season

        ingest_row(row)
      end

      run.update!(rows_seen: rows.size,
                  rows_changed: @stats[:athletes_created].to_i + @stats[:athletes_updated].to_i)
      puts "\nnflverse seed: #{@stats.inspect}"
      @stats
    end
  end

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
  # than of the file. Rows with no ID sort last.
  #
  # The index is a TIEBREAK, not decoration: Ruby's `sort_by` is NOT stable, so
  # without it every ID-less row could land in a different relative position on
  # each run — which is the exact non-determinism this method exists to remove.
  def ordered(rows)
    rows.each_with_index
        .sort_by { |r, i| [r["gsis_id"].to_s.strip.empty? ? 1 : 0, r["gsis_id"].to_s.strip, i] }
        .map(&:first)
  end

  # Public so tests can drive a single row without a CSV. Returns the Athlete
  # (or nil if skipped).
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
    nflverse_id = row["nfl_id"].to_s.strip.presence
    identifiers = { gsis_id: gsis_id, pff_id: pff_id, otc_id: otc_id, espn_id: espn_id,
                    pfr_id: pfr_id, nflverse_id: nflverse_id }
    athlete = lookup_athlete_by_ids(**identifiers)
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

      athlete = resolve_athlete!(person, first, last, identifiers)
      return nil unless athlete
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
  #   - athlete with no identity ID -> an unidentified record for this name (a
  #                                    seed, or a hand-entered row); adopt it
  #                                    rather than making a twin
  #   - athlete with a DIFFERENT ID -> a DIFFERENT HUMAN who shares the name.
  #                                    Give them their own Person, slugged with
  #                                    a disambiguator, so the two never collide
  #
  # That last branch is the whole point. Adopting blindly is what silently
  # overwrote one of each namesake pair: the row is counted as an update, the
  # import reports success, and a player is simply gone.
  def resolve_athlete!(person, first, last, identifiers)
    existing = Athlete.find_by(person_slug: person.slug)

    return existing if existing && adoptable_name_match?(existing, identifiers)

    disambiguator = disambiguator_for(identifiers) if existing
    if existing && disambiguator.blank?
      @stats[:namesake_collisions_skipped] += 1
      vputs "  [!] skipped unidentifiable namesake: #{first} #{last}"
      return nil
    end

    # ONE TRANSACTION, because the two writes are one fact. A Person created
    # here whose Athlete then fails leaves an ID-less orphan, and the NEXT run
    # recomputes the same disambiguator and dies on the unique index — an
    # uncaught RecordNotUnique that wedges every later import. The caller's
    # rescue is around `update!`, not around this.
    transaction do
      if existing
        person = Person.create!(
          first_name: first, last_name: last, athlete: true,
          disambiguator: disambiguator
        )
        @stats[:people_created] += 1
        @stats[:name_collisions] = @stats.fetch(:name_collisions, 0) + 1
        vputs "  [~] name collision: #{first} #{last} -> #{person.slug}"
      end

      @stats[:athletes_created] += 1
      Athlete.create!(person_slug: person.slug, sport: "football")
    end
  end

  def transaction(&block) = ActiveRecord::Base.transaction(&block)

  # Name matching can adopt a genuinely unidentified seed record. Once an
  # Athlete carries any cross-reference, though, a row that shares none of
  # them is another person even when GSIS is blank on both sides.
  def adoptable_name_match?(existing, identifiers)
    existing_ids = IDENTITY_COLUMNS.filter_map do |column|
      value = existing.public_send(column)
      [column, value] if value.present?
    end.to_h

    return true if existing_ids.empty?

    identifiers.any? do |column, incoming|
      incoming.present? && existing_ids[column].to_s == incoming.to_s
    end
  end

  # A short, STABLE suffix. Derived from the league ID rather than a counter, so
  # re-running the import in a different row order produces the same slug — a
  # counter would make a person's URL depend on CSV ordering.
  def disambiguator_for(identifiers)
    source = DISAMBIGUATOR_PRIORITY.filter_map { |column| identifiers[column].presence }.first
    return if source.blank?

    digits = source.to_s.gsub(/\D/, "")
    return digits.last(4) if digits.present?

    source.to_s.gsub(/[^a-z0-9]/i, "").downcase.last(8).presence
  end

  def lookup_athlete_by_ids(gsis_id:, pff_id:, otc_id:, espn_id:, pfr_id:, nflverse_id: nil)
    return Athlete.find_by(gsis_id: gsis_id) if gsis_id && Athlete.exists?(gsis_id: gsis_id)
    return Athlete.find_by(pff_id: pff_id)   if pff_id  && Athlete.exists?(pff_id: pff_id)
    return Athlete.find_by(otc_id: otc_id)   if otc_id  && Athlete.exists?(otc_id: otc_id)
    return Athlete.find_by(espn_id: espn_id) if espn_id && Athlete.exists?(espn_id: espn_id)
    return Athlete.find_by(pfr_id: pfr_id)   if pfr_id  && Athlete.exists?(pfr_id: pfr_id)
    # nflverse_id is written by build_attrs and UNIQUELY INDEXED, so it must be
    # probed here too. Missing it meant a row whose nflverse_id already belonged
    # to another athlete fell through to the name path, and `update!` then raised
    # into the caller's rescue — committing a namesake pair carrying no league
    # IDs. The NEXT run recomputed the same disambiguator and died on
    # index_people_on_slug with an uncaught RecordNotUnique, aborting the import.
    return Athlete.find_by(nflverse_id: nflverse_id) if nflverse_id && Athlete.exists?(nflverse_id: nflverse_id)
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

  # The feed is a third party and will have bad minutes. Its errors are named
  # so `call` can tell "nflverse was unreachable" apart from "our import is
  # broken" — a distinction that matters because this runs as a post-deploy
  # command inside `bin/release`, where a raise aborts the whole ship.
  def fetch_remote
    puts "Fetching #{@source_url}"
    open_source(@source_url).read.force_encoding("UTF-8")
  rescue *TRANSPORT_ERRORS => e
    raise FeedUnavailable, "#{e.class}: #{e.message}"
  rescue RuntimeError => e
    # Only open-uri's redirect refusals — anything else is ours and must keep
    # raising, or the quiet path would hide every genuine defect.
    raise unless e.message.match?(REDIRECT_ERROR)

    raise FeedUnavailable, "#{e.class}: #{e.message}"
  end

  private :run_import

  # Seam so a test can make the NETWORK fail rather than hand-raising the
  # wrapped error — which is what let an incomplete rescue list ship.
  def open_source(url)
    URI.open(url, read_timeout: 60)
  end

  def vputs(msg)
    puts msg if @verbose
  end
end
