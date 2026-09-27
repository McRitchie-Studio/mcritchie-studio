require "net/http"
require "json"

module Espn
  # ONE PLAYER, FETCHED FROM ESPN AND TRANSLATED INTO OUR VOCABULARY. The primary
  # provider behind Athletes::AcquireOrValidate, and the only file in that act that
  # knows ESPN's JSON exists.
  #
  # Public API — the seam a second source must satisfy, and nothing more:
  #   #find(source_id:)            -> Athletes::SourceProfile or nil
  #   #find_on_roster(team:, name:) -> Athletes::SourceProfile or nil
  #   #find_in_league(name:)       -> Athletes::SourceProfile or nil — finds a MOVED player
  #   #roster(team:)               -> [Entry] — id + name + group, for search and sweeps
  #
  # ── THE THREE ENDPOINTS, AND THE ONE THAT DOES NOT WORK ──────────────────────
  #
  # Measured 2026-09-27, all public, NO CREDENTIAL of any kind — which is what
  # makes this runnable from a desk, the operator's explicit requirement ("we also
  # need a local solution"):
  #
  #   ROSTER    site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/<abbr>/roster
  #             Las Vegas returned 79 players. This is the acquire route. Read the
  #             note on ROSTER_URL before changing that host: the obvious
  #             site.api.espn.com serves the same document to curl and 403s Ruby.
  #   ATHLETE   site.web.api.espn.com/apis/common/v3/sports/football/nfl/athletes/<id>
  #             displayName, firstName, lastName, jersey, displayHeight,
  #             displayWeight, position.abbreviation, team.slug, college.
  #   HEADSHOT  a.espncdn.com/i/headshots/nfl/players/full/<id>.png — HTTP 200,
  #             ~250KB, image/png for both ids checked.
  #
  # PLAYER-NAME SEARCH IS NOT ONE OF THEM. common/v3/search?query=Bo+Nix answers
  # HTTP 200 with `count: 0` — re-measured 2026-09-27, and it is 200-and-empty
  # rather than an error, so a caller that only checks the status code reads "this
  # man does not exist" and files a refusal about our data. Nothing here calls it.
  # A name is resolved against the TEAM ROSTER instead, which is why #find_on_roster
  # needs a team and cannot take a name alone.
  #
  # ── THE ROSTER'S SHAPE IS A TRAP ─────────────────────────────────────────────
  #
  # `athletes` is NOT a list of players. It is six GROUPS — offense, defense,
  # specialTeam, injuredReserveOrOut, suspended, practiceSquad — each holding
  # `items`. Measured for Las Vegas: `athletes.size` is 6, and the players are the
  # 79 rows underneath. A naive read gets six objects that have no name, no id and
  # no position, so it does not crash; it quietly finds nobody. #roster flattens
  # `items` and carries the group name through, because "which group" is the
  # difference between a starter and a practice-squad body and the operator should
  # see it.
  class PlayerProfile
    # Raised when ESPN could not be reached or answered with something other than a
    # document. DISTINCT from "no such player", which is a plain nil: the caller
    # must be able to tell "our record is wrong" from "the internet was down", and
    # a shared nil return collapses exactly that distinction. Nflverse::SeedPlayers
    # draws the same line with its own FeedUnavailable, for the same reason.
    #
    # Subclasses the SEAM's error, Athletes::SourceUnavailable, so the act can rescue
    # "a source was unreachable" without naming ESPN — which is the whole point of
    # the seam.
    class SourceUnavailable < Athletes::SourceUnavailable; end

    SOURCE = :espn

    # THE ROSTER IS FETCHED FROM site.web.api, NOT site.api — and that one word is
    # the difference between this act working and this act being dead. The whole
    # measurement, the UA table and the reason curl cannot verify either of them now
    # live on Espn::Api, which is where both this class and Espn::ScrapeDepthCharts
    # read them from.
    #
    # THE HOST IS READ, NOT SPELLED OUT, and that is the point. This class had the
    # working host while Espn::ScrapeDepthCharts, in the same directory, had the
    # filtered one, and the scraper was dead for as long as the two copies
    # disagreed. One constant cannot diverge from itself.
    ROSTER_URL = "https://#{Espn::Api::WEB_HOST}/apis/site/v2/sports/football/nfl/teams/%s/roster".freeze
    ATHLETE_URL = "https://#{Espn::Api::WEB_HOST}/apis/common/v3/sports/football/nfl/athletes/%s".freeze
    HEADSHOT_URL = "https://a.espncdn.com/i/headshots/nfl/players/full/%s.png".freeze

    # WHO WE SAY WE ARE — shared, for the same reason as the host. Impersonating a
    # browser bought nothing here and cost the roster call outright.
    USER_AGENT = Espn::Api::USER_AGENT

    TRANSPORT_ERRORS = Espn::Api::TRANSPORT_ERRORS

    # THE 32 ABBREVIATIONS #find_in_league walks, read from the map
    # Espn::ScrapeDepthCharts already carries rather than copied into a second list.
    # Measured 2026-09-27: that map's 32 entries agree with ESPN's own team slugs on
    # every one, and every slug has a `teams` row.
    TEAM_ABBREVS = Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG.keys.freeze

    # One row of a roster: enough to choose a player and then go and fetch them.
    Entry = Struct.new(:source_id, :name, :group, :position, :jersey_number, keyword_init: true)

    def initialize(read_timeout: 30)
      @read_timeout = read_timeout
    end

    def source = SOURCE

    # THE FULL PROFILE for one ESPN id. nil means ESPN has no such athlete —
    # a fact about them, not about us.
    def find(source_id:)
      id = source_id.to_s.strip
      return nil if id.empty?

      body = fetch_json(format(ATHLETE_URL, id))
      return nil unless body

      athlete = body["athlete"]
      return nil unless athlete.is_a?(Hash)

      profile_from(athlete)
    end

    # THE PROFILE FOR A NAMED PLAYER ON A NAMED TEAM. The roster is the only name
    # index ESPN gives us (see the search note above), so the team is required.
    # Matching is punctuation-insensitive in BOTH directions because a feed's
    # "AJ Cole" and a roster's "A.J. Cole" are one man — the same normalization
    # Athletes::NameKey applies to our own rows, kept in one place so the two sides
    # of the comparison cannot drift.
    def find_on_roster(team:, name:)
      wanted = Athletes::NameKey.for(name)
      return nil if wanted.empty?

      entry = roster(team: team).find { |candidate| Athletes::NameKey.for(candidate.name) == wanted }
      return nil unless entry

      find(source_id: entry.source_id)
    end

    # THE WHOLE LEAGUE, BY NAME — the only way to find a man who has MOVED.
    #
    # A trade is the operator's motivating case, and a trade is exactly the
    # situation in which the team we have on file is the one roster he is NOT on any
    # more. So a lookup that searches only the stored team can never discover the
    # event it was built for; measured 2026-09-27 with Bo Nix stored against
    # cincinnati-bengals, #find_on_roster correctly and uselessly reported that
    # ESPN's Cincinnati roster does not list him.
    #
    # ESPN publishes no working player-name search (see the class header), so 32
    # roster reads is not a shortcut avoided — it is the search index, built on
    # demand. Bounded and cheap: 32 public GETs, no credential, and `roster` memoizes
    # per instance so a sweep over one team pays for each roster once. It is also the
    # UNCOMMON path: the first successful lookup stores `espn_id`, and every validate
    # after that is a single request to the athlete endpoint.
    #
    # ABSENCE IS ONLY CONCLUDED FROM A COMPLETE SEARCH. If any roster could not be
    # read and the player was not found in the ones that could, this RAISES rather
    # than returning nil — "he is on no roster in the league" and "I could not read
    # four rosters" are different facts, and the caller turns nil into "retired or
    # released", which would be a lie about a man ESPN still carries.
    def find_in_league(name:)
      wanted = Athletes::NameKey.for(name)
      return nil if wanted.empty?

      unreadable = []
      TEAM_ABBREVS.each do |abbr|
        entry = roster(team: abbr).find { |candidate| Athletes::NameKey.for(candidate.name) == wanted }
        return find(source_id: entry.source_id) if entry
      rescue SourceUnavailable => e
        unreadable << "#{abbr} (#{e.message})"
      end

      if unreadable.any?
        raise SourceUnavailable,
              "searched the league for #{name} and could not read #{unreadable.length} roster(s): " \
              "#{unreadable.join('; ')} — not concluding they are unrostered"
      end

      nil
    end

    # EVERY PLAYER ON A TEAM, flattened out of the six groups described above.
    # Memoized per instance: #find_in_league walks all 32, and a roster sweep asks
    # for the same one repeatedly.
    def roster(team:)
      abbr = team.to_s.strip.downcase
      raise ArgumentError, "team abbreviation is required" if abbr.empty?

      @rosters ||= {}
      return @rosters[abbr] if @rosters.key?(abbr)

      @rosters[abbr] = fetch_roster(abbr)
    end

    private

    def fetch_roster(abbr)
      body = fetch_json(format(ROSTER_URL, abbr))
      raise SourceUnavailable, "ESPN has no roster for team #{abbr.inspect}" unless body

      groups = body["athletes"]
      # A SHAPE CHANGE MUST RAISE, NOT RETURN AN EMPTY ROSTER. If `athletes` ever
      # stops being a list of groups, every lookup through here would answer
      # "nobody on this team" and the act would file 79 honest-looking refusals.
      raise SourceUnavailable, "ESPN roster for #{abbr} is not grouped as expected" unless groups.is_a?(Array)

      groups.flat_map do |group|
        Array(group["items"]).map do |player|
          Entry.new(
            source_id: player["id"].to_s,
            name: player["displayName"].to_s,
            group: group["position"].to_s,
            position: PositionConcern.normalize_position(player.dig("position", "abbreviation"), source: SOURCE),
            jersey_number: Athletes::DisplayMeasurement.jersey_number(player["jersey"])
          )
        end
      end
    end

    # ESPN's athlete document -> Athletes::SourceProfile. Everything the act is
    # allowed to know about this player is decided here.
    def profile_from(athlete)
      id = athlete["id"].to_s
      raw_height = athlete["displayHeight"]
      raw_weight = athlete["displayWeight"]
      height = Athletes::DisplayMeasurement.height_inches(raw_height)
      weight = Athletes::DisplayMeasurement.weight_lbs(raw_weight)

      # THE NUMERIC FIELDS ARE NOT CONSULTED, deliberately. `height` and `weight`
      # measured nil on every athlete checked while the display strings carried the
      # value, so preferring them would look like defensive coding and would in
      # practice only add a second shape to test. If ESPN ever fills them, the
      # display string still agrees and this stays correct.
      unparsed = {}
      unparsed["height_inches"] = raw_height.to_s if height.nil? && raw_height.to_s.strip.present?
      unparsed["weight_lbs"] = raw_weight.to_s if weight.nil? && raw_weight.to_s.strip.present?

      Athletes::SourceProfile.new(
        source: SOURCE,
        source_id: id,
        first_name: athlete["firstName"].to_s.strip.presence,
        last_name: athlete["lastName"].to_s.strip.presence,
        jersey_number: Athletes::DisplayMeasurement.jersey_number(athlete["jersey"]),
        position: PositionConcern.normalize_position(athlete.dig("position", "abbreviation"), source: SOURCE),
        team_slug: team_slug_for(athlete["team"]),
        height_inches: height,
        weight_lbs: weight,
        headshot_url: (format(HEADSHOT_URL, id) if id.present?),
        college: athlete.dig("college", "name").to_s.strip.presence,
        unparsed: unparsed
      )
    end

    # ESPN'S TEAM -> OUR TEAM SLUG, and only a slug `teams` actually holds.
    #
    # `athletes.team_slug` is a foreign key by slug (Athlete belongs_to :team,
    # primary_key: :slug), so writing a slug with no row behind it produces an
    # athlete whose team silently resolves to nil everywhere — including in
    # Athlete#headshot_key_prefix, which would then file the headshot under
    # `free-agents/`. So the row is CHECKED here rather than assumed.
    #
    # ESPN's own `team.slug` is tried first: measured 2026-09-27 across all 32
    # teams, it agrees with Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG on every
    # one and every slug has a `teams` row. The abbreviation map is the FALLBACK,
    # read from that existing constant rather than copied, so there is still one
    # map in this repo and not two. nil is a legitimate answer — a free agent has
    # no team, and Athlete#team_slug is optional.
    def team_slug_for(team)
      return nil unless team.is_a?(Hash)

      slug = team["slug"].to_s.strip
      return slug if slug.present? && Team.exists?(slug: slug)

      mapped = Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG[team["abbreviation"].to_s.downcase]
      mapped if mapped && Team.exists?(slug: mapped)
    end

    # A JSON DOCUMENT, or nil for "ESPN says there is no such thing", or a raise
    # for "ESPN could not answer". A 404 is the only not-found: every other
    # non-success is a failure to reach a working service, and returning nil for
    # those is how a 500 becomes a false statement about a player.
    def fetch_json(url_str)
      url = URI(url_str)
      request = Net::HTTP::Get.new(url)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "application/json"

      response = Net::HTTP.start(url.host, url.port, use_ssl: true, read_timeout: @read_timeout) do |http|
        http.request(request)
      end

      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
      return nil if response.is_a?(Net::HTTPNotFound)

      raise SourceUnavailable, "ESPN answered #{response.code} for #{url.host}#{url.path}"
    rescue *TRANSPORT_ERRORS => e
      raise SourceUnavailable, "#{e.class}: #{e.message}"
    end
  end
end
