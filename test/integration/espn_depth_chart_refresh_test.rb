require "test_helper"

# [integration] ALL THIRTY-TWO TEAMS, THROUGH THE SERVICE'S OWN HTTP STACK.
#
# The unit suite stubs Espn::ScrapeDepthCharts#fetch_json, which is the right seam
# for translation and tally behaviour but cannot see the two things this bug was
# made of: WHICH HOST the service dials and WHAT USER AGENT it sends. Those live
# below fetch_json, so this test stubs one level lower — at Net::HTTP.start — and
# lets the real fetch_json build the request, choose the host, set the header and
# judge the status code.
#
# WHY THAT LEVEL MATTERS. site.api.espn.com answers curl with 200 and Ruby with
# 403 (re-measured 2026-09-27: 403/437 bytes to an honest UA and to a Chrome 120
# string; site.web.api answered 200/148848 bytes to both and to no UA at all).
# A test that stubs fetch_json would pass with either host wired in. This one
# records every authority and every User-Agent the transport was actually handed,
# so a regression to the dead host fails here rather than in production silence.
#
# It also answers the countable claim in this task's acceptance — "depth charts
# land for all thirty-two teams" — mechanically, by running the real `call` over
# the real 32-entry abbreviation map and counting the charts that came out.
class EspnDepthChartRefreshTest < ActionDispatch::IntegrationTest
  ABBREVS = Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG

  # ESPN's own numeric ids, read from the live index on 2026-09-27. Real ids rather
  # than 1..32 so the depth chart and roster URLs this test asserts are the URLs
  # production builds.
  ESPN_IDS = {
    "buf" => "2",  "mia" => "15", "ne" => "17",  "nyj" => "20", "bal" => "33",
    "cin" => "4",  "cle" => "5",  "pit" => "23", "hou" => "34", "ind" => "11",
    "jax" => "30", "ten" => "10", "den" => "7",  "kc" => "12",  "lv" => "13",
    "lac" => "24", "dal" => "6",  "nyg" => "19", "phi" => "21", "wsh" => "28",
    "chi" => "3",  "det" => "8",  "gb" => "9",   "min" => "16", "atl" => "1",
    "car" => "29", "no" => "18",  "tb" => "27",  "ari" => "22", "lar" => "14",
    "sf" => "25",  "sea" => "26"
  }.freeze

  setup do
    @seen = [] # [authority, path, user_agent] for every request the transport saw
    ABBREVS.each_value { |slug| ensure_team(slug) }
    ESPN_IDS.each_key { |abbrev| ensure_athlete(abbrev) }
  end

  test "a healthy league run lands a depth chart for all thirty-two teams" do
    stats = nil
    with_transport { stats = Espn::ScrapeDepthCharts.new.call }

    assert_equal 32, stats[:teams_scraped],
                 "every team in the abbreviation map must be applied, not most of them"
    assert_equal 0, stats[:teams_failed]
    assert_equal 0, stats[:teams_partial]

    landed = DepthChart.where(team_slug: ABBREVS.values).count
    assert_equal 32, landed, "32 charts, counted in the database rather than in the tally"

    # A TALLY IS NOT AN OUTCOME. teams_scraped counts the times the service reached
    # the end of scrape_team; this counts rows an operator can read.
    assert_equal 32, DepthChartEntry.joins(:depth_chart)
                                    .where(depth_charts: { team_slug: ABBREVS.values })
                                    .distinct.count("depth_charts.slug"),
                 "every chart must carry at least one entry"
  end

  test "every request goes to a host that serves Ruby, under an honest user agent" do
    with_transport { Espn::ScrapeDepthCharts.new.call }

    authorities = @seen.map(&:first).uniq.sort
    assert_equal ["sports.core.api.espn.com", "site.web.api.espn.com"].sort, authorities,
                 "site.api.espn.com answers curl and 403s Ruby — it must never be dialled"

    agents = @seen.map(&:last).uniq
    assert_equal [Espn::Api::USER_AGENT], agents, "one user agent, the shared one"
    agents.each do |ua|
      refute_match(/Mozilla|Chrome|Safari|AppleWebKit/, ua,
                   "the WAF rejected the browser string and admitted curl; impersonation " \
                   "is what broke this service")
    end

    # 1 index + 32 rosters + 32 depth charts. Pinned so a future change that asks
    # ESPN for the index once per team is visible as a change, not as a slow day.
    assert_equal 65, @seen.length
  end

  test "a 403 from the transport is raised, not turned into an empty league" do
    # THE ORIGINAL FAILURE, replayed end to end: the index 403s. Before the fix
    # fetch_json returned nil, the abbrev map came out empty, and the run reported
    # 32 teams with "no ESPN team_id" and exited 0.
    error = assert_raises(Espn::ScrapeDepthCharts::SourceUnavailable) do
      with_transport(forbid: %r{/nfl/teams\z}) { Espn::ScrapeDepthCharts.new.call }
    end

    assert_includes error.message, "403"
    assert_equal 0, DepthChart.where(team_slug: ABBREVS.values).count,
                 "nothing may be applied off an index that could not be read"
  end

  private

  def ensure_team(slug)
    return if Team.exists?(slug: slug)

    Team.create!(name: slug.split("-").map(&:capitalize).join(" "),
                 sport: "football", league: "nfl")
    assert Team.exists?(slug: slug), "fixture precondition: #{slug} must exist to hang a chart on"
  end

  # Replace Net::HTTP.start for the duration of the block. The real fetch_json runs:
  # it builds the URI, sets User-Agent, calls Net::HTTP.start(host, port, ...) and
  # judges what comes back, so the host and the header are observed rather than
  # assumed.
  def with_transport(forbid: nil, &block)
    seen = @seen
    docs = method(:document_for)
    http = Object.new
    http.define_singleton_method(:request) do |req|
      uri = req.uri
      seen << [uri.host, uri.path, req["User-Agent"]]
      if forbid && uri.path.match?(forbid)
        EspnDepthChartRefreshTest.response(Net::HTTPForbidden, "403", "<HTML><H1>Access Denied</H1></HTML>")
      else
        body = docs.call(uri)
        next EspnDepthChartRefreshTest.response(Net::HTTPNotFound, "404", "{}") if body.nil?

        EspnDepthChartRefreshTest.response(Net::HTTPOK, "200", JSON.generate(body))
      end
    end

    Net::HTTP.stub(:start, ->(_host, _port, **_opts, &blk) { blk.call(http) }, &block)
  end

  # A real Net::HTTPResponse subclass with its body already "read" — what Net::HTTP's
  # own is_a? checks in fetch_json need to judge.
  def self.response(klass, code, body)
    res = klass.new("1.1", code, "stub")
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    res
  end

  # ESPN's three documents, keyed off the URI the service built.
  def document_for(uri)
    case uri.path
    when %r{/nfl/teams\z}
      { "sports" => [{ "leagues" => [{ "teams" => ESPN_IDS.map { |abbrev, id|
        { "team" => { "abbreviation" => abbrev.upcase, "id" => id } }
      } }] }] }
    when %r{/nfl/teams/(\w+)/roster\z}
      { "athletes" => [{ "position" => "offense",
                         "items" => [{ "id" => athlete_id(Regexp.last_match(1)),
                                       "displayName" => athlete_name(Regexp.last_match(1)) }] }] }
    when %r{/teams/(\w+)/depthcharts\z}
      id = athlete_id(Regexp.last_match(1))
      { "items" => [
        { "name" => "3WR 1TE 1RB",
          "positions" => { "qb" => { "position" => { "abbreviation" => "QB" },
                                     "athletes" => [{ "slot" => 1, "athlete" => {
                                       "$ref" => "https://sports.core.api.espn.com/v2/sports/football/leagues/nfl/athletes/#{id}?lang=en"
                                     } }] } } },
        { "name" => "Base 4-3 D", "positions" => {} },
        { "name" => "Special Teams", "positions" => {} }
      ] }
    end
  end

  # ONE DISTINCT ATHLETE PER TEAM, so match_person resolves and a real
  # DepthChartEntry lands for every one of the 32 — a run that matched nobody would
  # still tally teams_scraped: 32 and is caught by the entry count instead.
  def athlete_id(espn_team_id) = "90#{espn_team_id.to_s.rjust(2, '0')}"

  def athlete_name(espn_team_id)
    "Starter #{(ESPN_IDS.key(espn_team_id.to_s) || espn_team_id).to_s.upcase}"
  end

  def ensure_athlete(abbrev)
    espn_id = athlete_id(ESPN_IDS.fetch(abbrev))
    return if Athlete.exists?(espn_id: espn_id)

    person = Person.create!(first_name: "Starter", last_name: abbrev.upcase, athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: espn_id)
  end
end
