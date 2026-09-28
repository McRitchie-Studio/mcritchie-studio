require "net/http"
require "json"

# Reads ESPN's per-team depth chart documents and updates DepthChart entries.
#
# SOURCE: ESPN's public JSON APIs, through Espn::Api's hosts. The class name still
# says "scrape" because its callers and its rake task do; nothing here has parsed an
# HTML page since the depth page went behind a CloudFront WAF challenge. The three
# documents and their hosts are named on the URL constants below.
#
# Behavior:
#   * Locked DepthChartEntry rows are never moved.
#   * ESPN-listed players get the depths ESPN assigned (skipping locked depths).
#   * Players already on our chart but not in ESPN's list keep their relative
#     order, slotted in after the ESPN-listed players.
#   * Players ESPN lists but we don't have are SKIPPED with a warning (we only
#     trust contracts + manual seed for who's actually on the team).
#
# Usage:
#   Espn::ScrapeDepthCharts.new.call                         # all 32 teams
#   Espn::ScrapeDepthCharts.new(team_abbrev: "buf").call     # single team
class Espn::ScrapeDepthCharts
  TEAM_ABBREV_TO_SLUG = {
    "buf" => "buffalo-bills",       "mia" => "miami-dolphins",
    "ne"  => "new-england-patriots", "nyj" => "new-york-jets",
    "bal" => "baltimore-ravens",    "cin" => "cincinnati-bengals",
    "cle" => "cleveland-browns",    "pit" => "pittsburgh-steelers",
    "hou" => "houston-texans",      "ind" => "indianapolis-colts",
    "jax" => "jacksonville-jaguars", "ten" => "tennessee-titans",
    "den" => "denver-broncos",      "kc"  => "kansas-city-chiefs",
    "lv"  => "las-vegas-raiders",   "lac" => "los-angeles-chargers",
    "dal" => "dallas-cowboys",      "nyg" => "new-york-giants",
    "phi" => "philadelphia-eagles", "wsh" => "washington-commanders",
    "chi" => "chicago-bears",       "det" => "detroit-lions",
    "gb"  => "green-bay-packers",   "min" => "minnesota-vikings",
    "atl" => "atlanta-falcons",     "car" => "carolina-panthers",
    "no"  => "new-orleans-saints",  "tb"  => "tampa-bay-buccaneers",
    "ari" => "arizona-cardinals",   "lar" => "los-angeles-rams",
    "sf"  => "san-francisco-49ers", "sea" => "seattle-seahawks"
  }.freeze

  # ESPN ST rows we ignore: holders, returners, gunners are derived from other positions
  IGNORED_POSITIONS = %w[H KR PR LH PH].freeze

  # Raised when ESPN could not be reached, or answered with something other than a
  # document. DISTINCT from "ESPN has no such document", which stays a plain nil:
  # the caller must be able to tell "our data is wrong" from "the service was down",
  # and a shared nil return collapses exactly that distinction. Espn::PlayerProfile
  # draws the same line with its own SourceUnavailable, for the same reason.
  class SourceUnavailable < StandardError; end

  # Raised when ESPN's teams index WAS read and carries no id for an abbreviation
  # this run was asked to scrape.
  #
  # THIS IS NOT WEATHER AND MUST NOT BE TOLERATED. A team ESPN cannot serve a depth
  # chart for today is a normal ESPN afternoon and is counted, not raised over (see
  # the tally lib/tasks/espn.rake grades). But TEAM_ABBREV_TO_SLUG disagreeing with
  # ESPN's own index is a fault in this repository: it cannot heal on the next run,
  # and the old behaviour — one printed line, one tallied failure, the other 31 teams
  # applied — is how a chart goes a week stale behind a green lane.
  class MissingTeamId < StandardError; end

  # RAISED AND IMMEDIATELY RESCUED BY lib/tasks/espn.rake, so the ErrorLog receipt for
  # a scrape that applied nothing carries a real class, message and backtrace rather
  # than the empty one a bare `.new` would file. Insights::DocFreshness::StaleDocError
  # exists for the same reason and is built the same way. It changes no verdict: the
  # lane still aborts on the same condition, and this only makes the abort findable in
  # /admin/error_logs a week later.
  class ScrapeDidNotHappen < StandardError; end

  # An operator typo in TEAM=, not an ESPN fact: refused up front, never filed.
  class UnknownTeam < ArgumentError; end

  # Nil for "all teams"; case and spaces are normalised, as Espn::PlayerProfile#roster does.
  def self.normalize_team!(raw)
    return nil if raw.to_s.strip.empty?

    abbrev = raw.to_s.strip.downcase
    return abbrev if TEAM_ABBREV_TO_SLUG.key?(abbrev)

    raise UnknownTeam, "Unknown TEAM=#{raw.to_s.strip.inspect}. Valid codes: #{TEAM_ABBREV_TO_SLUG.keys.sort.join(' ')}"
  end

  # WHO WE SAY WE ARE. Read from Espn::Api rather than spelled out, because a
  # second copy of this string is precisely how this service came to send a Chrome
  # UA while its neighbour sent an honest one. The browser string was not merely
  # useless: the WAF on the old host rejected it and admitted curl.
  USER_AGENT = Espn::Api::USER_AGENT

  attr_reader :stats

  def initialize(team_abbrev: nil, verbose: false)
    @only_team = self.class.normalize_team!(team_abbrev)
    @verbose = verbose
    @stats = Hash.new(0)
  end

  def vputs(msg)
    puts msg if @verbose
  end

  def call
    known = @only_team ? [@only_team] : TEAM_ABBREV_TO_SLUG.keys

    # EVERY ID RESOLVES BEFORE ANY CHART IS TOUCHED. Raising partway through would
    # leave a half-refreshed league behind a non-zero exit, which is worse than
    # either outcome; and resolving up front means a run either covers the teams it
    # was asked for or does nothing at all. It costs one request either way, because
    # the index is fetched once and memoized.
    resolve_team_ids!(known) if known.any?

    known.each { |abbrev| scrape_team(abbrev, TEAM_ABBREV_TO_SLUG.fetch(abbrev)) }

    puts "\nESPN scrape complete: #{@stats.inspect}"
    @stats
  end

  private

  def scrape_team(abbrev, team_slug)
    chart = DepthChart.find_or_create_by!(team_slug: team_slug)
    @stats[:depth_charts_created] += 1 if chart.previously_new_record?

    groups = fetch_groups(abbrev, chart)
    unless groups
      puts "  [!] Failed to parse depth chart for #{abbrev}"
      @stats[:teams_failed] += 1
      return
    end

    # ESPN occasionally serves partial responses (Lions on 2026-05-01 returned
    # only "Base 4-3 D" — no offense, no special teams). Applying that data
    # would silently OVERWRITE a complete chart with incomplete data. Skip
    # the team if we don't see all three sides — the next scrape (when ESPN
    # is healthy) will refresh.
    sides_present = groups.map { |g| side_for_group(g["name"]) }.compact.uniq
    if sides_present.size < 3
      puts "  [!] #{team_slug}: ESPN returned partial response (sides: #{sides_present.inspect}), skipping to preserve existing chart"
      @stats[:teams_partial] += 1
      return
    end

    # Tag each athlete with their raw formation slot ("WLB", "LDE", "NT") and
    # PRESERVE ESPN's row structure. Multi-row position groups (e.g. WR has 3
    # rows for WR1/WR2/WR3 chains) need the row grouping intact so flatten_rows
    # can round-robin the starters together: row1[0], row2[0], row3[0], then
    # row1[1], row2[1], row3[1], etc.
    by_side_pos = Hash.new { |h, k| h[k] = [] }
    groups.each do |group|
      side = side_for_group(group["name"])
      next unless side
      group["rows"].each do |row|
        formation_slot = row[0].to_s.upcase
        next if IGNORED_POSITIONS.include?(formation_slot)
        position = normalize_position(formation_slot)
        tagged_row = row[1..].compact.map { |a| a.merge("_formation_slot" => formation_slot) }
        by_side_pos[[side, position]] << tagged_row
      end
    end

    by_side_pos.each do |(side, position), rows|
      flattened = flatten_rows(rows)
      apply_row(chart, position, side, flattened, team_slug)
    end

    # Reconcile any same-side disagreements: ESPN's formation labels
    # (esp. 3-4 OLB vs 4-3 OLB) get collapsed to LB by ESPN_MAP, but our
    # athlete.position from nflverse correctly classifies edge rushers as
    # EDGE. Move the depth chart entry to match athlete.position so Maxx
    # Crosby (OLB→EDGE) is found in the EDGE pool by the Roster picker.
    reconcile_chart_positions(chart)

    # Re-densify depths everywhere — moves leave gaps at the source position.
    densify_chart(chart)

    puts "  [+] #{team_slug}: applied ESPN depth chart"
    @stats[:teams_scraped] += 1
  end

  # Defensive front-7 positions where ESPN's formation slot can disagree with
  # nflverse's player-role classification. ESPN labels by formation (LDE in
  # a 3-4 is interior DT; OLB in a 3-4 is an edge rusher) while nflverse
  # tracks the player's actual role across schemes. When chart.position and
  # athlete.position both fall in this set but differ, athlete.position wins.
  # Excluded by design: CB ↔ S (slot/big-nickel fluidity is real position
  # blending, not a labeling error).
  RECONCILE_FRONT7 = %w[EDGE DE DT NT DL DI LB ILB OLB MLB].freeze

  def reconcile_chart_positions(chart)
    chart.depth_chart_entries.includes(person: :athlete_profile).each do |entry|
      next if entry.locked
      ath_pos = entry.person&.athlete_profile&.position
      next if ath_pos.blank? || ath_pos == entry.position
      next unless reconcile_pair?(entry.position, ath_pos)

      # Player already has an entry at the canonical position on this chart
      # (e.g., a post-merge state where one entry came from each duplicate
      # Person). Drop the misplaced one — the canonical-position entry wins.
      twin = chart.depth_chart_entries
                  .where(person_slug: entry.person_slug, position: ath_pos)
                  .where.not(id: entry.id)
                  .first
      if twin
        entry.destroy
        @stats[:positions_deduped] += 1
        next
      end

      old_position = entry.position
      old_depth    = entry.depth

      # Bump existing entries at the target position with depth >= old_depth
      # down by one, preserving Crosby's starter slot at the new position.
      chart.depth_chart_entries
           .where(position: ath_pos)
           .where(locked: false)
           .where("depth >= ?", old_depth)
           .order(depth: :desc)
           .each { |other| other.update!(depth: other.depth + 1) }

      entry.update!(position: ath_pos)
      vputs "      [↔] #{entry.person.full_name}: #{old_position}#{old_depth} → #{ath_pos}#{old_depth}"
      @stats[:positions_reconciled] += 1
    end
  end

  def reconcile_pair?(chart_pos, athlete_pos)
    RECONCILE_FRONT7.include?(chart_pos) && RECONCILE_FRONT7.include?(athlete_pos)
  end

  # THE THREE DOCUMENTS, AND WHICH HOST EACH ONE LIVES ON.
  #
  # The depth chart comes from Espn::Api::CORE_HOST; the legacy HTML page at
  # www.espn.com/nfl/team/depth/_/name/{abbrev} has been behind a CloudFront WAF
  # challenge (HTTP 202 + x-amzn-waf-action: challenge) since long before this
  # comment, and nothing here parses HTML. That host never filtered on User-Agent.
  #
  # The roster and the teams index come from Espn::Api::WEB_HOST — NOT the obvious
  # site.api.espn.com, which answers curl with 200 and Ruby with 403. Read the note
  # on Espn::Api before changing either of them by one word; both of these lines
  # named the filtered host and that is what killed this service.
  #
  # The depth chart document gives athletes as $ref URLs only, so espn_id is pulled
  # out of the ref and the player's name comes from a one-call-per-team roster read,
  # which is why the roster host matters here at all.
  ESPN_DEPTHCHART_URL  = ->(year, team_id) { "https://#{Espn::Api::CORE_HOST}/v2/sports/football/leagues/nfl/seasons/#{year}/teams/#{team_id}/depthcharts" }
  ESPN_ROSTER_URL      = ->(team_id)       { "https://#{Espn::Api::WEB_HOST}/apis/site/v2/sports/football/nfl/teams/#{team_id}/roster" }
  ESPN_TEAMS_INDEX_URL = "https://#{Espn::Api::WEB_HOST}/apis/site/v2/sports/football/nfl/teams".freeze

  # The depth chart in the shape the downstream parser expects:
  #   [{ "name" => "Base 4-3 D", "rows" => [[position_label, athlete_hash, ...], ...] }, ...]
  def fetch_groups(abbrev, chart)
    team_id = team_id_for(abbrev)
    names = fetch_roster_names(team_id) # espn_id (String) => display_name

    year = current_nfl_year
    body = fetch_json(ESPN_DEPTHCHART_URL.call(year, team_id))
    # Try previous season if current is 404 (ESPN may not have published yet)
    body ||= fetch_json(ESPN_DEPTHCHART_URL.call(year - 1, team_id))
    return nil unless body

    (body["items"] || []).map do |item|
      rows = (item["positions"] || {}).map do |_key, pos_data|
        pos_label = pos_data.dig("position", "abbreviation").to_s.upcase
        athletes = (pos_data["athletes"] || []).sort_by { |a| a["slot"].to_i }.map do |a|
          espn_id = a.dig("athlete", "$ref").to_s[%r{/athletes/(\d+)}, 1]
          name = names[espn_id]
          {
            "href" => espn_id ? "https://www.espn.com/nfl/player/_/id/#{espn_id}/" : nil,
            "name" => name,
            "displayName" => name,
            "uid" => "espn:#{espn_id}"
          }
        end
        [pos_label] + athletes
      end
      { "name" => item["name"], "rows" => rows }
    end
  # THE PER-TEAM TOLERANCE, AND THE ONE THING IT MAY NOT SWALLOW. One team ESPN
  # cannot serve must not cost the other 31 their refresh, so a failure here becomes
  # a nil and scrape_team tallies it. MissingTeamId is re-raised through that rescue
  # on purpose: it is a fault in our own abbreviation map, it will still be there
  # next run, and turning it into one more tolerated team is the defect this service
  # was revived to remove.
  #
  # AND THE CAUSE GOES WHERE SOMEONE WILL FIND IT. The tolerance above is right and
  # stays; what was missing was the CAUSE. The `puts` below was the only place a dead
  # team's exception had ever been written, and bin/ecosystem-build runs this lane as
  # `bundle exec rails espn:scrape_depth_charts >/dev/null` — stdout discarded by
  # intent. The tally lib/tasks/espn.rake prints survives on stderr and carries
  # COUNTS, never causes, so by the time anyone asks why a chart is stale the answer
  # is gone. MEASURED with `git grep -cE "ErrorLog|rescue_and_log" origin/accepted --
  # app/services/espn lib/tasks/espn.rake`, which exits 1 with no output: zero hits,
  # while two sibling feed services file rows (Nflverse::SeedPlayers#record_outage,
  # Appearances::ImageSearch::WikimediaCommons).
  #
  # IT IS FILED HERE AND NOT ON scrape_team'S `unless groups`, because those are two
  # different facts. fetch_groups also answers nil when ESPN served a 404 for BOTH the
  # current and the previous season's document — a source with nothing to give, which
  # parse_response separates from every other non-success BY STATUS — the same move
  # Athletes::DeadHeadshotSource makes for the headshot lane, though NOT the same LIST.
  # It treats 404 AND 410 as dead; parse_response answers nil for 404 alone, so a 410
  # raises here and files a row. The season fallback needs the 404 nil, and no 410 has
  # been observed from these hosts — DeadHeadshotSource carries 410 on the protocol's
  # word, not on a measurement — so the gap is tolerable. But it is a difference, not a
  # parity: adding 410 to the nil branch owes that fallback a second look. A row
  # filed from `unless groups` would record that dead source as our failure; a row
  # filed in this rescue cannot, because the 404 became a nil and never raised.
  # (DeadHeadshotSource itself does not apply: it reads `io.status` off an
  # OpenURI::HTTPError and this service is Net::HTTP throughout, so calling it would
  # answer "not dead" for every ESPN error. The distinction it draws is already drawn
  # here, one layer lower, and a second classifier would be the duplication.)
  #
  # NOT `rescue_and_log`: that is the controller concern's wrapper and it RE-RAISES,
  # which would end a 32-team walk on the first dead team — the exact failure this
  # rescue exists to prevent.
  #
  # BOUNDED AT ONE ROW PER TEAM, so 32 in the worst run — TEAM_ABBREV_TO_SLUG.size is
  # 32, measured with `bin/rails runner 'puts
  # Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG.size'`. The worst run does not reach
  # here at all: an unreadable teams index raises out of resolve_team_ids! before the
  # loop starts, which is ONE row from the lane rather than 32 from this line.
  #
  # NOTHING CREDENTIAL-SHAPED CAN REACH THE ROW, structurally rather than by
  # scrubbing. Every endpoint this service reads is public and takes no key (Espn::Api
  # names all three hosts and no token), and the exception is filed exactly as raised
  # with nothing added — no response body, no headers, no request. That matters
  # because fetch_json's message carries the URL, so a key in a query string would
  # land in a durable table that also reaches Sentry; a test in
  # test/services/espn/scrape_depth_charts_test.rb refuses `ENV[` back into this
  # directory for that reason.
  #
  # The DepthChart is the target so /admin/error_logs renders the team on the row, and
  # it is a REQUIRED argument rather than one defaulting to nil: scrape_team is the only
  # caller and it has already created the row with find_or_create_by!, so a nil default
  # would be an untestable branch dressed as caution. Appearances::FailureLog swallows
  # its own failure, so telemetry can never veto the tolerance it reports.
  rescue MissingTeamId
    raise
  rescue StandardError => e
    puts "  [!] Fetch error for #{abbrev}: #{e.class}: #{e.message}"
    Appearances::FailureLog.file(e, target: chart)
    nil
  end

  # EVERY ID THIS RUN NEEDS, OR A RAISE THAT NAMES THE ONES MISSING.
  #
  # The old shape returned nil per team and printed "No ESPN team_id for abbrev X".
  # That sentence was a statement about OUR map, and it was usually a lie: the real
  # cause was an unreadable index, which made the abbrev map EMPTY and printed the
  # same line 32 times. Both halves are now separated and both are loud.
  def resolve_team_ids!(abbrevs)
    missing = abbrevs.reject { |abbrev| team_ids[abbrev].present? }
    return if missing.empty?

    raise MissingTeamId,
          "ESPN's teams index served #{team_ids.size} team(s) and carries no id for " \
          "#{missing.size} abbreviation(s) this run needs: #{missing.sort.join(', ')}. " \
          "TEAM_ABBREV_TO_SLUG in #{self.class} disagrees with ESPN's own index — " \
          "compare it against #{ESPN_TEAMS_INDEX_URL} and correct the map. No depth " \
          "chart was touched."
  end

  # ESPN's API uses numeric team_ids. Map our abbrev (e.g. "ari") → ESPN id ("22").
  def team_id_for(abbrev)
    team_ids[abbrev] || raise(MissingTeamId, "ESPN's teams index carries no id for abbrev #{abbrev.inspect}")
  end

  # ESPN'S OWN abbrev => id INDEX. One HTTP call per service instance.
  #
  # An index that could not be read RAISES rather than answering with an empty map:
  # "ESPN has no teams" is never true, and the empty map is what turned a single 403
  # into 32 honest-looking per-team failures and an exit code of 0.
  def team_ids
    @team_ids ||= begin
      body = fetch_json(ESPN_TEAMS_INDEX_URL)
      raise SourceUnavailable, "ESPN has no teams index at #{ESPN_TEAMS_INDEX_URL} (404)" if body.nil?

      teams = body.dig("sports", 0, "leagues", 0, "teams")
      # A SHAPE CHANGE MUST RAISE, NOT PRODUCE AN EMPTY LEAGUE — the same reason
      # Espn::PlayerProfile refuses to read an ungrouped roster as "nobody".
      unless teams.is_a?(Array) && teams.any?
        raise SourceUnavailable,
              "ESPN's teams index is not shaped as expected at #{ESPN_TEAMS_INDEX_URL}: " \
              "sports[0].leagues[0].teams was #{teams.class}"
      end

      teams.each_with_object({}) do |entry, h|
        team = entry["team"] || {}
        h[team["abbreviation"].to_s.downcase] = team["id"]
      end
    end
  end

  # One call per team — returns { espn_id_string => "Jacoby Brissett" }.
  def fetch_roster_names(team_id)
    body = fetch_json(ESPN_ROSTER_URL.call(team_id))
    out = {}
    (body&.dig("athletes") || []).each do |group|
      (group["items"] || []).each do |ath|
        out[ath["id"].to_s] = ath["displayName"] || ath["fullName"]
      end
    end
    out
  end

  # A JSON DOCUMENT, or nil for "ESPN has no such document", or a raise for "ESPN
  # could not answer".
  #
  # A 404 IS THE ONLY NOT-FOUND, and the season fallback above depends on that nil.
  # Every other non-success is a failure to reach a working service: the old
  # `return nil unless Net::HTTPSuccess` is what turned a 403 into "this team has no
  # id" and a 500 into "ESPN published no depth chart", and then nothing upstream
  # could tell either from the truth.
  def fetch_json(url_str)
    url = URI(url_str)
    req = Net::HTTP::Get.new(url)
    req["User-Agent"] = USER_AGENT
    req["Accept"] = "application/json"
    res = Net::HTTP.start(url.host, url.port, use_ssl: true, read_timeout: 30) { |http| http.request(req) }
    parse_response(res, url)
  rescue *Espn::Api::TRANSPORT_ERRORS => e
    raise SourceUnavailable, "#{e.class}: #{e.message} for #{url_str}"
  end

  # THE STATUS-CODE POLICY, SPLIT OUT FROM THE TRANSPORT so it can be tested against
  # a real Net::HTTPResponse without a socket. JSON.parse is inside the rescue in
  # fetch_json on purpose: the 403 this service used to collect is an HTML page, and
  # a body that is not JSON is a transport-shaped lie about the document.
  def parse_response(res, url)
    return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)
    return nil if res.is_a?(Net::HTTPNotFound)

    raise SourceUnavailable, "ESPN answered #{res.code} for #{url.host}#{url.path}"
  end

  def current_nfl_year
    # The NFL season is named by its start year; e.g. games played Sep 2026 → Feb 2027
    # are "2026 season". From Jan-Feb we're still in the prior season's playoffs.
    today = Date.current
    today.month <= 2 ? today.year - 1 : today.year
  end

  def side_for_group(name)
    case name
    when /Special Teams/i        then "special_teams"
    when /\bD\b|Defense|Nickel|Base/i then "defense"
    else "offense"
    end
  end

  def normalize_position(espn_pos)
    PositionConcern.normalize_position(espn_pos, source: :espn)
  end

  # Round-robin flatten: row0[0], row1[0], row2[0], row0[1], row1[1], ...
  # Dedupes (ESPN sometimes cross-lists e.g. nickel CB in two slots).
  def flatten_rows(rows)
    max_depth = rows.map(&:size).max || 0
    out, seen = [], {}
    (0...max_depth).each do |col|
      rows.each do |row|
        athlete = row[col]
        next unless athlete
        key = athlete["uid"] || athlete["href"] || athlete["name"]
        next if seen[key]
        seen[key] = true
        out << athlete
      end
    end
    out
  end

  # Apply ESPN's depth ranking to a canonical (position, side):
  # 1. ESPN's order is preserved verbatim. If ESPN lists a brand-new player
  #    above an existing one, the new player gets the higher slot — this is
  #    the whole point of the weekly scrape (overwrite starters).
  # 2. Each player has at most one entry on the chart. If ESPN places them at
  #    a different position than their existing entry, MOVE the entry.
  # 3. Locked entries at this position keep their fixed depth.
  # 4. Existing entries at this position not in ESPN's list keep their
  #    relative order, slotting in BELOW ESPN's listed players.
  def apply_row(chart, position, side, athletes, team_slug)
    # Resolve persons ONCE (match_person has side effects: contract creation,
    # team_slug sync). Remember each athlete's raw formation slot so we can
    # persist it on the depth chart entry for the scheme-aware Roster picker.
    resolved = athletes.filter_map do |a|
      person = match_person(a, team_slug, position: position)
      next nil unless person
      [person, a["_formation_slot"]]
    end
    espn_persons  = resolved.map(&:first)
    formation_for = resolved.to_h { |person, fs| [person.slug, fs] }

    # Existing entry per ESPN-listed person on this chart. A player can
    # legitimately have only one entry at a given position, but post-merge
    # data can leave a person with multiple entries at DIFFERENT positions
    # (e.g., one carried over from each side of a duplicate-Person merge).
    # Prefer the entry already at our target position; drop the others so
    # the upcoming move doesn't violate the [chart, person, position]
    # uniqueness constraint.
    existing_for_espn = {}
    all_entries = chart.depth_chart_entries.where(person_slug: espn_persons.map(&:slug)).to_a
    all_entries.group_by(&:person_slug).each do |slug, entries|
      keep = entries.find { |e| e.position == position } || entries.first
      existing_for_espn[slug] = keep
      (entries - [keep]).each do |stale|
        next if stale.locked
        stale.destroy
        @stats[:stale_entries_pruned] += 1
      end
    end

    position_entries = chart.depth_chart_entries.where(position: position).to_a
    locked = position_entries.select(&:locked).sort_by(&:depth)
    locked_persons = locked.map(&:person_slug).to_set

    # Build the ordered list in ESPN's exact order. For each ESPN-listed
    # player, either reuse their existing entry (so we MOVE them here from
    # wherever they were) or build a new entry. Skip anyone whose entry is
    # already locked (manual overrides win).
    espn_ordered = espn_persons.map do |person|
      next nil if locked_persons.include?(person.slug)
      existing = existing_for_espn[person.slug]
      next nil if existing&.locked
      existing || chart.depth_chart_entries.build(person_slug: person.slug, position: position, side: side)
    end.compact

    new_count = espn_ordered.count(&:new_record?)

    # Existing players at this position whom ESPN didn't mention slot in below.
    unlisted = position_entries.reject { |e| e.locked || espn_ordered.include?(e) }
                               .sort_by(&:depth)

    ordered = espn_ordered + unlisted
    total = ordered.size + locked.size
    free_depths = (1..total).to_a - locked.map(&:depth)

    ordered.each_with_index do |entry, i|
      depth = free_depths[i] || (total + i + 1)
      attrs = { depth: depth, side: side, position: position }
      attrs[:formation_slot] = formation_for[entry.person_slug] if formation_for[entry.person_slug]
      entry.assign_attributes(attrs)
      entry.save!
    end

    @stats[:rows_applied] += 1
    @stats[:athletes_matched] += espn_persons.size
    @stats[:athletes_added] += new_count
  end

  # After moves, the source position may have depth gaps (1,2,4,5 with 3 missing).
  # Re-pack so every position runs 1..N, respecting locked depths.
  def densify_chart(chart)
    chart.depth_chart_entries.distinct.pluck(:position).each do |pos|
      entries = chart.depth_chart_entries.where(position: pos).order(:depth).to_a
      locked_depths = entries.select(&:locked).map(&:depth)
      unlocked = entries.reject(&:locked)

      free_depths = (1..entries.size).to_a - locked_depths
      unlocked.each_with_index do |e, i|
        target = free_depths[i] || (entries.size + i + 1)
        e.update!(depth: target) unless e.depth == target
      end
    end
  end

  # Resolve ESPN athlete → our Person, ensuring an active Contract exists for
  # this team. ESPN is now authoritative for "who is on the team this week" —
  # if ESPN places a player and we don't have them on this team, create the
  # Contract and expire any active contract on a different team (player moved).
  # Also keeps Athlete.team_slug in sync with the team the scraper just placed
  # them on.
  def match_person(athlete, team_slug, position: nil)
    espn_id = athlete["href"].to_s[%r{/id/(\d+)/}, 1]
    person, athlete_record = lookup_person(espn_id, athlete["name"] || athlete["displayName"])

    unless person
      vputs "      [?] no match: #{athlete['name']} (espn_id=#{espn_id})"
      @stats[:athletes_unmatched] += 1
      return nil
    end

    athlete_record ||= person.athlete_profile
    if athlete_record.nil?
      vputs "      [?] no athlete record: #{person.full_name}"
      @stats[:athletes_no_record] += 1
      return nil
    end

    backfill_espn_id(athlete_record, espn_id) if espn_id
    ensure_active_contract(person, athlete_record, team_slug, position)
    person
  end

  # When we name-matched an athlete (because lookup_by_espn_id missed) but ESPN's
  # href DID give us an espn_id, persist it so future scrapes can fast-path AND
  # downstream nfl:upload_headshots can cache the headshot. Skip if athlete
  # already has espn_id (don't overwrite) or if some OTHER athlete already owns
  # that espn_id (uniqueness-protected).
  def backfill_espn_id(athlete, espn_id)
    return if athlete.espn_id.present?
    return if Athlete.where(espn_id: espn_id).where.not(id: athlete.id).exists?
    athlete.update!(
      espn_id: espn_id,
      espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/#{espn_id}.png"
    )
    @stats[:espn_ids_backfilled] += 1
  end

  def lookup_person(espn_id, name)
    if espn_id
      ath = Athlete.find_by(espn_id: espn_id)
      return [ath.person, ath] if ath
    end

    return [nil, nil] if name.blank?
    parts = strip_suffix(name).split(/\s+/, 2)
    return [nil, nil] if parts.size < 2

    person = Person.find_by_name(parts[0], parts[1])
    [person, person&.athlete_profile]
  end

  # Make Contract state agree with what ESPN just told us:
  #   1. Find or create active Contract for [person, team_slug]. If existing
  #      Contract was previously expired, un-expire it.
  #   2. Expire any other active Contracts the player has (they moved teams).
  #   3. Update Athlete.team_slug.
  def ensure_active_contract(person, athlete_record, team_slug, position)
    contract = Contract.find_or_initialize_by(person_slug: person.slug, team_slug: team_slug)
    if contract.new_record?
      contract.contract_type = "active"
      contract.position = position if position
      contract.save!
      @stats[:contracts_created] += 1
    elsif contract.expires_at && contract.expires_at < Date.today
      contract.update!(expires_at: nil, contract_type: "active")
      @stats[:contracts_revived] += 1
    end

    Contract.where(person_slug: person.slug, contract_type: "active")
            .where.not(team_slug: team_slug)
            .where("expires_at IS NULL OR expires_at >= ?", Date.today)
            .find_each do |stale|
      stale.update!(expires_at: Date.today - 1)
      @stats[:contracts_expired] += 1
    end

    if athlete_record.team_slug != team_slug
      athlete_record.update!(team_slug: team_slug)
      @stats[:team_slug_updates] += 1
    end
  end

  def strip_suffix(name)
    name.sub(/\s+(Jr\.?|Sr\.?|II|III|IV|V)\s*$/i, "").strip
  end
end
